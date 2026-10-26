#!/system/bin/sh
# Emergency-only restoration of the exact DB family preserved by Guardian one-shot.
# Invoke *only* from custom recovery with /data mounted and decrypted.
set -u
[ "${1:-}" = restore ] && [ "${2:-}" = --offline ] && [ -z "${3:-}" ] || {
  echo 'Usage (CUSTOM RECOVERY ONLY): sh one-shot-offline-undo.sh restore --offline' >&2
  exit 2
}
DB="${GUARDIAN_VECTOR_DB:-/data/adb/lspd/config/modules_config.db}"
ROOT="${GUARDIAN_STATE_DIR:-/data/adb/lsposed-guardian}/one-shot/transaction"
SAVE_BASE="${GUARDIAN_OFFLINE_SAVE_ROOT:-/data/local/tmp/guardian-rescue}"
SAVE="$SAVE_BASE/one-shot-emergency-$(date +%Y%m%dT%H%M%S)-$$"
MOD_DIR="${GUARDIAN_MODULE_DIR:-/data/adb/modules/lsposed_guardian}"

[ "$(id -u)" = 0 ] || { echo 'FAIL_ONE_SHOT_UNDO: root required' >&2; exit 1; }
if [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || [ -n "$(pidof vectord 2>/dev/null)" ]; then
  echo 'FAIL_ONE_SHOT_UNDO: Android or Vector running; CUSTOM RECOVERY ONLY' >&2;exit 1
fi
[ -s "$ROOT/original.db" ] && [ -d "${DB%/*}" ] || {
  echo 'FAIL_ONE_SHOT_UNDO: original family missing; use guardian-recover.sh instead' >&2;exit 1;
}
osr_hash_file() {
  if [ -x /system/bin/sha256sum ]; then
    /system/bin/sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}'
  elif command -v toybox >/dev/null 2>&1; then
    toybox sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}'
  elif command -v busybox >/dev/null 2>&1; then
    busybox sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}'
  else return 1; fi
}
for EXT in '' -wal -shm -journal; do
  if [ -f "$ROOT/original.db$EXT" ]; then
    [ -s "$ROOT/original.sha$EXT" ] || exit 1
    HASH="$(osr_hash_file "$ROOT/original.db$EXT")"
    [ -n "$HASH" ] && [ "$HASH" = "$(cat "$ROOT/original.sha$EXT")" ] || {
      echo "FAIL_ONE_SHOT_UNDO: original checksum mismatch ($EXT)" >&2;exit 1;
    }
  else
    [ -f "$ROOT/absent$EXT" ] || { echo "FAIL_ONE_SHOT_UNDO: incomplete journal ($EXT)" >&2;exit 1; }
  fi
done
[ ! -e "$SAVE" ] || exit 1
mkdir -p "$SAVE" || exit 1
chmod 700 "$SAVE" || exit 1
for EXT in '' -wal -shm -journal; do
  [ ! -e "$DB$EXT" ] || cp -p "$DB$EXT" "$SAVE/pre-undo.db$EXT" || exit 1
done
sync
# Prepare a full set before touching the live database family.
cp "$ROOT/original.db" "$SAVE/new.db" || exit 1
for EXT in -wal -shm -journal; do
  [ ! -f "$ROOT/original.db$EXT" ] || cp "$ROOT/original.db$EXT" "$SAVE/new.db$EXT" || exit 1
done
for EXT in '' -wal -shm -journal; do
  [ ! -e "$SAVE/new.db$EXT" ] || { chown 0:0 "$SAVE/new.db$EXT" && chmod 660 "$SAVE/new.db$EXT"; } || exit 1
done
# Label the prepared family before switching. Fail safely if recovery cannot do so.
for EXT in '' -wal -shm -journal; do
  [ ! -e "$SAVE/new.db$EXT" ] || chcon u:object_r:system_file:s0 "$SAVE/new.db$EXT" || {
    echo 'FAIL_ONE_SHOT_UNDO: SELinux chcon unavailable; use validated recovery rescue procedure' >&2;exit 1
  }
done
: > "$SAVE/RESTORE_STARTED" || exit 1
sync
for EXT in -wal -shm -journal; do
  [ ! -e "$DB$EXT" ] || mv "$DB$EXT" "$SAVE/retired.db$EXT" || exit 1
done
mv "$SAVE/new.db" "$DB" || exit 1
for EXT in -wal -shm -journal; do
  [ ! -e "$SAVE/new.db$EXT" ] || mv "$SAVE/new.db$EXT" "$DB$EXT" || exit 1
done
sync
[ "$(osr_hash_file "$DB")" = "$(cat "$ROOT/original.sha")" ] || exit 1
# Ensure Guardian won't re-run a pending one-shot hook until reviewed.
mkdir -p "$MOD_DIR"
: > "$MOD_DIR/disable" || exit 1
: > "$SAVE/RESTORE_CONFIRMED" || exit 1
sync
echo 'PASS_GUARDIAN_ONE_SHOT_OFFLINE_UNDO'
echo "pre_undo_family=$SAVE"
echo 'guardian_disabled=yes (until manually re-enabled)'
