#!/system/bin/sh
# Non-SQLite bootloop fallback: request KernelSU Vector module disable for next boot.
sm_status() {
  printf 'safe_mode_armed=%s\n' "$AUTO_SAFE_MODE"
  printf 'safe_mode_request=%s\n' "$(read_first "$BOOT_DIR/safe-mode-request")"
  printf 'vector_disable_marker=%s\n' "$([ -f "${VECTOR_PROP%/*}/disable" ] && echo present || echo absent)"
}
sm_early() {
  [ "$AUTO_SAFE_MODE" = 1 ] || return 0
  [ "$AUTO_RECOVERY" = 0 ] || return 0
  [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ] || return 0
  [ ! -e "$BOOT_DIR/safe-mode-request" ] || return 0
  SM_DIR="${VECTOR_PROP%/*}"
  # Never guess a different module path or follow a symlink.
  [ "$SM_DIR" = /data/adb/modules/zygisk_vector ] || return 0
  [ -d "$SM_DIR" ] && [ ! -L "$SM_DIR" ] &&
    [ -f "$VECTOR_PROP" ] && [ ! -L "$VECTOR_PROP" ] &&
    grep -Fxq 'id=zygisk_vector' "$VECTOR_PROP" || return 0
  [ ! -e "$SM_DIR/disable" ] && [ ! -L "$SM_DIR/disable" ] || return 0
  # Persist the one-time incident latch before any module-state mutation.
  write_atomic "$BOOT_DIR/safe-mode-request" "$(boot_id)" || return 0
  : > "$SM_DIR/disable" || { log WARN 'Vector safe-mode marker creation failed'; return 0; }
  chmod 600 "$SM_DIR/disable" 2>/dev/null || :
  sync
  log WARN 'Bootloop threshold reached: Vector disabled for NEXT boot only; no SQLite changes or reboot attempted'
}
