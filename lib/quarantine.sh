#!/system/bin/sh
# Journaled quarantine shared by explicit manual operations and narrowly allowlisted auto response.
QROOT="$STATE_DIR/quarantine"
QACTIVE="$QROOT/active"
QPENDING="$QROOT/pending"
QLEDGER="$QROOT/events.tsv"
q_init() {
  mkdir -p "$QACTIVE" "$QPENDING" || return 1
  chmod 700 "$QROOT" "$QACTIVE" "$QPENDING" 2>/dev/null || :
}
q_lock() {
  mkdir "$QROOT/.lock" 2>/dev/null || {
    echo 'Guardian quarantine lock held; no mutation (inspect quarantine-status)' >&2; return 1;
  }
  trap 'rmdir "$QROOT/.lock" 2>/dev/null || :' 0 HUP INT TERM
}
q_unlock() {
  rmdir "$QROOT/.lock" 2>/dev/null || :
  trap - 0 HUP INT TERM
}
q_inventory() {
  QI_JSON="$QROOT/inventory-$$.json"
  vector --json modules ls > "$QI_JSON" 2>/dev/null &&
    grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$QI_JSON" || {
      rm -f "$QI_JSON"; echo 'Vector module inventory unavailable' >&2; return 1;
    }
  # package existence, including disabled state, is checked against all modules.
  grep -Fq '"PACKAGE": "'"$1"'"' "$QI_JSON" || {
    rm -f "$QI_JSON"; echo "Module not found in Vector inventory: $1" >&2; return 1;
  }
  rm -f "$QI_JSON"
  vector_enabled_manifest "$QROOT/now-$$.enabled" || {
    echo 'Cannot verify Vector enabled-state inventory' >&2; return 1;
  }
}
q_cleanup_inventory() { rm -f "$QROOT/now-$$.enabled" "$QROOT/expected-$$.enabled"; }
q_is_on() { grep -Fxq "$1" "$QROOT/now-$$.enabled"; }
q_expect_only_module_change() {
  grep -Fxv "$1" "$2" > "$QROOT/expected-$$.enabled" || :
  cmp -s "$QROOT/expected-$$.enabled" "$QROOT/now-$$.enabled"
}
q_event() {
  # Only bounded, validated values are written; the transaction does not imply causality.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "$(boot_id | tr -cd 'a-fA-F0-9-')" "$(vector_version_code)" "${Q_ATTRIBUTION:-MANUAL_UNATTRIBUTED}" "$3" "$4" >> "$QLEDGER"
}
q_status() {
  q_init || return 1
  echo 'Manual quarantine records (a disabled module is not proof of crash causality):'
  found=0
  for f in "$QACTIVE"/*.record; do
    [ -f "$f" ] || continue
    echo "  active: ${f##*/}" | sed 's/\.record$//'
    found=1
  done
  for f in "$QPENDING"/*.rollback; do
    [ -f "$f" ] || continue
    echo "  ROLLBACK_NEEDS_RECONCILIATION: ${f##*/}" | sed 's/\.rollback$//'
    found=1
  done
  for f in "$QPENDING"/*.record; do
    [ -f "$f" ] || continue
    echo "  NEEDS_RECONCILIATION: ${f##*/}" | sed 's/\.record$//'
    found=1
  done
  [ "$found" -eq 1 ] || echo '  (none)'
  if [ -f "$QROOT/.lock" ] || [ -d "$QROOT/.lock" ]; then
    echo '  lock: present (check running Guardian process; never force-delete blindly)'
  fi
  echo "ledger_events=$([ -f "$QLEDGER" ] && wc -l < "$QLEDGER" | tr -d ' ' || echo 0)"
}
q_preview() {
  q_init || return 1
  if [ -e "$QPENDING/$1.rollback" ] || [ -e "$QPENDING/$1.record" ]; then
    echo "Pending transaction for $1; use quarantine-reconcile"; return 1
  fi
  if [ -e "$QACTIVE/$1.record" ]; then
    echo "Already quarantined by Guardian: $1"; return 1
  fi
  q_inventory "$1" || { q_cleanup_inventory; return 1; }
  if q_is_on "$1"; then
    echo "Preview: $1 is ENABLED; manual quarantine would disable this module in Vector."
    echo 'Scopes and module APK are not modified. Existing hooked processes may require restart.'
    echo 'No crash causality has been established. Use quarantine PACKAGE --apply to proceed.'
  else
    echo "Preview: $1 is already disabled; quarantine unnecessary."
  fi
  q_cleanup_inventory
}
q_apply() {
  Q_ATTRIBUTION=MANUAL_UNATTRIBUTED
  [ "${2:-}" != auto ] || Q_ATTRIBUTION=AUTO_CORRELATED_NOT_CAUSAL
  q_init && q_lock || return 1
  PK="$1"
  if [ -e "$QPENDING/$PK.record" ] || [ -e "$QPENDING/$PK.rollback" ] || [ -e "$QACTIVE/$PK.record" ]; then
    echo 'Existing quarantine transaction; refusing duplicate' >&2; q_unlock; return 1
  fi
  q_inventory "$PK" || { q_cleanup_inventory; q_unlock; return 1; }
  if ! q_is_on "$PK"; then
    echo 'Target module is already disabled; no mutation' >&2; q_cleanup_inventory; q_unlock; return 1
  fi
  BEFORE="$QPENDING/$PK.before"
  cp "$QROOT/now-$$.enabled" "$BEFORE" || { q_cleanup_inventory; q_unlock; return 1; }
  HASH="$(db_sha "$BEFORE")"
  RECORD="$(date +%s)|$(boot_id | tr -cd 'a-fA-F0-9-')|$(vector_version_code)|$HASH|$Q_ATTRIBUTION"
  if ! write_atomic "$QPENDING/$PK.record" "$RECORD"; then
    rm -f "$BEFORE"; q_cleanup_inventory; q_unlock; return 1
  fi
  # After pending is durable, failures stay pending and require explicit reconciliation.
  if ! vector --json modules disable "$PK" > "$LOG_DIR/last-quarantine-toggle.json" 2>&1 ||
     ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$LOG_DIR/last-quarantine-toggle.json" ||
     ! q_inventory "$PK" || q_is_on "$PK" ||
     ! q_expect_only_module_change "$PK" "$BEFORE"; then
    echo "Quarantine not confirmed. Pending transaction retained: $PK" >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  cp "$QPENDING/$PK.record" "$QACTIVE/$PK.record" || { q_cleanup_inventory; q_unlock; return 1; }
  cp "$BEFORE" "$QACTIVE/$PK.before" || { q_cleanup_inventory; q_unlock; return 1; }
  if ! q_event QUARANTINED "$PK" "$HASH" "$(db_sha "$QROOT/now-$$.enabled")"; then
    echo 'Ledger write failed; quarantine evidence and pending journal retained' >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  rm -f "$QPENDING/$PK.record" "$QPENDING/$PK.before"
  q_cleanup_inventory; q_unlock
  log QUARANTINE "Disabled $PK ($Q_ATTRIBUTION); reversible record saved; no hook causality assigned"
  echo "QUARANTINED $PK: confirmed disabled; reversible record retained. Running hooks may persist."
}
q_rollback() {
  q_init && q_lock || return 1
  PK="$1"
  if [ -e "$QPENDING/$PK.record" ] || [ -e "$QPENDING/$PK.rollback" ]; then
    echo 'Interrupted transaction; reconcile first' >&2; q_unlock; return 1
  fi
  if [ ! -s "$QACTIVE/$PK.record" ]; then
    echo 'Guardian has no active quarantine for this module' >&2; q_unlock; return 1
  fi
  q_inventory "$PK" || { q_cleanup_inventory; q_unlock; return 1; }
  if q_is_on "$PK"; then
    echo 'Module already enabled outside Guardian; refusing to change its state' >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  # A rollback can be interrupted *after* Vector enabled the module but before
  # Guardian has written the terminal ledger. Journal BEFORE the Vector write.
  Q_ROLLBACK_BEFORE="$QPENDING/$PK.rollback-before"
  cp "$QROOT/now-$$.enabled" "$Q_ROLLBACK_BEFORE" || { q_cleanup_inventory; q_unlock; return 1; }
  Q_RB_HASH="$(db_sha "$Q_ROLLBACK_BEFORE")"
  if ! write_atomic "$QPENDING/$PK.rollback" "$Q_RB_HASH"; then
    rm -f "$Q_ROLLBACK_BEFORE"; q_cleanup_inventory; q_unlock; return 1
  fi
  if ! vector --json modules enable "$PK" > "$LOG_DIR/last-quarantine-toggle.json" 2>&1 ||
     ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$LOG_DIR/last-quarantine-toggle.json" ||
     ! q_inventory "$PK" || ! q_is_on "$PK"; then
    echo 'Rollback could not be confirmed; active record retained' >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  grep -Fxv "$PK" "$QROOT/now-$$.enabled" > "$QROOT/expected-$$.enabled" || :
  if ! cmp -s "$QROOT/expected-$$.enabled" "$Q_ROLLBACK_BEFORE"; then
    echo 'Other modules changed during rollback; record retained for review' >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  if ! q_event ROLLED_BACK "$PK" "$Q_RB_HASH" "$(db_sha "$QROOT/now-$$.enabled")"; then
    echo 'Ledger write failed; rollback journal retained for reconciliation' >&2
    q_cleanup_inventory; q_unlock; return 1
  fi
  rm -f "$QACTIVE/$PK.record" "$QACTIVE/$PK.before" "$QPENDING/$PK.rollback" "$Q_ROLLBACK_BEFORE"
  q_cleanup_inventory; q_unlock
  log QUARANTINE "Manual rollback enabled $PK; unrelated Vector module settings preserved"
  echo "ROLLED_BACK $PK: verified enabled. Existing processes may require restart."
}
q_reconcile() {
  q_init && q_lock || return 1
  PK="$1"
  if [ ! -s "$QPENDING/$PK.record" ] || [ ! -s "$QPENDING/$PK.before" ]; then
    echo 'No complete pending transaction to reconcile' >&2; q_unlock; return 1
  fi
  # Read the on-disk single-line journal without passing through a shell
  # function's shared OUT variable. Some Android shells differ in `read` state.
  REC="$(LC_ALL=C sed -n '1p' "$QPENDING/$PK.record")"
  case "$REC" in
    *'|MANUAL_UNATTRIBUTED'|*'|AUTO_CORRELATED_NOT_CAUSAL') : ;;
    *)
      echo 'Unexpected transaction record: missing manual-attribution marker' >&2
      q_unlock; return 1 ;;
  esac
  # Require exactly five fields, with a SHA-256 of the previously enabled set.
  [ "$(printf '%s\n' "$REC" | awk -F '|' '{print NF}')" = 5 ] || {
    echo 'Unexpected transaction record: invalid field count' >&2
    q_unlock; return 1;
  }
  pre_hash="$(printf '%s' "$REC" | cut -d '|' -f 4)"
  case "$pre_hash" in ''|*[!a-fA-F0-9]*) echo 'Unexpected transaction record: malformed digest' >&2; q_unlock; return 1 ;; esac
  [ "${#pre_hash}" -eq 64 ] || {
    echo 'Unexpected transaction record: invalid digest size' >&2; q_unlock; return 1;
  }
  [ "$(db_sha "$QPENDING/$PK.before")" = "$pre_hash" ] || {
    echo 'Pending transaction digest invalid' >&2; q_unlock; return 1;
  }
  q_inventory "$PK" || { q_cleanup_inventory; q_unlock; return 1; }
  if q_is_on "$PK"; then
    if ! cmp -s "$QPENDING/$PK.before" "$QROOT/now-$$.enabled"; then
      echo 'Module enabled but unrelated module inventory changed; manual review required' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    if ! q_event CANCELLED "$PK" "$pre_hash" "$pre_hash"; then
      echo 'Ledger failure; pending journal kept' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    rm -f "$QPENDING/$PK.record" "$QPENDING/$PK.before"
    echo "CANCELLED $PK: enabled state unchanged, interrupted transaction cleared."
  else
    if ! q_expect_only_module_change "$PK" "$QPENDING/$PK.before"; then
      echo 'Unexpected module inventory delta; refusing reconciliation' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    cp "$QPENDING/$PK.record" "$QACTIVE/$PK.record" &&
      cp "$QPENDING/$PK.before" "$QACTIVE/$PK.before" || { q_cleanup_inventory; q_unlock; return 1; }
    if ! q_event RECONCILED "$PK" "$pre_hash" "$(db_sha "$QROOT/now-$$.enabled")"; then
      echo 'Ledger failure; pending reconciliation remains' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    rm -f "$QPENDING/$PK.record" "$QPENDING/$PK.before"
    echo "RECONCILED $PK: module disabled and rollback record recovered."
  fi
  q_cleanup_inventory; q_unlock
}

# Reconcile a journaled *rollback* without blindly issuing a second enable.
q_reconcile_rollback() {
  q_init && q_lock || return 1
  PK="$1"
  if [ ! -s "$QPENDING/$PK.rollback" ] || [ ! -f "$QPENDING/$PK.rollback-before" ] ||
     [ ! -s "$QACTIVE/$PK.record" ]; then
    echo 'No complete pending rollback transaction' >&2; q_unlock; return 1
  fi
  Q_RB_HASH="$(read_first "$QPENDING/$PK.rollback")"
  [ "$(db_sha "$QPENDING/$PK.rollback-before")" = "$Q_RB_HASH" ] || {
    echo 'Rollback journal checksum invalid' >&2; q_unlock; return 1;
  }
  q_inventory "$PK" || { q_cleanup_inventory; q_unlock; return 1; }
  if q_is_on "$PK"; then
    grep -Fxv "$PK" "$QROOT/now-$$.enabled" > "$QROOT/expected-$$.enabled" || :
    if ! cmp -s "$QROOT/expected-$$.enabled" "$QPENDING/$PK.rollback-before"; then
      echo 'Unrelated enabled modules changed; manual review required' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    if ! q_event ROLLBACK_RECONCILED "$PK" "$Q_RB_HASH" "$(db_sha "$QROOT/now-$$.enabled")"; then
      echo 'Ledger failure; pending rollback kept' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    rm -f "$QACTIVE/$PK.record" "$QACTIVE/$PK.before" "$QPENDING/$PK.rollback" "$QPENDING/$PK.rollback-before"
    echo "ROLLBACK_RECONCILED $PK: previous enable confirmed."
  else
    if ! cmp -s "$QROOT/now-$$.enabled" "$QPENDING/$PK.rollback-before"; then
      echo 'Rollback incomplete with unrelated state changes; manual review required' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    if ! q_event ROLLBACK_CANCELLED "$PK" "$Q_RB_HASH" "$Q_RB_HASH"; then
      echo 'Ledger failure; pending rollback kept' >&2
      q_cleanup_inventory; q_unlock; return 1
    fi
    rm -f "$QPENDING/$PK.rollback" "$QPENDING/$PK.rollback-before"
    echo "ROLLBACK_CANCELLED $PK: module remains quarantined; explicit rollback may be retried."
  fi
  q_cleanup_inventory; q_unlock
}
