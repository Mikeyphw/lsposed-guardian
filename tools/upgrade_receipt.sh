#!/system/bin/sh
# Root-only upgrade continuity checkpoint; metadata only, no Vector mutation.
set -u
case "${1:-}" in pre-install|post-install) PHASE="$1" ;; *) echo 'Expected pre-install or post-install' >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo 'root required for receipt' >&2; exit 1; }
STATE=/data/adb/lsposed-guardian
LOG="$STATE/upgrade/receipts.tsv"
[ -d "$STATE" ] || { echo 'Guardian state directory missing' >&2; exit 1; }
mkdir -p "$STATE/upgrade" || exit 1
chmod 700 "$STATE/upgrade" || exit 1
HASHER=/system/bin/sha256sum
[ -x "$HASHER" ] || HASHER="$(command -v sha256sum 2>/dev/null)"
[ -n "$HASHER" ] || { echo 'SHA-256 unavailable' >&2; exit 1; }
CRASH="$STATE/crashes/events.tsv"
if [ -f "$CRASH" ]; then
  COUNT="$(wc -l < "$CRASH" | tr -d ' ')"
  CRASH_HASH="$("$HASHER" "$CRASH" | awk '{print $1}')"
else
  COUNT=0
  CRASH_HASH=missing
fi
case "$COUNT" in ''|*[!0-9]*) exit 1 ;; esac
case "$CRASH_HASH" in missing) :;; *[!a-f0-9]*|'') exit 1;; esac
TX="$STATE/one-shot/transaction/phase"
RESTORE="$STATE/one-shot/transaction"
if [ -f "$TX" ]; then TX_PHASE="$(head -n 1 "$TX" | tr -cd 'A-Z_')"; else TX_PHASE=none; fi
RESTORE_FILE="$STATE/one-shot/early.txt"
if [ -f "$RESTORE_FILE" ]; then RESTORE_HASH="$("$HASHER" "$RESTORE_FILE" | awk '{print $1}')"; else RESTORE_HASH=missing; fi
case "$RESTORE_HASH" in missing) :;; *[!a-f0-9]*|'') exit 1;; esac
BID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -cd 'a-fA-F0-9-')"
case "$BID" in ''|*[!a-fA-F0-9-]*) exit 1 ;; esac
# Preserve no process names and no sensitive Vector configuration.
LINE="$(date +%s)\t$PHASE\t$BID\t$COUNT\t$CRASH_HASH\t$TX_PHASE\t$RESTORE_HASH"
# POSIX printf %b decodes only constructed tab delimiters; no untrusted strings.
printf '%b\n' "$LINE" >> "$LOG" || exit 1
chmod 600 "$LOG" 2>/dev/null || :
echo "PASS_GUARDIAN_UPGRADE_RECEIPT phase=$PHASE crash_count=$COUNT"
