#!/system/bin/sh
# Read-only fixed-path digest probe; no updates, no installer invocation.
set -u
[ "$(id -u)" = 0 ] || exit 1
if [ -x /system/bin/sha256sum ]; then
  H=/system/bin/sha256sum
else
  H="$(command -v sha256sum 2>/dev/null)"
fi
[ -n "$H" ] || exit 2
for TYPE in ACTIVE STAGED; do
  case "$TYPE" in
    ACTIVE) DIR=/data/adb/modules/lsposed_guardian ;;
    STAGED) DIR=/data/adb/modules_update/lsposed_guardian ;;
  esac
  if [ ! -d "$DIR" ]; then echo "$TYPE|ABSENT"; continue; fi
  for NAME in module.prop guardian.sh lib/crash.sh lib/qualification.sh lib/one-shot.sh post-fs-data.sh service.sh lib/common.sh lib/auto-quarantine.sh lib/safe-mode.sh crash-monitor.sh lib/quarantine.sh; do
    P="$DIR/$NAME"
    if [ ! -f "$P" ]; then echo "$TYPE|$NAME|MISSING"; continue; fi
    HASH="$("$H" "$P" 2>/dev/null | awk '{print $1}')"
    case "$HASH" in
      ????????????????????????????????????????????????????????????????)
        case "$HASH" in *[!a-f0-9]*) exit 3 ;; esac ;;
      *) exit 3 ;;
    esac
    echo "$TYPE|$NAME|$HASH"
  done
done
