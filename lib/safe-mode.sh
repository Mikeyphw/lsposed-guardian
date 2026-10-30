#!/system/bin/sh
# Non-SQLite bootloop fallback: request KernelSU Vector module disable for next boot.
sm_status() {
  printf 'safe_mode_armed=%s\n' "$AUTO_SAFE_MODE"
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    echo 'safe_mode_owner=ASHREXCUE_DEFERRED'
  else
    echo 'safe_mode_owner=GUARDIAN'
  fi
  printf 'safe_mode_request=%s\n' "$(read_first "$BOOT_DIR/safe-mode-request")"
  printf 'vector_disable_marker=%s\n' "$([ -f "${VECTOR_PROP%/*}/disable" ] && echo present || echo absent)"
}
sm_early() {
  [ "$AUTO_SAFE_MODE" = 1 ] || return 0
  [ "$AUTO_RECOVERY" = 0 ] || return 0
  # Never compete with AshReXcue's own KernelSU module rollback/lockdown.
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    log WARN 'AshReXcue present: leaving Vector bootloop lockdown to AshReXcue'
    return 0
  fi
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
  guardian_notify vector-safe-mode "$(boot_id | tr -cd 'a-fA-F0-9-')" || :
}

# Bounded unattended watchdog: up to three restarts per unresolved incident.
# If AshReXcue itself is installed, leave reboot ownership to it. Guardian's
# own one-shot SQLite journal, stored rescue backup, and Vector DB are untouched.
sm_watchdog_reboot() {
  [ "$AUTO_BOOTLOOP_REBOOT" = 1 ] && [ "$AUTO_SAFE_MODE" = 1 ] && [ "$AUTO_RECOVERY" = 0 ] || return 0
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    log WARN 'AshReXcue owns platform reboot protection; Guardian watchdog defers'
    return 0
  fi
  [ "$(read_first "$BOOT_DIR/pending-id")" = "$(boot_id)" ] || return 0
  [ "$(read_first "$BOOT_DIR/last-success-id")" != "$(boot_id)" ] || return 0
  case "$1" in
    boot-timeout) boot_complete && return 0 ;;
    systemui-three-strikes) : ;;
    *) return 0 ;;
  esac
  SM_BOOT="$(boot_id)"
  case "$SM_BOOT" in ''|*[!a-fA-F0-9-]*) return 0;; esac
  [ ! -e "$BOOT_DIR/auto-reboot-$SM_BOOT" ] || return 0
  SM_COUNT="$(read_first "$BOOT_DIR/auto-reboot-count")"
  is_number "$SM_COUNT" || SM_COUNT=0
  [ "$SM_COUNT" -lt 3 ] || {
    log WARN 'Automatic bootloop watchdog capped at three reboots; no further action'
    return 0
  }
  write_atomic "$BOOT_DIR/auto-reboot-count" "$((SM_COUNT + 1))" || return 0
  write_atomic "$BOOT_DIR/auto-reboot-$SM_BOOT" "$1" || return 0
  sync
  log WARN "Automatic rescue reboot requested ($1, attempt $((SM_COUNT + 1))/3)"
  guardian_notify watchdog-reboot "$(boot_id | tr -cd 'a-fA-F0-9-')" || :
  /system/bin/reboot || log WARN 'Automatic watchdog reboot command failed'
}
