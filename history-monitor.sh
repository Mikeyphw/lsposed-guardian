#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/history.sh" || exit 0
init_state || exit 0
load_config
[ "$HISTORY_MONITOR" = 1 ] || exit 0
HMON_BOOT="$(boot_id)"
[ -n "$HMON_BOOT" ] || exit 0
# Keep background process bounded to this hardware boot only.
while [ "$(boot_id)" = "$HMON_BOOT" ] && boot_complete; do
  if history_capture; then HMON_RESULT=ok
  else
    HMON_RESULT=error
    log WARN 'Historical Vector scope snapshot unavailable; no historical attribution'
    write_atomic "$HIST_DIR/last-error-epoch" "$(date +%s)" || :
  fi
  write_atomic "$HIST_DIR/last-boot" "$HMON_BOOT" || :
  write_atomic "$HIST_DIR/last-result" "$HMON_RESULT" || :
  write_atomic "$HIST_DIR/last-epoch" "$(date +%s)" || :
  sleep "$HISTORY_POLL_SECONDS"
done
