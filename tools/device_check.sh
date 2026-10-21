#!/bin/sh
# Native Termux read-only acceptance. Full stdout/stderr copied to Termux clipboard.
set -u
G=/data/adb/modules/lsposed_guardian/guardian.sh
OUT=$(mktemp "${TMPDIR:-/data/local/tmp}/guardian-check.XXXXXX") || exit 1
status=0
{
  for task in selftest doctor quarantine-lab recovery-lab qualification integrity report; do
    printf '\n=== %s ===\n' "$task"
    su -c "'$G' $task"
    rc=$?
    printf 'exit_code=%s\n' "$rc"
    [ "$rc" -eq 0 ] || status=1
  done
} > "$OUT" 2>&1
cat "$OUT"
if command -v termux-clipboard-set >/dev/null 2>&1 && termux-clipboard-set < "$OUT"; then
  echo 'PASS_GUARDIAN_OUTPUT_COPIED_TO_TERMUX_CLIPBOARD'
  rm -f "$OUT"
else
  echo "Clipboard unavailable; diagnostics saved: $OUT"
fi
exit "$status"
