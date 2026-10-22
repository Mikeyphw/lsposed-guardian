#!/system/bin/sh
# Devtool opt-in real-boot COPY-ONLY Vector WAL rehearsal; never swaps live DB.
set -u
KIND="${1:-}"
case "$KIND" in
  stage) ARG='boot-trial-stage --apply' ;;
  status) ARG='boot-trial-status' ;;
  cancel) ARG='boot-trial-cancel' ;;
  *) echo 'Expected stage|status|cancel' >&2; exit 2 ;;
esac
GUARDIAN=/data/adb/modules/lsposed_guardian/guardian.sh
OUT="$(mktemp)" || exit 1
su -c "sh '$GUARDIAN' $ARG" > "$OUT" 2>&1
RC=$?
cat "$OUT"
echo "boot_trial_${KIND}_exit_code=$RC"
if command -v termux-clipboard-set >/dev/null 2>&1; then
  termux-clipboard-set < "$OUT" && echo 'clipboard=COPIED' || echo "clipboard=FAILED evidence=$OUT"
fi
[ "$RC" -eq 0 ] && rm -f "$OUT"
exit "$RC"
