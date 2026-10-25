plan "verified downloads and module installation"
bootstrap
source_libs
rm -f "$BIN_DIR/sha256sum"
SPECTER_DEX="$TEST_ROOT/classes.dex"
touch "$SPECTER_DEX"
export SPECTER_DEX
export CURL_MODE=ok JAVA_MODE=fail

cat > "$BIN_DIR/curl" <<'MOCK'
#!/bin/sh
[ "$1" = --version ] && exit 0
printf '%s\n' "$*" >> "$LOGS_DIR/curl.log"
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then shift; output="$1"; fi
  shift
done
printf 'verified payload' > "$output"
[ "$CURL_MODE" = ok ]
MOCK
cat > "$BIN_DIR/app_process" <<'MOCK'
#!/bin/sh
if [ "$2" = com.dpejoh.specter.ReleaseAsset ]; then
  cat >/dev/null
  [ "$JAVA_MODE" = select ] || exit 1
  printf '%s\n' "$ASSET_SELECTION"
else
  printf 'verified payload' > "$4"
  [ "$JAVA_MODE" = ok ]
fi
MOCK
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/sleep"
chmod +x "$BIN_DIR/curl" "$BIN_DIR/app_process" "$BIN_DIR/sleep"

_digest=$(printf 'verified payload' | sha256sum | cut -d' ' -f1)
_out="$TEST_ROOT/download.zip"
download https://example.org/file "$_out" "$_digest"
assert_exit_code "matching digest accepted" 0 $?
assert_file_eq "downloaded bytes retained" "$_out" 'verified payload'
_curl=$(cat "$LOGS_DIR/curl.log")
assert_contains "curl validates HTTPS redirects" "$_curl" "--proto-redir =https"
assert_contains "curl rejects HTTP errors" "$_curl" "-fLs"
assert_not_contains "curl never disables certificate checks" "$_curl" "--insecure"

download https://example.org/file "$_out" bad-digest
assert_exit_code "digest mismatch rejected" 1 $?
assert_file_not_exists "mismatched download removed" "$_out"

CURL_MODE=fail
download https://example.org/file "$_out"
assert_exit_code "failed transports rejected" 1 $?
assert_file_not_exists "partial failure removed" "$_out"

# Exercise the Android HTTPS fallback with curl unavailable.
mv "$BIN_DIR/curl" "$BIN_DIR/curl.disabled"
curl() { return 127; }
JAVA_MODE=ok
download https://example.org/file "$_out" "$_digest"
assert_exit_code "Android client works without curl" 0 $?
assert_file_eq "Android client payload retained" "$_out" 'verified payload'
unset -f curl

# The installer must carry the selected asset's digest into download().
check_network() { return 0; }
download() {
  case "$1" in
    https://api.github.com/*) printf '{"assets":[]}' ;;
    *)
      printf '%s' "${3:-}" > "$TEST_ROOT/passed-digest"
      [ "$INSTALL_DOWNLOAD" = ok ] ;;
  esac
}
ksud() { printf '%s' "$*" >> "$TEST_ROOT/installed"; }
ROOT_SOL=kernelsu
JAVA_MODE=select
ASSET_SELECTION="https://github.com/owner/repo/releases/download/v1/module.zip|$_digest"
export ASSET_SELECTION
INSTALL_DOWNLOAD=ok
install_module_from_github owner/repo
assert_exit_code "verified module installation accepted" 0 $?
assert_file_eq "selected digest passed to downloader" "$TEST_ROOT/passed-digest" "$_digest"
assert_file_exists "verified module reaches root installer" "$TEST_ROOT/installed"

rm -f "$TEST_ROOT/installed"
INSTALL_DOWNLOAD=fail
install_module_from_github owner/repo
assert_exit_code "failed verification aborts installation" 1 $?
assert_file_not_exists "unverified bytes never reach root installer" "$TEST_ROOT/installed"

JAVA_MODE=fail
install_module_from_github owner/repo
assert_exit_code "invalid metadata aborts installation" 1 $?
assert_file_not_exists "invalid metadata never reaches root installer" "$TEST_ROOT/installed"

done_testing
