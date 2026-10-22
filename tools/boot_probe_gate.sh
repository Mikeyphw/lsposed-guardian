#!/system/bin/sh
# Devtool opt-in real-device read-only boot ordering qualification.
# Writes only an opt-in state marker for the next reboot.
set -u
KIND="${1:-}"
case "$KIND" in
  stage) ARG='boot-probe-stage --apply' ;;
  status) ARG='boot-probe-status' ;;
  *) echo 'Expected stage|status' >&2; exit 2 ;;
esac
GUARDIAN=/data/adb/modules/lsposed_guardian/guardian.sh
OUT="$(mktemp)" || exit 1
su -c "sh '$GUARDIAN' $ARG" > "$OUT" 2>&1
RC=$?
cat "$OUT"
echo "boot_probe_${KIND}_exit_code=$RC"
if command -v termux-clipboard-set >/dev/null 2>&1; then
  termux-clipboard-set < "$OUT" && echo 'clipboard=COPIED' || echo "clipboard=FAILED evidence=$OUT"
fi
[ "$RC" -eq 0 ] && rm -f "$OUT"
exit "$RC"
