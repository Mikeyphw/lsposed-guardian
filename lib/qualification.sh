#!/system/bin/sh
# Read-only machine/human summary of the *current* qualification boundaries.
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
  echo 'actual_early_boot_restore_test=NOT_VERIFIED'
  echo 'live_quarantine_roundtrip=NOT_VERIFIED'
  echo 'automatic_quarantine=DISABLED'
  echo 'qualification=UNQUALIFIED'
  echo 'reason=Isolated labs do not certify live Vector recovery or device safety'
}
