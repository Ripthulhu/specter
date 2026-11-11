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

plan "scheduler runs the keybox watch"

_scheduler=$(cat "$REPO_ROOT/src/lib/scheduler.sh")
assert_contains "watch task present" "$_scheduler" "keybox_watch:keybox_watch.sh:3600:toggle_keybox_info"
assert_contains "watch minimum interval" "$_scheduler" '[ "$_name" = "keybox_watch" ] && [ "$_cfg_interval" -lt 60 ]'
assert_contains "hma task present" "$_scheduler" "hma:hma.sh:21600:toggle_auto_hma"
assert_contains "hma watcher present" "$_scheduler" 'features/hma.sh" --watch'
assert_contains "hma watcher gated" "$_scheduler" '_hma_val'
assert_contains "hma watcher runs without auto-target" "$_scheduler" '|| [ "$(cfg_get toggle_auto_hma 0)" = "1" ]'
assert_contains "target watcher respects polling" "$_scheduler" '_at_method:-instant'
assert_not_contains "target watcher does not require su" "$_scheduler" 'su -c'
assert_contains "hma retry on failure" "$_scheduler" '[ "$_name" = "hma" ] && [ "$_task_rc" -ne 0 ]'
assert_contains "hma failure retry delay" "$_scheduler" "retrying in 5m"
assert_contains "hma missing config forces run" "$_scheduler" '[ "$_hma_cfg_ok" = "1" ] || _last_run=0'
assert_not_contains "old keybox-info task removed" "$_scheduler" "keybox_info:keybox_info.sh:21600"
assert_contains "setup inputs are watched" "$_scheduler" "_setup_info_stale()"
assert_not_contains "setup has no fixed timer" "$_scheduler" "setup_info:setup_info.sh:900"
assert_contains "module snapshot rebuilds on module change" "$_scheduler" "features/modules_state.sh"
assert_contains "instant auto-target uses 6h cleanup" "$_scheduler" "_cfg_interval=21600"
assert_not_contains "second auto-keybox task removed" "$_scheduler" "autokeybox:keybox_auto.sh"
assert_contains "keybox refresh migration present" "$_scheduler" ".keybox_refresh_migrated"

done_testing
