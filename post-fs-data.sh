#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 0
. "$MODDIR/lib/boot-probe.sh" || exit 0
. "$MODDIR/lib/boot-trial.sh" || exit 0
. "$MODDIR/lib/one-shot.sh" || exit 0
. "$MODDIR/lib/safe-mode.sh" || exit 0
init_state || exit 0
load_config
bp_early || :
bt_early || :
os_early || :
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

# Retired legacy unjournaled auto SQLite restore: never call offline_restore.
# Bootloop response is an opt-in KernelSU safe-mode marker only.
sm_early || :
if [ -f "$BOOT_DIR/manual-restore" ]; then
  log WARN 'Legacy manual restore queue ignored; use guarded one-shot staging'
fi
exit 0
