plan "pif preferred + imported device seam"

bootstrap
. "$REPO_ROOT/src/lib/pif_preferred.sh"

assert_eq "inject dest" "/data/adb/pif.prop" "$(pif_prop_dest 'Play Integrity Fix [INJECT]')"
assert_eq "fork dest" "/data/adb/modules/playintegrityfix/custom.pif.prop" "$(PIF_DIR=/data/adb/modules/playintegrityfix pif_prop_dest 'Play Integrity Fork')"

_tmp=$(mktemp -d)
printf '%s\n' 'FINGERPRINT=google/blazer/blazer:17/CP2A.1/1:user/release-keys' 'MODEL=Pixel 10 Pro' 'MANUFACTURER=Google' >"$_tmp/ok.prop"
printf '%s\n' 'MODEL=Pixel 10 Pro' >"$_tmp/no_fp.prop"
printf '%s\n' 'FINGERPRINT=google/blazer/blazer:17/CP2A.1/1:user/release-keys' >"$_tmp/no_model.prop"

pif_prop_valid "$_tmp/ok.prop"
assert_eq "valid prop" "0" "$?"

pif_prop_valid "$_tmp/no_fp.prop"
assert_eq "missing fingerprint" "1" "$?"

pif_prop_valid "$_tmp/no_model.prop"
assert_eq "missing model" "1" "$?"

assert_eq "read model" "Pixel 10 Pro" "$(pif_prop_get "$_tmp/ok.prop" MODEL)"

SPECTER_DIR="$_tmp"
mkdir -p "$SPECTER_DIR/pif_imported"
cp "$_tmp/ok.prop" "$SPECTER_DIR/pif_imported/abc.prop"

_choice=$(pif_choose_preferred "Pixel 6|oriole_beta
Pixel 10 Pro|imported:abc")
case "$_choice" in
  "Pixel 6|oriole_beta"|"Pixel 10 Pro|imported:abc") ok "choose picks from preferred pool" ;;
  *) fail "choose picks from preferred pool" "got [$_choice]" ;;
esac

pif_choose_preferred "Gone|imported:missing"
assert_eq "choose fails when imported file missing" "1" "$?"

_choice=$(pif_choose_preferred "Pixel 9 Pro|caiman_beta")
assert_eq "choose keeps canary preferred" "Pixel 9 Pro|caiman_beta" "$_choice"

assert_eq "mirror url product path" \
  "https://fastly.jsdelivr.net/gh/KOWX712/PlayIntegrityFix@bot/device_prop/caiman_beta.prop" \
  "$(pif_bot_mirror_urls 'bot/device_prop/caiman_beta.prop' | head -1)"

_out="$_tmp/data_adb_pif.prop"
pif_apply_imported "abc" "$_out"
assert_file_eq "apply writes prop as-is" "$_out" "$(cat "$_tmp/ok.prop")"

printf '%s\n' 'FINGERPRINT=old' 'MODEL=Old' 'spoofBuild=true' 'spoofProvider=false' >"$_tmp/existing.prop"
printf '%s\n' 'FINGERPRINT=google/blazer/blazer:17/CP2A.1/1:user/release-keys' 'MODEL=Pixel 10 Pro' >"$_tmp/dest.prop"
pif_merge_spoof_keys "$_tmp/existing.prop" "$_tmp/dest.prop"
grep -q '^spoofBuild=true$' "$_tmp/dest.prop"
assert_eq "merge keeps spoofBuild" "0" "$?"

rm -rf "$_tmp"

# pif_apply_preferred: migrate+imported success, Canary no-net → 2
bootstrap
source_libs
. "$REPO_ROOT/src/lib/pif_preferred.sh"
PIF_DIR="$TEST_ROOT/pif"
mkdir -p "$PIF_DIR" "$SPECTER_DIR/pif_imported"
printf '%s\n' 'FINGERPRINT=google/blazer/blazer:17/CP2A.1/1:user/release-keys' 'MODEL=Pixel 10 Pro' \
  >"$SPECTER_DIR/pif_imported/abc.prop"
set_cfg pif_preferred_product "imported:abc"
set_cfg pif_preferred_model "Pixel 10 Pro"
pif_apply_preferred "Play Integrity Fork"
assert_eq "apply preferred imported" "0" "$?"
assert_file_eq "apply preferred wrote dest" "$PIF_DIR/custom.pif.prop" "$(cat "$SPECTER_DIR/pif_imported/abc.prop")"
set_cfg pif_preferred_devices "Pixel 9 Pro|caiman_beta"
check_network() { return 1; }
pif_apply_preferred "Play Integrity Fork"
assert_eq "apply preferred needs network" "2" "$?"

# Test blacklist filtering
_sample_pool="Pixel 6|oriole_beta
Pixel 8|shiba_beta
Pixel 9a|tegu_beta"

_filtered=$(pif_filter_blacklist "$_sample_pool" "")
assert_eq "filter empty blacklist keeps all" "$_sample_pool" "$_filtered"

_filtered=$(pif_filter_blacklist "$_sample_pool" "tegu_beta")
assert_eq "filter blacklist removes matching product" "Pixel 6|oriole_beta
Pixel 8|shiba_beta" "$_filtered"

_filtered=$(pif_filter_blacklist "$_sample_pool" "Pixel 9a|tegu_beta
Pixel 6|oriole_beta")
assert_eq "filter multi blacklist leaves single item" "Pixel 8|shiba_beta" "$_filtered"

# Test pif_apply_preferred with blacklist when preferred_devices is unset
set_cfg pif_preferred_devices ""
set_cfg pif_preferred_product ""
set_cfg pif_preferred_model ""
set_cfg pif_blacklist ""
pif_apply_preferred "Play Integrity Fork"
assert_eq "apply preferred returns 1 when no target and no blacklist" "1" "$?"

# When blacklist is set, pif_apply_preferred activates random canary selection
set_cfg pif_blacklist "oriole_beta"
check_network() { return 1; }
pif_apply_preferred "Play Integrity Fork"
assert_eq "apply preferred with blacklist activates random canary (needs net)" "2" "$?"

# Generated Pixel 10 identities must not keep Fork v18's generic launch API 32.
bootstrap
source_libs
. "$REPO_ROOT/src/lib/pif_preferred.sh"
PIF_DIR="$TEST_ROOT/pif"
export PIF_DIR
mkdir -p "$PIF_DIR" "$SPECTER_DIR/pif_imported"
cat > "$PIF_DIR/killpi.sh" <<'EOF'
#!/bin/sh
grep '^DEVICE_INITIAL_SDK_INT=' "$PIF_DIR/custom.pif.prop" >> "$PIF_DIR/restarts"
grep '^\*api_level=' "$PIF_DIR/custom.pif.prop" >> "$PIF_DIR/restarts"
EOF

cat > "$PIF_DIR/custom.pif.prop" <<'EOF'
FINGERPRINT=google/mustang_beta/mustang:CANARY/BUILD/123:user/release-keys
MODEL=Pixel 7 Pro
DEVICE=cheetah
DEVICE_INITIAL_SDK_INT=32
*api_level=32
xapi_level=17
# *api_level=32
spoofVendingSdk=0
EOF
_pfg_out=$(pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork')
assert_eq "generated Pixel 10 Java launch API" 36 "$(pif_prop_get "$PIF_DIR/custom.pif.prop" DEVICE_INITIAL_SDK_INT)"
assert_contains "literal wildcard updated" "$(cat "$PIF_DIR/custom.pif.prop")" '*api_level=36'
assert_contains "nonliteral wildcard preserved" "$(cat "$PIF_DIR/custom.pif.prop")" 'xapi_level=17'
assert_contains "comment preserved" "$(cat "$PIF_DIR/custom.pif.prop")" '# *api_level=32'
assert_contains "custom spoof setting preserved" "$(cat "$PIF_DIR/custom.pif.prop")" 'spoofVendingSdk=0'
assert_contains "RKP requirement explained" "$_pfg_out" 'valid RKP keybox'
assert_file_eq "restart sees corrected config" "$PIF_DIR/restarts" 'DEVICE_INITIAL_SDK_INT=36
*api_level=36'
_pfg_before=$(cat "$PIF_DIR/custom.pif.prop")
pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
assert_file_eq "already-correct generated props unchanged" "$PIF_DIR/custom.pif.prop" "$_pfg_before"
assert_eq "no extra restart for unchanged props" 2 "$(wc -l < "$PIF_DIR/restarts" | tr -d ' ')"

sed -i 's/DEVICE_INITIAL_SDK_INT=36/DEVICE_INITIAL_SDK_INT=32/; s/^\*api_level=36/*api_level=32/' \
  "$PIF_DIR/custom.pif.prop"
_atomic_before=$(cat "$PIF_DIR/custom.pif.prop")
_atomic_restarts=$(wc -l < "$PIF_DIR/restarts")
(
  cat() { printf 'partial write\n'; return 1; }
  pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null 2>&1
)
assert_exit_code "staged write failure reported" 1 "$?"
assert_file_eq "staged write failure preserves live profile" "$PIF_DIR/custom.pif.prop" "$_atomic_before"
assert_eq "staged write failure does not restart" "$_atomic_restarts" "$(wc -l < "$PIF_DIR/restarts")"
(
  mv() { return 1; }
  pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null 2>&1
)
assert_exit_code "atomic rename failure reported" 1 "$?"
assert_file_eq "atomic rename failure preserves live profile" "$PIF_DIR/custom.pif.prop" "$_atomic_before"
assert_eq "atomic rename failure does not restart" "$_atomic_restarts" "$(wc -l < "$PIF_DIR/restarts")"
(
  cp() { return 1; }
  pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null 2>&1
)
assert_exit_code "unsupported metadata preservation reported" 1 "$?"
assert_file_eq "metadata copy failure preserves live profile" "$PIF_DIR/custom.pif.prop" "$_atomic_before"

chmod 640 "$PIF_DIR/custom.pif.prop"
_atomic_metadata=$(stat -c '%a %u %g' "$PIF_DIR/custom.pif.prop")
pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
assert_eq "atomic replacement preserves permissions and ownership" "$_atomic_metadata" "$(stat -c '%a %u %g' "$PIF_DIR/custom.pif.prop")"
mv "$PIF_DIR/custom.pif.prop" "$PIF_DIR/resolved.prop"
ln -s "$PIF_DIR/resolved.prop" "$PIF_DIR/custom.pif.prop"
sed -i 's/DEVICE_INITIAL_SDK_INT=36/DEVICE_INITIAL_SDK_INT=32/' "$PIF_DIR/resolved.prop"
pif_normalize_generated_first_api "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
[ -L "$PIF_DIR/custom.pif.prop" ]
assert_exit_code "normalization preserves the destination symlink" 0 "$?"
assert_eq "symlink target receives the correction" 36 "$(pif_prop_get "$PIF_DIR/resolved.prop" DEVICE_INITIAL_SDK_INT)"
rm "$PIF_DIR/custom.pif.prop"
mv "$PIF_DIR/resolved.prop" "$PIF_DIR/custom.pif.prop"

for _pixel_device in frankel blazer mustang rango; do
  printf 'FINGERPRINT=google/%s_beta/%s:CANARY/B/1:user/release-keys\nMODEL=Pixel 10\n' \
    "$_pixel_device" "$_pixel_device" > "$PIF_DIR/family.prop"
  pif_normalize_generated_first_api "$PIF_DIR/family.prop" 'Play Integrity Fix [INJECT]' >/dev/null
  assert_eq "$_pixel_device launch API appended" 36 "$(pif_prop_get "$PIF_DIR/family.prop" DEVICE_INITIAL_SDK_INT)"
  grep -q '^\*api_level=' "$PIF_DIR/family.prop"
  assert_eq "$_pixel_device inject props get no Fork wildcard" 1 "$?"
done

printf '%s\n' 'FINGERPRINT=google/cheetah_beta/cheetah:CANARY/B/1:user/release-keys' \
  'MODEL=Pixel 10 Pro XL' 'DEVICE=mustang' 'DEVICE_INITIAL_SDK_INT=32' '*api_level=32' > "$PIF_DIR/older.prop"
_pfg_before=$(cat "$PIF_DIR/older.prop")
pif_normalize_generated_first_api "$PIF_DIR/older.prop" 'Play Integrity Fork' >/dev/null
assert_file_eq "fingerprint identity wins over model and DEVICE fields" "$PIF_DIR/older.prop" "$_pfg_before"
printf '%s\n' 'FINGERPRINT=google/future/future:CANARY/B/1:user/release-keys' \
  'MODEL=Future Pixel' 'DEVICE_INITIAL_SDK_INT=32' > "$PIF_DIR/unknown.prop"
_pfg_before=$(cat "$PIF_DIR/unknown.prop")
pif_normalize_generated_first_api "$PIF_DIR/unknown.prop" 'Play Integrity Fork' >/dev/null
assert_file_eq "unknown generated identity unchanged" "$PIF_DIR/unknown.prop" "$_pfg_before"
printf '%s\n' 'FINGERPRINT=other/mustang_beta/mustang:CANARY/B/1:user/release-keys' \
  'MODEL=Pixel 10 Pro XL' 'DEVICE_INITIAL_SDK_INT=32' > "$PIF_DIR/other.prop"
_pfg_before=$(cat "$PIF_DIR/other.prop")
pif_normalize_generated_first_api "$PIF_DIR/other.prop" 'Play Integrity Fork' >/dev/null
assert_file_eq "non-Google fingerprint unchanged" "$PIF_DIR/other.prop" "$_pfg_before"

cat > "$PIF_DIR/autopif4.sh" <<'EOF'
#!/bin/sh
cat > "$PIF_DIR/custom.pif.prop" <<'PROP'
FINGERPRINT=google/mustang_beta/mustang:CANARY/B/1:user/release-keys
MODEL=Pixel 10 Pro XL
DEVICE_INITIAL_SDK_INT=32
PROP
echo 'MODEL=Pixel 10 Pro XL'
EOF
check_network() { return 0; }
pif_apply_device 'Pixel 10 Pro XL' mustang_beta "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
assert_eq "preferred Fork generator normalized" 36 "$(pif_prop_get "$PIF_DIR/custom.pif.prop" DEVICE_INITIAL_SDK_INT)"
assert_contains "preferred Fork generator gets wildcard" "$(cat "$PIF_DIR/custom.pif.prop")" '*api_level=36'

printf '#!/bin/sh\nexit 1\n' > "$PIF_DIR/autopif4.sh"
download() {
  printf '%s\n' 'FINGERPRINT=google/blazer_beta/blazer:CANARY/B/1:user/release-keys' \
    'MODEL=Pixel 10 Pro' 'DEVICE_INITIAL_SDK_INT=32' > "$2"
}
pif_apply_device 'Pixel 10 Pro' blazer_beta "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
assert_eq "Fork GitHub fallback normalized" 36 "$(pif_prop_get "$PIF_DIR/custom.pif.prop" DEVICE_INITIAL_SDK_INT)"

cp "$PIF_DIR/custom.pif.prop" "$SPECTER_DIR/pif_imported/custom.prop"
sed -i 's/DEVICE_INITIAL_SDK_INT=36/DEVICE_INITIAL_SDK_INT=32/; s/^\*api_level=36/*api_level=32/' \
  "$SPECTER_DIR/pif_imported/custom.prop"
_pfg_before=$(cat "$SPECTER_DIR/pif_imported/custom.prop")
_pfg_restarts=$(wc -l < "$PIF_DIR/restarts")
pif_apply_device 'Custom Pixel 10' imported:custom "$PIF_DIR/custom.pif.prop" 'Play Integrity Fork' >/dev/null
assert_file_eq "imported Pixel 10 keeps deliberate custom API" "$PIF_DIR/custom.pif.prop" "$_pfg_before"
assert_eq "imported profile not restarted by normalizer" "$_pfg_restarts" "$(wc -l < "$PIF_DIR/restarts")"

# Exercise the feature's independent default/random Fork path without network access.
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/ping"
chmod +x "$BIN_DIR/ping"
printf 'name=Play Integrity Fork\n' > "$PIF_DIR/module.prop"
cat > "$PIF_DIR/autopif4.sh" <<'EOF'
#!/bin/sh
cat > "$PIF_DIR/custom.pif.prop" <<'PROP'
FINGERPRINT=google/rango_beta/rango:CANARY/B/1:user/release-keys
MODEL=Pixel 10 Pro Fold
DEVICE_INITIAL_SDK_INT=32
*api_level=32
PROP
echo 'MODEL=Pixel 10 Pro Fold'
EOF
run_feature pif.sh > "$PIF_DIR/default-run.log"
assert_exit_code "default Fork generation succeeds" 0 "$?"
assert_eq "default Fork generation normalized" 36 "$(pif_prop_get "$PIF_DIR/custom.pif.prop" DEVICE_INITIAL_SDK_INT)"
assert_contains "default path restarts with corrected property" "$(tail -2 "$PIF_DIR/restarts")" '*api_level=36'

printf '#!/bin/sh\nexit 1\n' > "$PIF_DIR/autopif4.sh"
cp "$SPECTER_DIR/pif_imported/custom.prop" "$PIF_DIR/custom.pif.prop"
_pfg_before=$(cat "$PIF_DIR/custom.pif.prop")
run_feature pif.sh > "$PIF_DIR/failed-run.log"
assert_file_eq "failed generation does not normalize existing custom props" "$PIF_DIR/custom.pif.prop" "$_pfg_before"

done_testing


