#!/system/bin/sh
# Conservative review planning. No module toggles, scope changes or reboots.
recovery_plan() {
  RP_TARGET="$1"
  RP_OUTPUT="$(history_decision "$RP_TARGET")" || return 1
  RP_DECISION="$(printf '%s\n' "$RP_OUTPUT" | sed -n 's/^decision=//p' | head -n 1)"
  RP_CANDIDATE="$(printf '%s\n' "$RP_OUTPUT" | sed -n 's/^candidate_for_manual_review=//p' | head -n 1)"
  printf 'target=%s\n' "$RP_TARGET"
  printf 'decision=%s\n' "$RP_DECISION"
  printf '%s\n' "$RP_OUTPUT" | grep -E '^(recent_crash_count|distinct_process_count|last_matched_scope_count|causality)=' || :
  printf 'mode=REVIEW_ONLY\n'
  printf 'automatic_action=disabled\n'
  if [ "$RP_DECISION" = REVIEW_SINGLE_SCOPED_MODULE ] && [ -n "$RP_CANDIDATE" ]; then
    case "$RP_CANDIDATE" in *[!a-zA-Z0-9_.]*|''|*..*)
      echo 'candidate=INVALID; fail closed' >&2; return 1 ;; esac
    printf 'candidate=%s\n' "$RP_CANDIDATE"
    printf 'next_step=MANUAL_INVESTIGATION_REQUIRED\n'
    printf 'preview=guardian.sh quarantine %s\n' "$RP_CANDIDATE"
    printf 'warning=Historical scope is not evidence of hook causality\n'
  else
    printf 'next_step=NO_MODULE_ACTION\n'
  fi
  if [ "$RECOVERY_DEVICE_QUALIFIED" != 1 ] || ! recovery_baseline_ready; then
    echo 'offline_recovery=BLOCKED_UNQUALIFIED'
  else
    echo 'offline_recovery=QUALIFICATION_CONFIGURED_NOT_TRIGGERED'
  fi
}
