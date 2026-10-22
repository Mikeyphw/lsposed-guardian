#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/lib/common.sh" || exit 1
. "$MODDIR/lib/crash.sh" || exit 1
. "$MODDIR/lib/history.sh" || exit 1
. "$MODDIR/lib/quarantine.sh" || exit 1
. "$MODDIR/lib/recovery-lab.sh" || exit 1
. "$MODDIR/lib/quarantine-lab.sh" || exit 1
. "$MODDIR/lib/qualification.sh" || exit 1
. "$MODDIR/lib/boot-probe.sh" || exit 1
. "$MODDIR/lib/policy.sh" || exit 1
init_state || { echo 'Cannot initialize Guardian state (root required)' >&2; exit 1; }
load_config

help_text() {
  cat <<'USAGE'
LSPosed Guardian (Vector adapter)
Usage: guardian.sh COMMAND [ARGS]

  status            Show recovery state and current framework health
  report            Emit machine-readable JSON diagnostic evidence
  doctor            Diagnose boot recovery, Vector CLI, backup and AshLooper
  modules           List enabled/disabled modules using Vector CLI
  suspects APP      List active modules with APP in their scope (read-only)
  crashes           Show crash-buffer process counts (read-only)
  collect           Capture bounded read-only crash event history now
  selftest          Test crash parsing, deduplication and persistence in isolation
  events            Show last 30 saved crash events (with fresh capture)
  triage            Summarize retained crash events by process (no logcat read)
  collector-health  Show poll outcome and last recorded failure reason
  correlate APP     Show recent crash count and explicitly scoped enabled modules
  snapshot          Capture current Vector config as OBSERVED (never overwrite pinned baseline)
  changes           Diff currently enabled modules against pinned recovery baseline
  assess APP        Read-only crash history + current scope candidates + baseline delta
  history           Show last 12 sampled Vector config checkpoints
  history-health    Show latest historical sampler heartbeat
  history-capture   Take a timestamped read-only enabled-module/scope checkpoint
  decision APP      Conservative historical crash correlation; never toggles modules
  recovery-plan APP Review-only escalation plan; never toggles modules
  recovery-lab      Verify staged restore mechanics on ISOLATED copied database
  quarantine-lab    Fault-inject real quarantine logic against ISOLATED fake Vector
  qualification     Read-only recovery qualification boundaries and lab outcomes
  promote --apply   Explicitly replace pinned recovery baseline with current Vector snapshot
  integrity         Read-only snapshot checksum/SQLite validation status
  quarantine-status Show active or interrupted manual quarantines
  panel             Compact read-only management overview (Termux-friendly)
  quarantine-ledger Show sanitized manual toggle ledger (read-only)
  boot-probe-stage --apply  Record read-only early boot probe on next hardware boot
  boot-probe-status         Inspect post-fs-data and subsequent Vector health evidence
  quarantine PKG    Preview single-module quarantine
  quarantine PKG --apply  Disable one Vector module and save rollback evidence
  rollback PKG --apply    Re-enable only a Guardian-quarantined module
  quarantine-reconcile PKG --apply  Resolve interrupted disable transaction
  rollback-reconcile PKG --apply  Resolve interrupted rollback transaction
  arm               Enable recovery only after device qualification
  disarm            Observe only; never automatically restore
  restore --apply   Queue known-good database restore for the NEXT hardware boot
  cancel-restore    Cancel a queued manual restore
  disable PACKAGE   Disable one module through Vector; does not restart apps
  enable PACKAGE    Re-enable one module through Vector; does not restart apps
  scope PACKAGE     Show that module's scope using Vector
  reset-failures    Reset the failed-boot counter and recovery latch
  help              Show help

Automatic app-crash quarantining remains disabled in this release.
Snapshots retain all Vector module data, scopes and preferences. Disable/enable
changes apply to newly spawned processes; existing hooks may persist until restart.
USAGE
}

set_auto() {
  TARGET="$1"
  [ -f "$CFG" ] || return 1
  TEMP="$CFG.tmp.$$"
  grep -q '^AUTO_RECOVERY=' "$CFG" || { echo 'Missing AUTO_RECOVERY config; refusing change' >&2; return 1; }
  if ! sed "s/^AUTO_RECOVERY=.*/AUTO_RECOVERY=$TARGET/" "$CFG" > "$TEMP"; then return 1; fi
  chmod 600 "$TEMP" 2>/dev/null || :
  mv -f "$TEMP" "$CFG" || return 1
  log CONFIG "Auto recovery set to $TARGET"
  echo "AUTO_RECOVERY=$TARGET"
}

check_pkg() {
  case "$1" in
    ''|lspd|*[!a-zA-Z0-9_.]*|.*|*..*|*.)
      echo 'Invalid module package or protected framework pseudo-module' >&2; return 1;;
    *.*) return 0;;
    *) echo 'Expected an Android package name with at least one dot' >&2; return 1;;
  esac
}

check_target() {
  [ "$1" = system_server ] && return 0
  check_pkg "$1"
}

status() {
  echo "LSPosed Guardian $(guardian_version)"
  echo "mode=$([ "$AUTO_RECOVERY" = 1 ] && echo ARMED || echo OBSERVE)"
  echo "boot_id=$(boot_id)"
  echo "pending_boot=$(read_first "$BOOT_DIR/pending-id")"
  echo "last_stable_boot=$(read_first "$BOOT_DIR/last-success-id")"
  echo "consecutive_failed_boots=$(read_first "$BOOT_DIR/failures")"
  echo "failure_threshold=$FAILURE_THRESHOLD"
  echo "stable_observation_seconds=$STABILITY_SECONDS"
  echo "manual_restore_queued=$([ -f "$BOOT_DIR/manual-restore" ] && echo yes || echo no)"
  echo "recovery_attempted=$([ -f "$BOOT_DIR/recovery-performed" ] && echo yes || echo no)"
  echo "snapshot=$({ recovery_baseline_ready && echo available; } || echo unqualified_or_missing)"
  echo "snapshot_validation=$(snapshot_integrity_level last-good)"
  echo "sqlite_verifier=$({ sqlite_tool >/dev/null && echo available; } || echo unavailable)"
  echo "device_restore_qualified=$RECOVERY_DEVICE_QUALIFIED"
  echo "baseline_policy=pinned"
  echo "baseline_boot=$(baseline_boot_label)"
  echo "baseline_provenance=$(baseline_provenance)"
  echo "observed_boot=$(read_first "$SNAP_DIR/observed.complete")"
  echo "vector_cli=$([ -x "$VECTOR_CLI" ] && echo available || echo missing)"
  echo "vector_db=$([ -f "$DB" ] && echo available || echo missing)"
  echo "state_directory=$STATE_DIR"
  echo "quarantine_active=$(find "$STATE_DIR/quarantine/active" -maxdepth 1 -name '*.record' -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "quarantine_pending=$(find "$STATE_DIR/quarantine/pending" -maxdepth 1 -type f \( -name '*.record' -o -name '*.rollback' \) 2>/dev/null | wc -l | tr -d ' ')"
  echo "passive_crash_monitor=$([ "$PASSIVE_CRASH_MONITOR" = 1 ] && echo enabled || echo disabled)"
  echo "stored_crash_events=$(crash_count_all)"
  echo "historical_checkpoints=$([ -f "$HIST_INDEX" ] && wc -l < "$HIST_INDEX" | tr -d ' ' || echo 0)"
  echo "history_recent_poll=$({ history_recent_poll && echo yes; } || echo no)"
  echo "collector_recent_poll=$({ monitor_recent_poll && echo yes; } || echo no)"
  echo "collector_last_poll_epoch=$(read_first "$MON_DIR/last-epoch")"
  echo "collector_last_poll_result=$(read_first "$MON_DIR/last-result")"
  echo "collector_last_poll_reason=$(read_first "$MON_DIR/last-reason")"
  echo "collector_last_failure_boot=$(read_first "$MON_DIR/last-failure-boot")"
  echo "collector_last_failure_reason=$(read_first "$MON_DIR/last-failure-reason")"
  echo "collector_last_failure_epoch=$(read_first "$MON_DIR/last-failure-epoch")"
  echo '--- Vector ---'
  vector status 2>&1 || echo 'Vector daemon not reachable'
}

doctor() {
  status
  echo '--- Diagnostics ---'
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    echo 'AshLooper/AshReXcue: detected; Guardian never initiates reboots'
  else
    echo 'AshLooper/AshReXcue: not detected at common module IDs'
  fi
  if [ -f "$DB-wal" ]; then echo 'Vector WAL: present (expected while live; never edit DB now)'; fi
  echo "Snapshot verification: $(snapshot_integrity_level last-good)"
  if [ -f "$SNAP_DIR/baseline-in-progress" ]; then echo 'Recovery baseline: update interrupted; restore and arming blocked'; fi
  echo '--- Recent Guardian log ---'
  [ ! -f "$LOG_DIR/guardian.log" ] || tail -n 20 "$LOG_DIR/guardian.log"
}

# All commands that affect the daemon go through Vector's own authenticated CLI.
case "${1:-help}" in
  help|-h|--help) help_text ;;
  status) status ;;
  report)
    if [ "${2:-}" != '' ]; then echo 'report takes no parameters' >&2; exit 2; fi
    if recovery_baseline_ready; then SNAPSHOT_VALID=true; else SNAPSHOT_VALID=false; fi
    if cli_ready; then CLI_AVAILABLE=true; else CLI_AVAILABLE=false; fi
    if [ -f "$BOOT_DIR/manual-restore" ]; then QUEUED=true; else QUEUED=false; fi
    if [ -f "$BOOT_DIR/recovery-performed" ]; then ATTEMPTED=true; else ATTEMPTED=false; fi
    FAILURES="$(read_first "$BOOT_DIR/failures")"
    is_number "$FAILURES" || FAILURES=0
    # Kernel boot IDs are restricted to hex, hyphens; never emit untrusted data unescaped.
    ID="$(boot_id | tr -cd 'a-fA-F0-9-')"
    GOOD="$(read_first "$BOOT_DIR/last-success-id" | tr -cd 'a-fA-F0-9-')"
    printf '{"schema_version":1,"producer":"lsposed-guardian","version":"%s","qualification":"UNQUALIFIED",' "$(guardian_version)"
    printf '"timestamp_utc":"%s","boot_id":"%s","last_stable_boot_id":"%s",' "$(stamp)" "$ID" "$GOOD"
    printf '"recovery_armed":%s,"consecutive_failed_boots":%s,"failure_threshold":%s,' "$([ "$AUTO_RECOVERY" = 1 ] && echo true || echo false)" "$FAILURES" "$FAILURE_THRESHOLD"
    EVENT_COUNT="$(crash_count_all)"
    printf '"snapshot_valid":%s,"vector_cli_available":%s,"manual_restore_queued":%s,"recovery_attempted":%s,' "$SNAPSHOT_VALID" "$CLI_AVAILABLE" "$QUEUED" "$ATTEMPTED"
    H_COUNT="$([ -f "$HIST_INDEX" ] && wc -l < "$HIST_INDEX" | tr -d ' ' || echo 0)"
    printf '"stored_crash_events":%s,"historical_checkpoints":%s,"passive_crash_monitor":%s,' "$EVENT_COUNT" "$H_COUNT" "$([ "$PASSIVE_CRASH_MONITOR" = 1 ] && echo true || echo false)"
    if monitor_recent_poll; then MON_RECENT=true; else MON_RECENT=false; fi
    MON_AT="$(read_first "$MON_DIR/last-epoch")"
    is_number "$MON_AT" || MON_AT=0
    MON_RESULT="$(read_first "$MON_DIR/last-result")"
    case "$MON_RESULT" in ok|error|busy) : ;; *) MON_RESULT=unknown ;; esac
    MON_REASON="$(read_first "$MON_DIR/last-reason")"
    case "$MON_REASON" in ok|unknown|state-unavailable|logcat-missing|collector-busy|boot-id-unavailable|logcat-failed|parse-failed|history-merge-failed) : ;; *) MON_REASON=unknown ;; esac
    FAIL_REASON="$(read_first "$MON_DIR/last-failure-reason")"
    case "$FAIL_REASON" in
      '') FAIL_REASON_JSON=null ;;
      state-unavailable|logcat-missing|boot-id-unavailable|logcat-failed|parse-failed|history-merge-failed) FAIL_REASON_JSON="\"$FAIL_REASON\"" ;;
      *) FAIL_REASON_JSON='"unknown"' ;;
    esac
    Q_ACTIVE="$(find "$STATE_DIR/quarantine/active" -maxdepth 1 -name '*.record' -type f 2>/dev/null | wc -l | tr -d ' ')"
    Q_PENDING="$(find "$STATE_DIR/quarantine/pending" -maxdepth 1 -type f \( -name '*.record' -o -name '*.rollback' \) 2>/dev/null | wc -l | tr -d ' ')"
    if history_recent_poll; then H_RECENT=true; else H_RECENT=false; fi
    H_RESULT="$(read_first "$HIST_DIR/last-result")"
    case "$H_RESULT" in ok|error|busy) : ;; *) H_RESULT=unknown ;; esac
    printf '"history_recent_poll":%s,"history_last_poll_result":"%s",' "$H_RECENT" "$H_RESULT"
    printf '"quarantine_active":%s,"quarantine_pending":%s,"automatic_quarantine_enabled":false,"excluded_crash_packages":["com.openai.chatgpt"],' "$Q_ACTIVE" "$Q_PENDING"
    printf '"collector_recent_poll":%s,"collector_last_poll_epoch":%s,"collector_last_poll_result":"%s","collector_last_poll_reason":"%s","collector_last_failure_reason":%s,' "$MON_RECENT" "$MON_AT" "$MON_RESULT" "$MON_REASON" "$FAIL_REASON_JSON"
        # Metadata pre-dating v0.5 has no recorded origin boot; report null rather than inventing one.
    BASELINE_BOOT="$(read_first "$SNAP_DIR/last-good.boot-id")"
    BASELINE_BOOT="$(printf '%s' "$BASELINE_BOOT" | tr -cd 'a-zA-Z0-9-')"
    if [ -n "$BASELINE_BOOT" ]; then BASELINE_BOOT_JSON="\"$BASELINE_BOOT\""; else BASELINE_BOOT_JSON=null; fi
    printf '"baseline_policy":"pinned","baseline_boot_id":%s,"baseline_provenance":"%s","snapshot_validation":"%s","observed_snapshot_available":%s}\n' \
      "$BASELINE_BOOT_JSON" "$(baseline_provenance)" "$(snapshot_integrity_level last-good)" "$([ "$(read_first "$SNAP_DIR/observed.complete")" = "$(boot_id | tr -cd 'a-fA-F0-9-')" ] && echo true || echo false)"
    ;;
  doctor) doctor ;;
  panel)
    echo "LSPOSED GUARDIAN $(guardian_version) / READ-ONLY PANEL"
    echo '------------------------------------------------'
    # Local state only: do not invoke the Vector daemon or the heavyweight
    # full doctor command from this compact panel.
    echo "mode=$([ "$AUTO_RECOVERY" = 1 ] && echo ARMED || echo OBSERVE)"
    echo "last_stable_boot=$(read_first "$BOOT_DIR/last-success-id")"
    echo "device_restore_qualified=$RECOVERY_DEVICE_QUALIFIED"
    echo "collector_recent_poll=$({ monitor_recent_poll && echo yes; } || echo no)"
    echo "history_recent_poll=$({ history_recent_poll && echo yes; } || echo no)"
    echo '--- Recovery ---'
    echo "observed=$(snapshot_integrity_level observed)"
    echo "baseline=$(snapshot_integrity_level last-good)"
    echo '--- Quarantine ---'
    q_status
    echo '--- Last historical samples ---'
    history_recent | tail -n 4
    echo '--- Controls ---'
    echo 'Open the KernelSU module WebUI for read-only monitoring and previews.'
    echo 'Changes require separate, explicit CLI commands; no automatic actions.'
    ;;
  quarantine-lab)
    [ "${2:-}" = '' ] || { echo 'quarantine-lab takes no options' >&2; exit 2; }
    quarantine_lab ;;
  qualification)
    [ "${2:-}" = '' ] || { echo 'qualification takes no options' >&2; exit 2; }
    qualification_report ;;
  recovery-lab)
    [ "${2:-}" = '' ] || { echo 'recovery-lab takes no options' >&2; exit 2; }
    recovery_lab ;;
  recovery-plan)
    check_target "${2:-}" || exit 2
    [ "${3:-}" = '' ] || { echo 'Unexpected extra arguments' >&2; exit 2; }
    recovery_plan "$2" ;;

  history) history_recent ;;
  history-health) history_health ;;
  history-capture)
    history_capture && echo 'history_capture=ok (read-only Vector sampling)' || { echo 'history_capture=failed' >&2; exit 1; }
    ;;
  decision)
    check_target "${2:-}" || exit 2
    history_decision "$2"
    ;;
  integrity)
    echo "baseline=$(snapshot_integrity_level last-good)"
    echo "observed=$(snapshot_integrity_level observed)"
    echo "sqlite_verifier=$({ sqlite_tool >/dev/null && echo available; } || echo unavailable)"
    echo "device_restore_qualified=$RECOVERY_DEVICE_QUALIFIED"
    ;;
  boot-probe-stage)
    [ "${2:-}" = --apply ] && [ -z "${3:-}" ] || { echo "Requires boot-probe-stage --apply" >&2; exit 2; }
    bp_stage ;;
  boot-probe-status)
    [ -z "${2:-}" ] || { echo "No arguments expected" >&2; exit 2; }
    bp_status ;;
  quarantine-status) q_status ;;
  quarantine-ledger)
    if [ -s "$STATE_DIR/quarantine/events.tsv" ]; then
      cat "$STATE_DIR/quarantine/events.tsv"
    else echo 'No quarantine events'; fi ;;
  quarantine)
    check_pkg "${2:-}" || exit 2
    case "${3:-}" in
      '') q_preview "$2" ;;
      --apply) q_apply "$2" ;;
      *) echo 'Expected quarantine PACKAGE [--apply]' >&2; exit 2 ;;
    esac ;;
  rollback)
    check_pkg "${2:-}" || exit 2
    if [ "${3:-}" != --apply ]; then
      echo 'Preview only: rollback PACKAGE --apply re-enables one Guardian-quarantined module.'
      q_status
    else q_rollback "$2"; fi ;;
  rollback-reconcile)
    check_pkg "${2:-}" || exit 2
    [ "${3:-}" = --apply ] || { echo 'Explicit --apply required for rollback reconciliation' >&2; exit 2; }
    q_reconcile_rollback "$2" ;;
  quarantine-reconcile)
    check_pkg "${2:-}" || exit 2
    [ "${3:-}" = --apply ] || { echo 'Explicit --apply required for reconciliation' >&2; exit 2; }
    q_reconcile "$2" ;;

  modules) vector modules ls ;;
  selftest)
    sh "$MODDIR/selftest.sh"
    ;;
  collect)
    crash_collect || { echo "Crash buffer capture failed: $CR_CAPTURE_REASON" >&2; exit 1; }
    echo "Stored crash events: $(crash_count_all)"
    ;;
  events) crash_show ;;
  triage) crash_triage ;;
  collector-health)
    echo "collector_recent_poll=$({ monitor_recent_poll && echo yes; } || echo no)"
    echo "collector_last_poll_boot=$(read_first "$MON_DIR/last-boot")"
    echo "collector_last_poll_epoch=$(read_first "$MON_DIR/last-epoch")"
    echo "collector_last_poll_result=$(read_first "$MON_DIR/last-result")"
    echo "collector_last_poll_reason=$(read_first "$MON_DIR/last-reason")"
    echo "collector_last_failure_boot=$(read_first "$MON_DIR/last-failure-boot")"
    echo "collector_last_failure_epoch=$(read_first "$MON_DIR/last-failure-epoch")"
    echo "collector_last_failure_reason=$(read_first "$MON_DIR/last-failure-reason")"
    echo 'Note: prior v0.3 failures do not contain a reason; raw logcat errors are not retained.'
    ;;
  correlate)
    TARGET="${2:-}"
    check_target "$TARGET" || exit 2
    crash_collect || echo 'Crash buffer unavailable, using retained event history' >&2
    CR_N="$(crash_count_recent "$TARGET")"
    case ",$CRASH_EXCLUDE_PACKAGES," in *,$TARGET,*) echo "recovery_decision=EXCLUDED_BY_USER" ;; esac
    echo "Recent crashes for $TARGET: $CR_N in ${CRASH_WINDOW_SECONDS}s"
    if [ "$CR_N" -ge 3 ]; then
      echo 'Repeated crashes observed; this alone does not identify an Xposed module'
    else
      echo 'No repeated crash pattern established in the time window'
    fi
    sh "$MODDIR/guardian.sh" suspects "$TARGET"
    ;;
  snapshot)
    if ! boot_complete; then echo 'Boot is not completed; snapshot refused' >&2; exit 1; fi
    successful_snapshot || exit 1
    echo "Observed: $SNAP_DIR/observed.db (pinned recovery baseline unchanged)"
    ;;
  changes)
    if [ ! -f "$SNAP_DIR/last-good.enabled" ]; then echo 'No pinned module manifest is available' >&2; exit 1; fi
    NOW_MAN="$STATE_DIR/changes-now-$$.enabled"
    if ! vector_enabled_manifest "$NOW_MAN"; then
      echo 'Cannot obtain current enabled modules; refusing to infer changes' >&2; exit 1
    fi
    echo 'Current enabled modules vs pinned recovery baseline (not crash causality):'
    echo "  baseline_boot=$(baseline_boot_label)"
    echo "  baseline_provenance=$(baseline_provenance)"
    echo '  Enabled since baseline:'
    DELTA="$(LC_ALL=C grep -Fxv -f "$SNAP_DIR/last-good.enabled" "$NOW_MAN" || :)"
    [ -z "$DELTA" ] && echo '    (none)' || printf '%s\n' "$DELTA" | sed 's/^/    + /'
    echo '  Disabled since baseline:'
    DELTA="$(LC_ALL=C grep -Fxv -f "$NOW_MAN" "$SNAP_DIR/last-good.enabled" || :)"
    [ -z "$DELTA" ] && echo '    (none)' || printf '%s\n' "$DELTA" | sed 's/^/    - /'
    rm -f "$NOW_MAN"
    ;;
  assess)
    TARGET="${2:-}"
    check_target "$TARGET" || exit 2
    echo "Read-only assessment: $TARGET"
    case ",$CRASH_EXCLUDE_PACKAGES," in *,$TARGET,*) echo "recovery_decision=EXCLUDED_BY_USER (not evidence of LSPosed failure)" ;; esac
    if [ -s "$CRASH_FILE" ]; then
      awk -F '\t' -v pkg="$TARGET" '
        $3 == pkg || index($3, pkg ":") == 1 { count++; if (last < $2+0) last=$2+0; boots[$1]=1 }
        END {for (b in boots) n++; printf "Retained crashes=%d across_boots=%d latest_epoch=%.0f\n",count+0,n+0,last+0}
      ' "$CRASH_FILE"
    else
      echo 'Retained crashes=0 across_boots=0 latest_epoch=0'
    fi
    sh "$MODDIR/guardian.sh" suspects "$TARGET" || exit 1
    sh "$MODDIR/guardian.sh" changes || exit 1
    echo 'No causal attribution: current scopes and modules may differ from those at crash time.'
    ;;
  promote)
    if [ "${2:-}" != '--apply' ]; then echo 'Explicit promote --apply required' >&2; exit 2; fi
    promote_snapshot || exit 1
    ;;
  arm)
    if ! recovery_baseline_ready; then
      echo 'Cannot arm without a valid last-known-good snapshot. Boot normally or run snapshot.' >&2; exit 1
    fi
    if [ "$RECOVERY_DEVICE_QUALIFIED" != 1 ]; then
      echo 'Offline recovery not device-qualified. Refusing to arm.' >&2; exit 1
    fi
    set_auto 1
    ;;
  disarm) set_auto 0 ;;
  restore)
    if [ "${2:-}" != '--apply' ]; then echo 'Explicit --apply required to queue restoration' >&2; exit 2; fi
    [ "$RECOVERY_DEVICE_QUALIFIED" = 1 ] || { echo 'Device offline recovery unqualified; refusing restore queue' >&2; exit 1; }
    recovery_baseline_ready || { echo 'No integrity-verified snapshot to restore' >&2; exit 1; }
    write_atomic "$BOOT_DIR/manual-restore" 'queued' || exit 1
    log REQUEST 'Manual last-known-good restore queued for next hardware boot'
    echo 'Restore queued. Perform an ordinary hardware reboot when ready. No reboot triggered.'
    ;;
  cancel-restore) rm -f "$BOOT_DIR/manual-restore"; echo 'Queued restore cancelled' ;;
  reset-failures)
    write_atomic "$BOOT_DIR/failures" 0
    rm -f "$BOOT_DIR/recovery-performed"
    echo 'Failure count and recovery latch reset'
    ;;
  disable|enable)
    PKG="${2:-}"
    check_pkg "$PKG" || exit 2
    # Confirm successful change from a read-back; CLI request acceptance by itself
    # does not prove that this particular package changed state.
    if ! vector --json modules "$1" "$PKG" > "$LOG_DIR/last-toggle.json" 2>&1; then
      echo 'Vector declined module operation; see last-toggle.json' >&2; exit 1
    fi
    if ! vector --json modules ls -e > "$LOG_DIR/last-modules.json" 2>&1; then
      echo 'Vector state read-back unavailable' >&2; exit 1
    fi
    if sed -n 's/.*"PACKAGE"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_.]*\)".*/\1/p' "$LOG_DIR/last-modules.json" | grep -Fxq "$PKG"; then
      ENABLED=1
    else
      ENABLED=0
    fi
    if [ "$1" = enable ] && [ "$ENABLED" -ne 1 ]; then
      echo 'Enable did not persist in Vector configuration' >&2; exit 1
    fi
    if [ "$1" = disable ] && [ "$ENABLED" -ne 0 ]; then
      echo 'Disable did not persist in Vector configuration' >&2; exit 1
    fi
    log MODULE "User-requested $1 $PKG confirmed via Vector read-back"
    echo "$1 succeeded: $PKG (newly spawned processes only)"
    ;;
  scope)
    check_pkg "${2:-}" || exit 2
    vector scope ls "$2"
    ;;
  suspects)
    TARGET="${2:-}"
    check_target "$TARGET" || exit 2
    if [ "$TARGET" = system_server ]; then
      SCOPE_TARGET=system
    else
      SCOPE_TARGET="$TARGET"
    fi
    TMP_MODS="$STATE_DIR/suspects-$$.json"
    if ! vector --json modules ls -e > "$TMP_MODS"; then
      rm -f "$TMP_MODS"; echo 'Cannot read Vector module configuration' >&2; exit 1
    fi
    echo "Enabled modules scoped to $TARGET:"
    FOUND=0
    for MOD in $(sed -n 's/.*"PACKAGE"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_.]*\)".*/\1/p' "$TMP_MODS" | sort -u); do
      [ "$MOD" = 'lspd' ] && continue
      if vector --json scope ls "$MOD" 2>/dev/null | grep -F -q '"APP_PACKAGE": "'"$SCOPE_TARGET"'"'; then
        echo "  $MOD"
        FOUND=1
      fi
    done
    rm -f "$TMP_MODS"
    [ "$FOUND" -eq 1 ] || echo '  (none found; this is not proof no hooks are involved)'
    ;;
  crashes)
    if ! command -v logcat >/dev/null 2>&1; then echo 'logcat unavailable' >&2; exit 1; fi
    echo 'Crash-buffer process counts (not definitive proof of hook causality):'
    logcat -b crash -d -t 700 2>/dev/null |
      sed -n 's/.*Process: \([^ ,]*\), PID:.*/\1/p' | sort | uniq -c | sort -rn | head -n 25
    ;;
  *) echo "Unknown command: $1" >&2; help_text; exit 2 ;;
esac
