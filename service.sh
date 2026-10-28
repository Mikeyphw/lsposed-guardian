#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/crash.sh" || exit 0
. "$MODDIR/lib/boot-probe.sh" || exit 0
. "$MODDIR/lib/boot-trial.sh" || exit 0
. "$MODDIR/lib/one-shot.sh" || exit 0
init_state || exit 0
load_config
ID="$(boot_id)"
[ -n "$ID" ] || exit 0
# Refuse to label a different boot successful (or run after a missing boot hook).
[ "$(read_first "$BOOT_DIR/pending-id")" = "$ID" ] || { log WARN 'No matching pending boot record'; exit 0; }
LOCK="${GUARDIAN_LOCK_DIR:-/dev/lsposed_guardian_service_lock}"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || :' EXIT HUP INT TERM

WAITED=0
while ! boot_complete; do
  if [ "$WAITED" -ge "$BOOT_WAIT_SECONDS" ]; then
    log WARN 'Boot completion timeout; pending observation preserved'
    exit 0
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done
log BOOT 'Android boot completed; starting stability checks'

STABLE=0
PREVIOUS_PID=''
ELAPSED=0
while [ "$ELAPSED" -lt "$STABILITY_SECONDS" ]; do
  if ! boot_complete; then
    log WARN 'Boot completion flag disappeared; pending observation preserved'
    exit 0
  fi
  if [ "$CHECK_SYSTEMUI" = 1 ]; then
    PID="$(pidof com.android.systemui 2>/dev/null | awk '{print $1}')"
    if [ -z "$PID" ]; then
      log WARN 'SystemUI absent during stability check; pending observation preserved'
      exit 0
    fi
    if [ -n "$PREVIOUS_PID" ] && [ "$PID" != "$PREVIOUS_PID" ]; then
      log WARN 'SystemUI process restarted during stability check; pending observation preserved'
      exit 0
    fi
    PREVIOUS_PID="$PID"
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
STABLE=1

# A failed snapshot must not make an otherwise stable boot count as a bootloop.
# Only rotate a known-good DB when Vector's own consistent backup succeeds.
successful_snapshot || :
write_atomic "$BOOT_DIR/last-success-id" "$ID"
write_atomic "$BOOT_DIR/failures" 0
rm -f "$BOOT_DIR/pending-id" "$BOOT_DIR/recovery-performed"
log HEALTH 'Boot stable, consecutive-failure counter cleared'
# Read-only history state attestation; failure never makes a healthy boot fail.
crash_continuity_boot || log WARN 'Crash continuity boot checkpoint unavailable'
bp_stable || :
bt_stable || :
os_stable || :
# Start the read-only collector only after a healthy boot; never delay recovery for it.
if [ "$PASSIVE_CRASH_MONITOR" = 1 ]; then
  sh "$MODDIR/crash-monitor.sh" </dev/null >/dev/null 2>&1 &
fi

# Start independent read-only module/scope sampler, with no coupling to the
# crash collector and no impact on boot stability qualification.
if [ "$HISTORY_MONITOR" = 1 ]; then
  sh "$MODDIR/history-monitor.sh" </dev/null >/dev/null 2>&1 &
fi
exit 0
