#!/system/bin/sh
# Runs actual quarantine transaction functions against a local synthetic Vector.
# No production Vector CLI, modules, DB, snapshots or scopes are ever accessed.
QLAB_DIR="$STATE_DIR/quarantine-lab"

quarantine_lab_run() (
  mkdir -p "$QLAB_DIR" || return 1
  chmod 700 "$QLAB_DIR" 2>/dev/null || :
  mkdir "$QLAB_DIR/.lock" 2>/dev/null || {
    echo 'QUARANTINE_LAB_BUSY: another lab run may be active' >&2
    return 1
  }
  mkdir "$QLAB_DIR/run-$$" || return 1
  # All state paths are redirected BEFORE loading the transaction implementation.
  STATE_DIR="$QLAB_DIR/run-$$"
  LOG_DIR="$STATE_DIR/logs"
  mkdir -p "$LOG_DIR" || return 1
  . "$MODDIR/lib/quarantine.sh" || return 1
  LAB_MODS="$STATE_DIR/fake-enabled.txt"
  LAB_ALL="$STATE_DIR/fake-installed.txt"
  printf 'lab.alpha\n' > "$LAB_MODS" || return 1
  printf 'lab.alpha\nlab.beta\n' > "$LAB_ALL" || return 1
  LAB_MODE=normal
  LAB_EVENT_FAIL=0

  # The synthetic adapter has no path to the installed Vector daemon.
  vector() {
    [ "$1" = --json ] || return 9
    shift
    case "$1:$2" in
      modules:ls)
        printf '{"success": true, "data": [\n'
        first=1
        while IFS= read -r pkg; do
          [ -n "$pkg" ] || continue
          if grep -Fxq "$pkg" "$LAB_MODS"; then state=enabled; else state=disabled; fi
          if [ "${3:-}" = -e ] && [ "$state" != enabled ]; then continue; fi
          [ "$first" = 1 ] || printf ',\n'
          printf '{"PACKAGE": "%s", "STATUS": "%s"}' "$pkg" "$state"
          first=0
        done < "$LAB_ALL"
        printf '\n]}\n'
        return 0 ;;
      modules:disable|modules:enable)
        pkg="$3"
        grep -Fxq "$pkg" "$LAB_ALL" || return 4
        [ "$LAB_MODE" != reject ] || return 5
        if [ "$LAB_MODE" != pretend ]; then
          if [ "$2" = disable ]; then
            grep -Fxv "$pkg" "$LAB_MODS" > "$LAB_MODS.next" || :
            mv -f "$LAB_MODS.next" "$LAB_MODS" || return 1
          elif ! grep -Fxq "$pkg" "$LAB_MODS"; then
            printf '%s\n' "$pkg" >> "$LAB_MODS" || return 1
            LC_ALL=C sort -u "$LAB_MODS" -o "$LAB_MODS" || return 1
          fi
        fi
        if [ "$LAB_MODE" = mutate-other ]; then
          printf 'lab.beta\n' >> "$LAB_MODS"
          LC_ALL=C sort -u "$LAB_MODS" -o "$LAB_MODS" || return 1
        fi
        [ "$LAB_MODE" != lost-reply ] || return 6
        echo '{"success": true}'
        return 0 ;;
    esac
    return 9
  }
  vector_enabled_manifest() {
    cp "$LAB_MODS" "$1" || return 1
  }
  vector_version_code() { echo 999; }
  boot_id() { echo '00000000-0000-4000-8000-000000000001'; }
  # Inject an evidence-ledger failure without changing transaction code.
  q_event() {
    [ "$LAB_EVENT_FAIL" = 0 ] || return 1
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$QLEDGER"
  }
  log() { :; }

  q_init || return 1
  LAB_BASELINE_SHA="$(db_sha "$LAB_MODS")"
  q_preview lab.alpha > "$STATE_DIR/preview.txt" || return 1
  [ "$(db_sha "$LAB_MODS")" = "$LAB_BASELINE_SHA" ] || return 1
  [ ! -s "$QLEDGER" ] || return 1
  echo 'PASS_Q_LAB_PREVIEW_NO_MUTATION'

  q_apply lab.alpha > "$STATE_DIR/operation.txt" || return 1
  ! grep -Fxq lab.alpha "$LAB_MODS" || return 1
  [ -s "$QACTIVE/lab.alpha.record" ] || return 1
  q_rollback lab.alpha >> "$STATE_DIR/operation.txt" || return 1
  [ "$(db_sha "$LAB_MODS")" = "$LAB_BASELINE_SHA" ] || return 1
  [ ! -e "$QACTIVE/lab.alpha.record" ] || return 1
  echo 'PASS_Q_LAB_TRANSACTIONAL_DISABLE_ROLLBACK'

  LAB_MODE=pretend
  if q_apply lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then return 1; fi
  [ -s "$QPENDING/lab.alpha.record" ] || return 1
  # Diagnose the sandbox journal *before* reconciliation. Only fake data lives
  # here; all results stay under Guardian's own quarantine-lab directory.
  QLAB_RECORD="$(LC_ALL=C sed -n '1p' "$QPENDING/lab.alpha.record")"
  if ! q_reconcile lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then
    printf 'stage=noop-reconcile\nrecord_field_count=%s\nrecord_bytes=%s\nrecord_suffix=%s\nrecord_head=%s\n' \
      "$(printf '%s\n' "$QLAB_RECORD" | awk -F '|' '{print NF}')" \
      "$(wc -c < "$QPENDING/lab.alpha.record" | tr -d ' ')" \
      "${QLAB_RECORD##*|}" \
      "$(printf '%s' "$QLAB_RECORD" | cut -d '|' -f 1-3)" \
      > "$QLAB_DIR/last-failure.txt"
    echo 'FAIL_Q_LAB_NOOP_RECONCILIATION; safe diagnostic saved' >&2
    cat "$QLAB_DIR/last-failure.txt" >&2
    return 1
  fi
  [ "$(db_sha "$LAB_MODS")" = "$LAB_BASELINE_SHA" ] || return 1
  [ ! -e "$QPENDING/lab.alpha.record" ] || return 1
  echo 'PASS_Q_LAB_NOOP_RESPONSE_CANCELLED'

  LAB_MODE=lost-reply
  if q_apply lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then return 1; fi
  [ -s "$QPENDING/lab.alpha.record" ] || return 1
  LAB_MODE=normal
  q_reconcile lab.alpha >> "$STATE_DIR/operation.txt" || return 1
  [ -s "$QACTIVE/lab.alpha.record" ] || return 1
  q_rollback lab.alpha >> "$STATE_DIR/operation.txt" || return 1
  [ "$(db_sha "$LAB_MODS")" = "$LAB_BASELINE_SHA" ] || return 1
  echo 'PASS_Q_LAB_LOST_REPLY_RECONCILED'

  LAB_EVENT_FAIL=1
  if q_apply lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then return 1; fi
  [ -s "$QPENDING/lab.alpha.record" ] || return 1
  LAB_EVENT_FAIL=0
  q_reconcile lab.alpha >> "$STATE_DIR/operation.txt" || return 1
  q_rollback lab.alpha >> "$STATE_DIR/operation.txt" || return 1
  [ "$(db_sha "$LAB_MODS")" = "$LAB_BASELINE_SHA" ] || return 1
  echo 'PASS_Q_LAB_LEDGER_FAILURE_RECOVERED'

  LAB_MODE=mutate-other
  if q_apply lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then return 1; fi
  [ -s "$QPENDING/lab.alpha.record" ] || return 1
  LAB_MODE=normal
  if q_reconcile lab.alpha >> "$STATE_DIR/operation.txt" 2>&1; then return 1; fi
  [ -s "$QPENDING/lab.alpha.record" ] || return 1
  echo 'PASS_Q_LAB_UNRELATED_DELTA_BLOCKED'

  # No synthetic state is ever promoted to Guardian's real quarantine directory.
  write_atomic "$QLAB_DIR/last-result.txt" PASS || return 1
  echo 'PASS_GUARDIAN_ISOLATED_QUARANTINE_LAB'
  echo 'real_vector_modules_modified=false'
  echo 'automatic_quarantine_enabled=false'
)

quarantine_lab() {
  # A previous successful run must not conceal a failed repeat.
  rm -f "$QLAB_DIR/last-result.txt" "$QLAB_DIR/last-failure.txt"
  quarantine_lab_run
  QL_RC=$?
  # Clean only the precisely owned sandbox, never production Guardian state.
  rm -rf "$QLAB_DIR/run-$$"
  rmdir "$QLAB_DIR/.lock" 2>/dev/null || :
  if [ "$QL_RC" -ne 0 ]; then
    mkdir -p "$QLAB_DIR" 2>/dev/null || :
    write_atomic "$QLAB_DIR/last-result.txt" FAIL 2>/dev/null || :
    echo 'sandbox_quarantine_lab=FAIL (live modules unchanged)' >&2
  fi
  return "$QL_RC"
}
