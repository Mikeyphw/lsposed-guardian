#!/system/bin/sh
# Real DB mutation is never part of check/install or CI. Stage is separately explicit.
case "${1:-}" in
  preflight) ARG='one-shot-preflight' ;;
  stage) ARG='one-shot-stage --apply' ;;
  status) ARG='one-shot-status' ;;
  cancel) ARG='one-shot-cancel' ;;
  *) echo 'Expected preflight|stage|status|cancel' >&2; exit 2 ;;
esac
GUARDIAN=/data/adb/modules/lsposed_guardian/guardian.sh
OUT="$(mktemp)" || exit 1
su -c "sh '$GUARDIAN' $ARG" > "$OUT" 2>&1
RC=$?
cat "$OUT"
printf 'one_shot_%s_exit_code=%s\n' "$1" "$RC"
if command -v termux-clipboard-set >/dev/null 2>&1; then
  termux-clipboard-set < "$OUT" && echo 'clipboard=COPIED' || echo "clipboard=FAILED log=$OUT"
fi
[ "$RC" -ne 0 ] || rm -f "$OUT"
exit "$RC"
