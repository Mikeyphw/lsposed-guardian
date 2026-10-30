#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/crash.sh" || exit 0
. "$MODDIR/lib/boot-probe.sh" || exit 0
. "$MODDIR/lib/boot-trial.sh" || exit 0
. "$MODDIR/lib/one-shot.sh" || exit 0
. "$MODDIR/lib/safe-mode.sh" || exit 0
. "$MODDIR/lib/softlock.sh" || exit 0
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
    sm_watchdog_reboot boot-timeout || :
    exit 0
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done
log BOOT 'Android boot completed; starting stability checks'

STABLE=0
PREVIOUS_PID=''
SYSTEMUI_STRIKES=0
ELAPSED=0
while [ "$ELAPSED" -lt "$STABILITY_SECONDS" ]; do
  if ! boot_complete; then
    log WARN 'Boot completion flag disappeared; pending observation preserved'
    exit 0
  fi
  if [ "$CHECK_SYSTEMUI" = 1 ]; then
    PID="$(pidof com.android.systemui 2>/dev/null | awk '{print $1}')"
    if [ -z "$PID" ] || { [ -n "$PREVIOUS_PID" ] && [ "$PID" != "$PREVIOUS_PID" ]; }; then
      SYSTEMUI_STRIKES=$((SYSTEMUI_STRIKES + 1))
      log WARN "SystemUI instability observed ($SYSTEMUI_STRIKES/3)"
      if [ "$SYSTEMUI_STRIKES" -ge 3 ]; then
        log WARN 'SystemUI crash loop: pending boot deliberately not marked stable'
        sm_watchdog_reboot systemui-three-strikes || :
        exit 0
      fi
    fi
    [ -z "$PID" ] || PREVIOUS_PID="$PID"
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
STABLE=1
if [ "$SYSTEMUI_STRIKES" -gt 0 ]; then
  log WARN 'SystemUI instability during observation; treating boot as unqualified'
  exit 0
fi

# A stable SystemUI PID does not prove Android dismissed the boot-progress dialog.
# Observe current boot BEFORE rotating success receipts or beginning collectors.
SL_OBSERVE_RESULT=0
sl_observe || SL_OBSERVE_RESULT=$?
if [ "$SL_OBSERVE_RESULT" -eq 2 ]; then
  sl_recover || :
  exit 0
fi
# Unsupported visibility is distinct from a confirmed clear result; the
# regular boot stability receipt remains a *process* health receipt only.
if [ "$SL_OBSERVE_RESULT" -ne 0 ]; then
  log WARN 'Softlock window detection unverified; no automatic rescue action'
fi

# A failed snapshot must not make an otherwise stable boot count as a bootloop.
# Only rotate a known-good DB when Vector's own consistent backup succeeds.
successful_snapshot || :
write_atomic "$BOOT_DIR/last-success-id" "$ID"
write_atomic "$BOOT_DIR/failures" 0
write_atomic "$BOOT_DIR/auto-reboot-count" 0 || :
rm -f "$BOOT_DIR/pending-id" "$BOOT_DIR/recovery-performed"
log HEALTH 'Boot stable, consecutive-failure counter cleared'
# A previous one-shot softlock attempt stays latched while Vector is disabled.
# Only a *later* stable boot with Vector restored/healthy releases that latch.
if [ -s "$STATE_DIR/softlock/recovery-attempt" ] &&
   [ ! -e /data/adb/modules/zygisk_vector/disable ] &&
   vector status >/dev/null 2>&1; then
  cp "$STATE_DIR/softlock/recovery-attempt" "$STATE_DIR/softlock/last-recovery-attempt" 2>/dev/null || :
  rm -f "$STATE_DIR/softlock/recovery-attempt"
  log HEALTH 'Prior softlock rescue latch released after Vector healthy restoration'
fi
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
