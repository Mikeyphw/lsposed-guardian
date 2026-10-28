#!/system/bin/sh
# Read-only machine/human summary of the *current* qualification boundaries.
# Evidence is deliberately described as recorded historical acceptance rather
# than permission to arm recovery. Ledger entries alone are root-writable.
qualification_quarantine_ledger() {
  [ -s "$STATE_DIR/quarantine/events.tsv" ] || return 1
  awk -F '\t' '
    NF==8 && $1=="QUARANTINED" && $2=="eu.hxreborn.remembermysort" && $6=="MANUAL_UNATTRIBUTED" {
      if ($7 ~ /^[[:xdigit:]]+$/ && $8 ~ /^[[:xdigit:]]+$/ && length($7)==64 && length($8)==64) {
        before=$7; after=$8; boot=$4; version=$5; found=1
      }
    }
    found && NF==8 && $1=="ROLLED_BACK" && $2=="eu.hxreborn.remembermysort" && $4==boot && $5==version &&
      $6=="MANUAL_UNATTRIBUTED" && $7==after && $8==before { verified=1 }
    END { exit !verified }
  ' "$STATE_DIR/quarantine/events.tsv"
}
qualification_boot_record() {
  [ -s "$STATE_DIR/boot-probe/early.txt" ] &&
  [ -s "$STATE_DIR/boot-probe/stable.txt" ] || return 1
  QE="$(sed -n 's/^observed_boot_id=//p' "$STATE_DIR/boot-probe/early.txt")"
  QS="$(sed -n 's/^observed_boot_id=//p' "$STATE_DIR/boot-probe/stable.txt")"
  [ -n "$QE" ] && [ "$QE" = "$QS" ] &&
  grep -Fxq 'assessment=EARLY_CANDIDATE' "$STATE_DIR/boot-probe/early.txt" &&
  grep -Fxq 'boot_completed=0' "$STATE_DIR/boot-probe/early.txt" &&
  grep -Fxq 'vectord_pid=none' "$STATE_DIR/boot-probe/early.txt" &&
  grep -Fxq 'vector=VECTOR_RESPONDING' "$STATE_DIR/boot-probe/stable.txt"
}
qualification_trial_record() {
  [ -s "$STATE_DIR/boot-trial/early.txt" ] &&
  [ -s "$STATE_DIR/boot-trial/stable.txt" ] || return 1
  QE="$(sed -n 's/^observed_boot_id=//p' "$STATE_DIR/boot-trial/early.txt")"
  QS="$(sed -n 's/^observed_boot_id=//p' "$STATE_DIR/boot-trial/stable.txt")"
  [ -n "$QE" ] && [ "$QE" = "$QS" ] &&
  grep -Fxq 'assessment=PASS_COPY_ONLY' "$STATE_DIR/boot-trial/early.txt" &&
  grep -Fxq 'vector=VECTOR_RESPONDING' "$STATE_DIR/boot-trial/stable.txt"
}
qualification_status() {
  Q_BASE="$(snapshot_integrity_level last-good)"
  Q_OBS="$(snapshot_integrity_level observed)"
  Q_QLAB="$(read_first "$STATE_DIR/quarantine-lab/last-result.txt")"
  Q_RLAB='NOT_RUN'
  [ -f "$STATE_DIR/recovery-lab/last-result.json" ] &&
    grep -Fq '"result":"PASS"' "$STATE_DIR/recovery-lab/last-result.json" && Q_RLAB=PASS
  case "$Q_QLAB" in PASS|FAIL) : ;; *) Q_QLAB=NOT_RUN ;; esac
  Q_PEND="$(find "$STATE_DIR/quarantine/pending" -maxdepth 1 -type f \( -name '*.record' -o -name '*.rollback' \) 2>/dev/null | wc -l | tr -d ' ')"
  is_number "$Q_PEND" || Q_PEND=0
  Q_B_READY=0
  if [ "$Q_BASE" = sqlite_integrity_verified ] &&
     [ -s "$SNAP_DIR/last-good.vector-version" ] &&
     [ -s "$SNAP_DIR/last-good.enabled" ] &&
     [ -s "$SNAP_DIR/last-good.complete" ] &&
     [ -s "$SNAP_DIR/last-good.boot-id" ] &&
     [ "$(read_first "$SNAP_DIR/last-good.complete")" = "$(read_first "$SNAP_DIR/last-good.boot-id")" ]; then
    Q_B_READY=1
  fi
  Q_LIVE_RESTORE=UNQUALIFIED
  [ "$RECOVERY_DEVICE_QUALIFIED" = 1 ] && Q_LIVE_RESTORE=CONFIG_FLAG_SET_NOT_DEVICE_PROOF
}
qualification_report() {
  qualification_status
  echo 'GUARDIAN RECOVERY QUALIFICATION (read-only)'
  echo "version=$(guardian_version)"
  echo "mode=$([ "$AUTO_RECOVERY" = 1 ] && echo ARMED || echo OBSERVE)"
  echo "baseline_integrity=$Q_BASE"
  echo "observed_integrity=$Q_OBS"
  echo "baseline_ready=$Q_B_READY"
  echo "baseline_provenance=$(baseline_provenance)"
  echo "sandbox_restore_lab=$Q_RLAB"
  echo "sandbox_quarantine_lab=$Q_QLAB"
  echo "pending_quarantine_transactions=$Q_PEND"
  echo "device_restore_qualification=$Q_LIVE_RESTORE"
  if os_receipt_verified && [ "$(cat "$OS_TX/phase")" = HEALTH_CONFIRMED ]; then
    echo 'actual_early_boot_restore_test=PASS_MANUAL_ONE_SHOT_RECEIPT'
    echo "actual_restore_boot_id=$OS_RBOOT"
  elif os_receipt_verified; then
    echo 'actual_early_boot_restore_test=HEALTH_PASS_PENDING_FINALIZATION'
  else
    echo 'actual_early_boot_restore_test=NOT_VERIFIED'
  fi
  if qualification_quarantine_ledger; then
    echo 'live_quarantine_roundtrip=PASS_HISTORICAL_LEDGER_PAIR'
  else
    echo 'live_quarantine_roundtrip=NOT_VERIFIED'
  fi
  if qualification_boot_record; then echo 'boot_order_observation=PASS_RECORDED'; else echo 'boot_order_observation=NOT_VERIFIED'; fi
  if qualification_trial_record; then echo 'copy_only_boot_trial=PASS_RECORDED'; else echo 'copy_only_boot_trial=NOT_VERIFIED'; fi
  echo 'automatic_quarantine=DISABLED'
  echo 'qualification=UNQUALIFIED'
  echo 'reason=Manual acceptance receipts do not certify unattended recovery, power-loss safety or exclusive Vector database access'
}
