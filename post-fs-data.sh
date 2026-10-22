#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/boot-probe.sh" || exit 0
init_state || exit 0
load_config
bp_early || :
ID="$(boot_id)"
[ -n "$ID" ] || { log ERROR 'Boot ID missing, refusing recovery'; exit 0; }
CURRENT="$(read_first "$BOOT_DIR/current-id")"
[ "$ID" = "$CURRENT" ] && { log BOOT 'Same kernel boot ID, skipping duplicate/soft restart'; exit 0; }

# Previous hardware boot was never declared healthy by the service.
PENDING="$(read_first "$BOOT_DIR/pending-id")"
FAILURES="$(read_first "$BOOT_DIR/failures")"
is_number "$FAILURES" || FAILURES=0
if [ -n "$PENDING" ] && [ "$PENDING" != "$ID" ]; then
  FAILURES=$((FAILURES + 1))
  log BOOT "Previous boot did not reach stability; failures=$FAILURES"
else
  log BOOT 'New boot observation started'
fi
write_atomic "$BOOT_DIR/failures" "$FAILURES" || exit 0
write_atomic "$BOOT_DIR/current-id" "$ID" || exit 0
write_atomic "$BOOT_DIR/pending-id" "$ID" || exit 0

SNAP="$SNAP_DIR/last-good.db"
if [ "$RECOVERY_DEVICE_QUALIFIED" != 1 ]; then
  [ ! -f "$BOOT_DIR/manual-restore" ] || log WARN 'Manual restore queued but offline restore is not device-qualified; refusing'
elif [ -f "$BOOT_DIR/manual-restore" ]; then
  if offline_restore "$SNAP"; then
    rm -f "$BOOT_DIR/manual-restore"
    write_atomic "$BOOT_DIR/last-recovery-id" "$ID"
    write_atomic "$BOOT_DIR/recovery-performed" 1
  fi
elif [ "$AUTO_RECOVERY" = 1 ] && [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
  if [ -f "$BOOT_DIR/recovery-performed" ]; then
    log WARN 'Recovery already attempted this incident; no repeated mutation'
  elif offline_restore "$SNAP"; then
    write_atomic "$BOOT_DIR/recovery-performed" 1
    write_atomic "$BOOT_DIR/last-recovery-id" "$ID"
  else
    log WARN 'Recovery declined or failed; state preserved'
  fi
fi
exit 0
