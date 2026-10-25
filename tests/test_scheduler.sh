plan "root scheduler handler without traditional su"
bootstrap
source_libs
mkdir -p "$TEST_ROOT/lib" "$TEST_ROOT/features" "$TEST_ROOT/deps"
cat > "$TEST_ROOT/lib/common.sh" <<'MOCK'
cfg_get() { echo 1; }
ensure_dir() { mkdir -p "$1"; }
log_i() { :; }
MOCK
touch "$TEST_ROOT/lib/constants.sh"
printf 'refresh_module_description() { :; }\n' > "$TEST_ROOT/lib/desc.sh"
printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/deps/inotifyd"
chmod +x "$TEST_ROOT/deps/inotifyd"
printf '#!/bin/sh\nexit 99\n' > "$BIN_DIR/su"
chmod +x "$BIN_DIR/su"
printf 'echo ran > "$SPECTER_DIR/target-ran"\n' > "$TEST_ROOT/features/auto_target.sh"
mkdir -p "$SPECTER_DIR/config/val"
printf '1' > "$SPECTER_DIR/config/val/toggle_auto_target.val"

# Stop before the periodic loop, then execute the actual generated handler.
sed -e '/^while true; do/,$d' -e '/^trap /d' "$REPO_ROOT/src/lib/scheduler.sh" > "$TEST_ROOT/lib/scheduler.sh"
sh "$TEST_ROOT/lib/scheduler.sh"
sh "$SPECTER_DIR/.inotify_handler.sh"
assert_file_exists "handler runs with su unavailable" "$SPECTER_DIR/target-ran"
rm -f "$SPECTER_DIR/target-ran"
printf '0' > "$SPECTER_DIR/config/val/toggle_auto_target.val"
sh "$SPECTER_DIR/.inotify_handler.sh"
assert_file_not_exists "handler honors disabled auto-target" "$SPECTER_DIR/target-ran"

done_testing
