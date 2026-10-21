#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/crash.sh" || exit 0
init_state || exit 0
load_config
[ "$PASSIVE_CRASH_MONITOR" = 1 ] || exit 0
MON_LOCK="${GUARDIAN_MONITOR_LOCK:-/dev/lsposed_guardian_crash_monitor}"
mkdir "$MON_LOCK" 2>/dev/null || exit 0
trap 'rmdir "$MON_LOCK" 2>/dev/null || :' EXIT HUP INT TERM
MON_BOOT="$(boot_id)"
[ -n "$MON_BOOT" ] || exit 0
mkdir -p "$MON_DIR" || exit 0
chmod 700 "$MON_DIR" 2>/dev/null || :
log MONITOR 'Read-only crash collector started'
while [ "$(boot_id)" = "$MON_BOOT" ] && boot_complete; do
  if crash_collect; then
    MON_RESULT=ok
  else
    MON_RESULT=error
    [ "$CR_CAPTURE_REASON" = collector-busy ] && MON_RESULT=busy
    if [ "$MON_RESULT" = error ]; then
      log WARN "Crash capture failed ($CR_CAPTURE_REASON); previous history retained"
      write_atomic "$MON_DIR/last-failure-boot" "$MON_BOOT" || :
      write_atomic "$MON_DIR/last-failure-reason" "$CR_CAPTURE_REASON" || :
      write_atomic "$MON_DIR/last-failure-epoch" "$(date +%s)" || :
    else
      log MONITOR 'Crash capture deferred: another collector holds the lock'
    fi
  fi
  # Write last-epoch last, as the completion marker for this sample.
  write_atomic "$MON_DIR/last-boot" "$MON_BOOT" || :
  write_atomic "$MON_DIR/last-result" "$MON_RESULT" || :
  write_atomic "$MON_DIR/last-reason" "$CR_CAPTURE_REASON" || :
  write_atomic "$MON_DIR/last-epoch" "$(date +%s)" || :
  sleep "$CRASH_POLL_SECONDS"
done
