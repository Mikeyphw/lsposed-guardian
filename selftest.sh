#!/system/bin/sh
# Test the crash pipeline in an isolated root-only temporary directory.
# No logcat read, real crashes, Vector mutations, module toggles, or reboots.
case "$0" in */*) MODDIR="${0%/*}" ;; *) MODDIR=. ;; esac
. "$MODDIR/lib/common.sh" || exit 1
. "$MODDIR/lib/crash.sh" || exit 1
umask 077
TEST_HOME="$STATE_DIR/selftests"
mkdir -p "$TEST_HOME" || exit 1
chmod 700 "$TEST_HOME" 2>/dev/null || :
TESTDIR="$TEST_HOME/run-$$"
mkdir "$TESTDIR" || exit 1
trap 'rm -rf "$TESTDIR"' EXIT HUP INT TERM
CRASH_DIR="$TESTDIR/crashes"
CRASH_FILE="$CRASH_DIR/events.tsv"
crash_init || exit 1
cat > "$TESTDIR/input" <<'SYNTHETIC'
1792451234.001 200 300 E AndroidRuntime: Process: guardian.test.app, PID: 123
1792451234.001 200 300 E AndroidRuntime: Process: guardian.test.app, PID: 123
1792451235.002 200 300 E AndroidRuntime: Process: guardian.test.app:worker, PID: 124
1792451236.003 200 300 E OtherTag: Process: guardian.test.innocent, PID: 125
1792451237.003 200 300 E AndroidRuntime: Process: invalid;rm, PID: 126
SYNTHETIC
crash_parse_file "$TESTDIR/input" "$TESTDIR/parsed" 'aaaaaaaa-0000' || exit 1
crash_merge_file "$TESTDIR/parsed" || exit 1
[ "$(crash_count_all)" = 2 ] || { echo 'FAIL: parser/filter' >&2; exit 1; }
crash_merge_file "$TESTDIR/parsed" || exit 1
[ "$(crash_count_all)" = 2 ] || { echo 'FAIL: duplicate ingestion' >&2; exit 1; }
cat > "$TESTDIR/input" <<'SYNTHETIC'
1792452234.001 200 300 E AndroidRuntime: Process: guardian.test.app, PID: 500
SYNTHETIC
crash_parse_file "$TESTDIR/input" "$TESTDIR/parsed" 'bbbbbbbb-0000' || exit 1
crash_merge_file "$TESTDIR/parsed" || exit 1
[ "$(crash_count_all)" = 3 ] || { echo 'FAIL: cross-boot persistence' >&2; exit 1; }
grep -q '^aaaaaaaa-0000' "$CRASH_FILE" || { echo 'FAIL: earlier boot missing' >&2; exit 1; }
grep -q '^bbbbbbbb-0000' "$CRASH_FILE" || { echo 'FAIL: later boot missing' >&2; exit 1; }
echo 'PASS_GUARDIAN_ISOLATED_CRASH_PIPELINE: parse=PASS deduplicate=PASS cross_boot=PASS real_history_untouched=true'
