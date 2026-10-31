plan "automatic keybox replacement is guarded"

bootstrap
source_libs
mk_module tricky_store "Tricky Store"
detect_keystore_manager
export SPECTER_TMP_DIR="$TEST_ROOT"
export TEST_NOW=$(date +%s)
export TEST_SCENARIO=healthy
set_cfg toggle_autokeybox 1
printf 'original' > "$KSM_KEYBOX"
printf 'replacement' | base64 | tr -d '\n' | tr "$STD_ALPHABET" "$SHUFFLED_ALPHABET" > "$TEST_ROOT/candidate.blob"

cat > "$BIN_DIR/app_process" <<'MOCK'
#!/bin/sh
case "$3:$4" in
  serial:*) echo abc ;;
  rkp:*/original) [ "$TEST_SCENARIO" != rkp ] && echo 0 || echo 1 ;;
  rkp:*/candidate) echo 0 ;;
  algorithms:*/candidate) [ "$TEST_SCENARIO" != algorithm ] && echo ec || echo rsa ;;
  algorithms:*) echo ec ;;
  expiry:*)
    case "$TEST_SCENARIO" in healthy) echo $((TEST_NOW + 432000)) ;; revoked) echo $((TEST_NOW + 604800)) ;; *) echo $((TEST_NOW + 86400)) ;; esac ;;
  verify:*/original)
    [ "$TEST_SCENARIO" != revoked ] || exit 1
    echo $((TEST_NOW + 86400)) ;;
  verify:*/candidate)
    [ "$TEST_SCENARIO" != invalid ] || exit 1
    [ "$TEST_SCENARIO" != short ] || { echo $((TEST_NOW + 90000)); exit 0; }
    echo $((TEST_NOW + 432000)) ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$BIN_DIR/app_process"

cat > "$BIN_DIR/curl" <<'MOCK'
#!/bin/sh
case "$1" in --version) echo mock; exit 0 ;; esac
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
case "$url" in
  */attestation/root) [ "$TEST_SCENARIO" != offline ] || exit 1; echo '[]' > "$out" ;;
  */attestation/status*) echo '{"entries":{}}' > "$out" ;;
  */catalog)
    if [ "$TEST_SCENARIO" = unknown ]; then serial=9999; else serial=2748; fi
    printf '{"entries":[{"source":"TAKR","version":"1","serial":"%s","revoked":false,"softbanned":false}]}' "$serial" > "$out" ;;
  */key/TAKR/1) cp "$TEST_ROOT/candidate.blob" "$out" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$BIN_DIR/curl"

_out=$(run_feature keybox_auto.sh)
assert_contains "healthy keybox is not rotated" "$_out" "valid for more than 72 hours"
assert_eq "healthy keybox remains" "original" "$(cat "$KSM_KEYBOX")"

export TEST_SCENARIO=invalid
_out=$(run_feature keybox_auto.sh)
assert_contains "invalid candidate rejected" "$_out" "No verified longer-lived replacement"
assert_eq "invalid candidate leaves keybox" "original" "$(cat "$KSM_KEYBOX")"

export TEST_SCENARIO=short
_out=$(run_feature keybox_auto.sh)
assert_contains "short-lived candidate rejected" "$_out" "No verified longer-lived replacement"
assert_eq "short-lived candidate leaves keybox" "original" "$(cat "$KSM_KEYBOX")"

for TEST_SCENARIO in rkp algorithm unknown offline; do
  export TEST_SCENARIO
  rm -f "$SPECTER_DIR/cache/keybox_catalog.json"
  _out=$(run_feature keybox_auto.sh)
  assert_eq "$TEST_SCENARIO leaves keybox unchanged" "original" "$(cat "$KSM_KEYBOX")"
done

export TEST_SCENARIO=revoked
rm -f "$SPECTER_DIR/cache/keybox_catalog.json"
_out=$(run_feature keybox_auto.sh)
assert_contains "revoked keybox may use an otherwise valid shorter-lived replacement" "$_out" "Installed a verified replacement"
assert_eq "revoked keybox was replaced" "replacement" "$(cat "$KSM_KEYBOX")"
printf 'original' > "$KSM_KEYBOX"

export TEST_SCENARIO=expiring
set_cfg keybox_private true
_out=$(run_feature keybox_auto.sh)
assert_contains "private keybox is left alone" "$_out" "Private keybox left unchanged"
set_cfg keybox_private false
set_cfg keybox_custom_type file
_out=$(run_feature keybox_auto.sh)
assert_contains "custom keybox is left alone" "$_out" "Custom keybox left unchanged"
set_cfg keybox_custom_type ''

mkdir -p "$SPECTER_DIR/cache"
printf '%s' '{"entries":[]}' > "$SPECTER_DIR/cache/keybox_catalog.json"
_out=$(run_feature keybox_auto.sh)
assert_contains "uses fresh catalog rather than shared cache" "$_out" "Installed a verified replacement"
assert_eq "replacement is active" "replacement" "$(cat "$KSM_KEYBOX")"
assert_eq "previous keybox backed up" "original" "$(cat "$SPECTER_DIR/keybox-auto-backup/keybox.xml")"

unset SPECTER_TMP_DIR TEST_SCENARIO TEST_NOW
done_testing
