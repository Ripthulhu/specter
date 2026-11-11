#!/system/bin/sh
set -e
umask 077
MODDIR=${0%/*}
. "$MODDIR/../lib/common.sh"

detect_keystore_manager
# Only the backend whose atomic replacement behaviour is verified is supported.
[ "$KSM" = "trickystore" ] && [ -f "$KSM_KEYBOX" ] && [ ! -L "$KSM_KEYBOX" ] || {
  log_w "AUTO_KEYBOX" "No supported installed keybox; leaving it unchanged"
  exit 0
}
case "$(cfg_get keybox_private false)" in true|1) log_i "AUTO_KEYBOX" "Private keybox left unchanged"; exit 0 ;; esac
[ -z "$(cfg_get keybox_custom_type '')" ] || { log_i "AUTO_KEYBOX" "Custom keybox left unchanged"; exit 0; }
command -v flock >/dev/null 2>&1 || { log_w "AUTO_KEYBOX" "flock unavailable; leaving keybox unchanged"; exit 1; }
ensure_dir "$SPECTER_DIR"
# Android's shell marks higher descriptors close-on-exec; stdin stays inherited.
exec 0<>"$SPECTER_DIR/keybox-update.lock"
flock -n 0 || { log_i "AUTO_KEYBOX" "Another keybox update is running"; exit 0; }

_dir=$(mktemp -d "$SPECTER_DIR/keybox-auto.XXXXXXXX") || exit 1
SPECTER_TMP_DIR="$_dir"
export SPECTER_TMP_DIR
_adjacent="$(dirname "$KSM_KEYBOX")/.specter-keybox.$$"
trap 'rm -f "$_adjacent"; rm -rf "$_dir"' EXIT
trap 'exit 1' HUP INT TERM
cp "$KSM_KEYBOX" "$_dir/original" || exit 1
_dex="$MODDIR/../deps/classes.dex"
_verify() { CLASSPATH="$_dex" app_process / com.dpejoh.specter.KeyboxVerifier "$@"; }
_expiry=$(_verify expiry "$_dir/original") || { log_w "AUTO_KEYBOX" "Could not inspect installed keybox"; exit 1; }
case "$_expiry" in ''|*[!0-9]*) exit 1 ;; esac
_now=$(date +%s)
case "$_now" in ''|*[!0-9]*) exit 1 ;; esac
_notify() {
  command -v cmd >/dev/null 2>&1 && cmd notification post -t 'Specter' specter_keybox "$1" >/dev/null 2>&1 || true
}
_network_failure() {
  log_w "AUTO_KEYBOX" "Verification data unavailable; keeping the current keybox"
  [ "$_expiry" -gt $((_now + 259200)) ] || _notify 'Keybox expires soon; verification data is unavailable.'
  exit 1
}

# Fresh Google data is required even when the installed certificate appears valid.
download "https://android.googleapis.com/attestation/root" "$_dir/roots.json" || _network_failure
download "$GOOGLE_REVOCATION_URL" "$_dir/status.json" || _network_failure
_current_ok=0
_verify verify "$_dir/original" "$_dir/roots.json" "$_dir/status.json" >/dev/null 2>&1 && _current_ok=1
if [ "$_current_ok" = 1 ] && [ "$_expiry" -gt $((_now + 259200)) ]; then
  log_i "AUTO_KEYBOX" "Installed keybox is valid for more than 72 hours"
  exit 0
fi

download "$CATALOG_URL" "$_dir/catalog.json" || _network_failure
_history=$(cat "$_dir/catalog.json")
_serial=$(_verify serial "$_dir/original") || exit 1
_current_rkp=$(_verify rkp "$_dir/original") || exit 1
_current_algorithms=$(_verify algorithms "$_dir/original") || exit 1
case "$_serial" in ''|*[!a-fA-F0-9]*) exit 1 ;; esac
_decimal=$(hex_to_dec "$_serial") || exit 1
_managed=$(printf '%s' "$_history" | grep -o '"entries":\[[^]]*\]' | grep -o '{[^}]*}' |
  grep -E '"serial":"('"$_serial"'|'"$_decimal"')"' || true)
[ -n "$_managed" ] || {
  log_w "AUTO_KEYBOX" "Installed keybox is not in the catalog; leaving it unchanged"
  _notify 'Installed keybox is not recognized; it was left unchanged.'
  exit 1
}
_provider=$(cfg_get keybox_provider auto)
_pool=$(printf '%s' "$_history" | grep -o '"entries":\[[^]]*\]' | grep -o '{[^}]*}' | grep -v '"revoked":true' | grep -v '"softbanned":true' || true)
_minimum=$((_now + 172800))
if [ "$_current_ok" = 1 ] && [ $((_expiry + 86400)) -gt "$_minimum" ]; then
  _minimum=$((_expiry + 86400))
fi
while IFS= read -r _entry; do
  _src=$(printf '%s' "$_entry" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')
  _ver=$(printf '%s' "$_entry" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  case "$_src" in ''|*[!a-zA-Z0-9_.-]*) continue ;; esac
  case "$_ver" in ''|*[!a-zA-Z0-9_.-]*) continue ;; esac
  [ "$_provider" = auto ] || [ "$_provider" = "$_src" ] || continue
  download "${KEYBOX_URL}/${_src}/${_ver}" "$_dir/download" || continue
  decode_keybox_blob "$_dir/download" "$_dir/candidate" || continue
  _candidate_expiry=$(_verify verify "$_dir/candidate" "$_dir/roots.json" "$_dir/status.json") || continue
  _verify normalize "$_dir/candidate" "$_dir/normalized" || continue
  _verify verify "$_dir/normalized" "$_dir/roots.json" "$_dir/status.json" >/dev/null || continue
  mv -f "$_dir/normalized" "$_dir/candidate" || continue
  [ "$(_verify algorithms "$_dir/candidate")" = "$_current_algorithms" ] || continue
  if [ "$_current_rkp" = 1 ]; then
    [ "$(_verify rkp "$_dir/candidate")" = 1 ] || continue
  fi
  case "$_candidate_expiry" in ''|*[!0-9]*) continue ;; esac
  [ "$_candidate_expiry" -gt "$_minimum" ] || continue
  cmp -s "$KSM_KEYBOX" "$_dir/original" || { log_w "AUTO_KEYBOX" "Keybox changed during check; cancelling"; exit 1; }
  [ "$(cfg_get toggle_autokeybox 0)" = 1 ] || exit 0
  case "$(cfg_get keybox_private false)" in true|1) exit 0 ;; esac
  [ -z "$(cfg_get keybox_custom_type '')" ] || exit 0
  mkdir -p "$SPECTER_DIR/keybox-auto-backup"
  chmod 700 "$SPECTER_DIR/keybox-auto-backup"
  cp "$_dir/original" "$SPECTER_DIR/keybox-auto-backup/keybox.xml" || exit 1
  chmod 600 "$SPECTER_DIR/keybox-auto-backup/keybox.xml"
  cp "$_dir/candidate" "$_adjacent" || exit 1
  chmod 600 "$_adjacent"
  restorecon "$_adjacent" 2>/dev/null || true
  mv -f "$_adjacent" "$KSM_KEYBOX" || exit 1
  log_i "AUTO_KEYBOX" "Installed a verified replacement; the previous keybox was saved"
  _notify 'Keybox updated. Check Play Integrity when convenient.'
  exit 0
done <<EOF
$_pool
EOF
log_w "AUTO_KEYBOX" "No verified longer-lived replacement available; keeping the current keybox"
_notify 'Keybox needs attention; no verified replacement is available.'
exit 1
