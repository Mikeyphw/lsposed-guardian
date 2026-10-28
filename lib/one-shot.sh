#!/system/bin/sh
# v0.9.3 manually staged, once-only early-boot Vector DB restore acceptance.
# This is deliberately independent from unattended recovery, which remains gated off.
OS_ROOT="$STATE_DIR/one-shot"
OS_REQ="$OS_ROOT/request"
OS_TX="$OS_ROOT/transaction"
OS_REPORT="$OS_ROOT/early.txt"
OS_HEALTH="$OS_ROOT/stable.txt"
os_id() { printf '%s' "$1" | tr -cd 'a-fA-F0-9-'; }
os_setup() { mkdir -p "$OS_ROOT" && chmod 700 "$OS_ROOT"; }
os_sha() {
  OS_DIGEST="$(sha256sum "$1" 2>/dev/null | awk 'NR==1 {print $1}')"
  case "$OS_DIGEST" in ''|*[!0-9a-fA-F]*) return 1;; esac
  [ "${#OS_DIGEST}" -eq 64 ] || return 1
  printf '%s' "$OS_DIGEST"
}
os_context() {
  # The Android ls -Z output is not column-stable; identify the context token.
  ls -Z "$1" 2>/dev/null | tr '[:space:]' '\n' |
    grep -E '^u:object_r:[a-zA-Z0-9_]+:s[0-9]+$' | head -n 1
}
os_file_metadata() {
  [ ! -L "$DB" ] && [ -f "$DB" ] && [ ! -L "${DB%/*}" ] || return 1
  OS_LABEL="$(os_context "$DB")"
  [ "$OS_LABEL" = 'u:object_r:system_file:s0' ] || return 1
  OS_OWNER="$(stat -c '%u:%g' "$DB" 2>/dev/null)"
  OS_MODE="$(stat -c '%a' "$DB" 2>/dev/null)"
  [ "$OS_OWNER" = '0:0' ] && [ "$OS_MODE" = 660 ] || return 1
  [ "$(os_context "${DB%/*}")" = "$OS_LABEL" ] || return 1
}
os_safe_environment() {
  [ "$AUTO_RECOVERY" = 0 ] && [ "$RECOVERY_DEVICE_QUALIFIED" = 0 ] || return 1
  [ ! -e "$BOOT_DIR/manual-restore" ] && [ ! -e "$BOOT_DIR/recovery-performed" ] || return 1
  [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ] || return 1
  [ -z "$(pidof vectord 2>/dev/null)" ] || return 1
  [ "$(vector_version_code)" = 3112 ] || return 1
  for OS_PATH in "$DB" "$DB-wal" "$DB-shm" "$DB-journal"; do
    [ ! -L "$OS_PATH" ] || return 1
  done
  os_file_metadata || return 1
}
os_verified_rescue() {
  OS_RESCUE="${GUARDIAN_RESCUE_SCRIPT:-/data/local/tmp/guardian-recover.sh}"
  [ -f "$OS_RESCUE" ] || return 1
  OS_RESCUE_OUT="$(sh "$OS_RESCUE" status 2>/dev/null)" || return 1
  printf '%s\n' "$OS_RESCUE_OUT" | grep -Fxq 'backup_integrity=PASS' || return 1
  # A separate explicit path is supported for isolated host fixtures only.
  # Production uses the unchanged verified-backup location from rescue v4.
  OS_RESCUE_DB="${GUARDIAN_RESCUE_DB:-/data/local/tmp/guardian-rescue/verified-backup/vector.db}"
  [ -s "$OS_RESCUE_DB" ] || return 1
  # Source file must be the exact file checked by rescue status.
  [ ! -L "$OS_RESCUE_DB" ] && db_integrity "$OS_RESCUE_DB" || return 1
}
os_manifest_db() {
  OS_SQLITE="$(sqlite_tool)" || return 1
  "$OS_SQLITE" -readonly "$1" 'SELECT module_pkg_name FROM modules WHERE enabled=1 ORDER BY module_pkg_name;' 2>/dev/null |
    grep -v '^lspd$' | LC_ALL=C sort -u
}
os_stage_checks() {
  os_setup || return 1
  [ ! -e "$OS_REQ" ] && [ ! -e "$OS_TX" ] || {
    echo 'One-shot transaction already staged or retained; refusing' >&2; return 1;
  }
  [ "$AUTO_RECOVERY" = 0 ] && [ "$RECOVERY_DEVICE_QUALIFIED" = 0 ] || return 1
  [ ! -e "$BOOT_DIR/manual-restore" ] || return 1
  boot_complete || return 1
  OS_ORIGIN="$(os_id "$(boot_id)")"
  [ -n "$OS_ORIGIN" ] && [ "$(os_id "$(read_first "$BOOT_DIR/last-success-id")")" = "$OS_ORIGIN" ] || return 1
  # Real boot-rehearsal and subsequent Vector response must match this boot.
  grep -Fxq "observed_boot_id=$OS_ORIGIN" "$STATE_DIR/boot-trial/early.txt" 2>/dev/null &&
  grep -Fxq 'assessment=PASS_COPY_ONLY' "$STATE_DIR/boot-trial/early.txt" 2>/dev/null &&
  grep -Fxq "observed_boot_id=$OS_ORIGIN" "$STATE_DIR/boot-trial/stable.txt" 2>/dev/null &&
  grep -Fxq 'vector=VECTOR_RESPONDING' "$STATE_DIR/boot-trial/stable.txt" 2>/dev/null || {
    echo 'This boot lacks a successful real copy-only rehearsal' >&2; return 1;
  }
  [ "$(vector_version_code)" = 3112 ] && vector status >/dev/null 2>&1 || return 1
  os_verified_rescue || { echo 'The verified custom recovery DB is missing or invalid' >&2; return 1; }
  # Reject snapshot drift even if the rescue file passes integrity.
  OS_DB_MAN="$OS_ROOT/current-$$.enabled"
  OS_RESCUE_MAN="$OS_ROOT/rescue-$$.enabled"
  if ! vector_enabled_manifest "$OS_DB_MAN" ||
     ! os_manifest_db "$OS_RESCUE_DB" > "$OS_RESCUE_MAN" ||
     ! cmp -s "$OS_DB_MAN" "$OS_RESCUE_MAN"; then
    rm -f "$OS_DB_MAN" "$OS_RESCUE_MAN"
    echo 'Rescue snapshot modules differ from currently enabled Vector modules' >&2; return 1
  fi
  rm -f "$OS_DB_MAN" "$OS_RESCUE_MAN"
  os_file_metadata || { echo 'Live Vector DB ownership/mode/SELinux label not qualified' >&2; return 1; }
  [ "$(stat -c '%u:%g' "${DB%/*}" 2>/dev/null)" = 0:0 ] || return 1
  [ ! -e "$DB.guardian-oneshot-stage" ] && [ ! -L "$DB.guardian-oneshot-stage" ] || return 1
  echo 'PASS_GUARDIAN_ONE_SHOT_PREFLIGHT'
  echo "boot_id=$OS_ORIGIN"
  echo 'vector_version=3112'
  echo 'live_db_label=u:object_r:system_file:s0'
  echo 'enabled_inventory=MATCHED'
  echo 'real_restore=NOT_YET_ATTEMPTED'
}
os_stage() {
  os_stage_checks || return 1
  # Source pinning into private state is allowed while Android is booted.
  OS_NEW="$OS_ROOT/payload.tmp.$$"
  cp "$OS_RESCUE_DB" "$OS_NEW" || return 1
  chmod 600 "$OS_NEW" || return 1
  db_integrity "$OS_NEW" || { rm -f "$OS_NEW"; return 1; }
  OS_DIGEST="$(os_sha "$OS_NEW")" || { rm -f "$OS_NEW"; return 1; }
  os_manifest_db "$OS_NEW" > "$OS_ROOT/expected.enabled" || return 1
  [ -s "$OS_ROOT/expected.enabled" ] || return 1
  mv "$OS_NEW" "$OS_ROOT/payload.db" || return 1
  printf '%s\n' "$OS_ORIGIN|3112|$OS_DIGEST" > "$OS_ROOT/request.tmp.$$" || return 1
  mv "$OS_ROOT/request.tmp.$$" "$OS_REQ" || return 1
  sync
  echo 'PASS_GUARDIAN_ONE_SHOT_STAGED'
  echo "payload_sha256=$OS_DIGEST"
  echo 'one_time_request=CONSUMED_BEFORE_MUTATION'
  echo 'automatic_recovery=DISABLED'
  echo 'reboot_manually=yes'
}
os_cancel() {
  os_setup || return 1
  [ ! -e "$OS_TX" ] || { echo 'Already attempted: transaction retained for inspection' >&2; return 1; }
  rm -f "$OS_REQ" || return 1
  echo 'PASS_GUARDIAN_ONE_SHOT_CANCELLED'
}
os_receipt() {
  cat > "$OS_REPORT.tmp.$$" <<EOF
schema=guardian-one-shot-v1
boot_id=$(os_id "$(boot_id)")
phase=post-fs-data
assessment=$1
reason=$2
before_sha256=${OS_BEFORE:-unknown}
restored_sha256=${OS_AFTER:-unknown}
source_sha256=${OS_WANTED:-unknown}
selinux_context=${OS_LABEL:-unknown}
vector_version=$(vector_version_code)
automatic_recovery=DISABLED
observed_epoch=$(date +%s)
EOF
  mv "$OS_REPORT.tmp.$$" "$OS_REPORT"
}
os_write_phase() { printf '%s\n' "$1" > "$OS_TX/phase.tmp.$$" && mv "$OS_TX/phase.tmp.$$" "$OS_TX/phase" && sync; }
os_backup_family() {
  mkdir -p "$OS_TX" || return 1
  [ ! -e "$OS_TX/original.db" ] || return 1
  for OS_EXT in '' -wal -shm -journal; do
    if [ -f "$DB$OS_EXT" ]; then
      cp "$DB$OS_EXT" "$OS_TX/original.db$OS_EXT" || return 1
      cmp -s "$DB$OS_EXT" "$OS_TX/original.db$OS_EXT" || return 1
      os_sha "$OS_TX/original.db$OS_EXT" > "$OS_TX/original.sha$OS_EXT" || return 1
    else
      [ -n "$OS_EXT" ] || return 1
      : > "$OS_TX/absent$OS_EXT"
    fi
  done
  # Recheck the entire family after copying, not only each file individually.
  # A concurrent writer during the backup must fail BEFORE live mutation.
  for OS_EXT in '' -wal -shm -journal; do
    if [ -f "$OS_TX/original.db$OS_EXT" ]; then
      cmp -s "$DB$OS_EXT" "$OS_TX/original.db$OS_EXT" || return 1
    else
      [ ! -e "$DB$OS_EXT" ] || return 1
    fi
  done
  sync
  os_write_phase ORIGINAL_VERIFIED
}
os_offline_undo() {
  # This function only runs at the early boot hook before the Vector daemon.
  [ -s "$OS_TX/original.db" ] || return 1
  [ -z "$(pidof vectord 2>/dev/null)" ] || return 1
  for OS_EXT in '' -wal -shm -journal; do
    if [ -f "$OS_TX/original.db$OS_EXT" ]; then
      [ "$(os_sha "$OS_TX/original.db$OS_EXT")" = "$(cat "$OS_TX/original.sha$OS_EXT")" ] || return 1
    elif [ -e "$OS_TX/absent$OS_EXT" ]; then :
    else return 1; fi
  done
  # Keep all original transaction evidence even when undo succeeds.
  os_write_phase RESTORING_ORIGINAL || return 1
  for OS_EXT in -wal -shm -journal; do
    [ ! -e "$DB$OS_EXT" ] || mv "$DB$OS_EXT" "$OS_TX/aborted-live$OS_EXT" || return 1
  done
  cp "$OS_TX/original.db" "$DB.guardian-undo-stage" || return 1
  chmod 660 "$DB.guardian-undo-stage" && chown 0:0 "$DB.guardian-undo-stage" || return 1
  chcon "$OS_LABEL" "$DB.guardian-undo-stage" || return 1
  mv -f "$DB.guardian-undo-stage" "$DB" || return 1
  for OS_EXT in -wal -shm -journal; do
    [ ! -e "$OS_TX/original.db$OS_EXT" ] || cp "$OS_TX/original.db$OS_EXT" "$DB$OS_EXT" || return 1
    [ ! -e "$DB$OS_EXT" ] || { chmod 660 "$DB$OS_EXT" && chown 0:0 "$DB$OS_EXT" && chcon "$OS_LABEL" "$DB$OS_EXT"; } || return 1
  done
  [ "$(os_sha "$DB")" = "$(cat "$OS_TX/original.sha")" ] || return 1
  sync
  os_write_phase ABORTED_ORIGINAL_RESTORED || return 1
}
os_early() {
  os_setup || return 0
  OS_NOW="$(os_id "$(boot_id)")"
  # A previous interrupted mutation is never retried. Only a journaled undo is attempted.
  if [ -s "$OS_TX/phase" ]; then
    OS_OLD_PHASE="$(cat "$OS_TX/phase")"
    if [ "$OS_OLD_PHASE" = SWAP_STARTED ] || [ "$OS_OLD_PHASE" = RESTORING_ORIGINAL ]; then
      OS_LABEL='u:object_r:system_file:s0'
      if os_safe_environment && os_offline_undo; then
        os_receipt ABORTED 'interrupted_restore_reconciled_before_vector'
      else
        os_receipt NEEDS_CUSTOM_RECOVERY 'interrupted_restore_unresolved'
      fi
    fi
    return 0
  fi
  [ -s "$OS_REQ" ] || return 0
  OS_FROM="$(sed -n '1s/|.*//p' "$OS_REQ")"
  OS_FROM="$(os_id "$OS_FROM")"
  [ "$OS_NOW" != "$OS_FROM" ] && [ -n "$OS_NOW" ] && [ -n "$OS_FROM" ] || return 0
  mv "$OS_REQ" "$OS_ROOT/consumed" || return 0
  OS_REC="$(sed -n '1p' "$OS_ROOT/consumed")"
  OS_VER="$(printf '%s' "$OS_REC" | cut -d '|' -f2)"
  OS_WANTED="$(printf '%s' "$OS_REC" | cut -d '|' -f3)"
  OS_BEFORE=unknown OS_AFTER=unknown OS_LABEL=unknown
  if ! os_safe_environment; then os_receipt REFUSED unsafe_boot_or_file_metadata; return 0; fi
  case "$OS_WANTED" in ''|*[!a-fA-F0-9]*) os_receipt REFUSED invalid_source_digest; return 0;; esac
  if [ "${#OS_WANTED}" -ne 64 ] || [ "$OS_VER" != 3112 ] ||
     [ "$(os_sha "$OS_ROOT/payload.db")" != "$OS_WANTED" ] ||
     ! db_integrity "$OS_ROOT/payload.db"; then
    os_receipt REFUSED snapshot_changed_or_invalid; return 0
  fi
  OS_BEFORE="$(os_sha "$DB")"
  if ! os_backup_family; then
    os_receipt REFUSED original_family_not_preserved; return 0
  fi
  OS_STAGE="$DB.guardian-oneshot-stage"
  if [ -e "$OS_STAGE" ] || [ -L "$OS_STAGE" ] ||
     ! cp "$OS_ROOT/payload.db" "$OS_STAGE" ||
     ! chmod 660 "$OS_STAGE" || ! chown 0:0 "$OS_STAGE" ||
     ! chcon "$OS_LABEL" "$OS_STAGE" ||
     [ "$(os_context "$OS_STAGE")" != "$OS_LABEL" ] ||
     [ "$(os_sha "$OS_STAGE")" != "$OS_WANTED" ]; then
    os_write_phase REFUSED_BEFORE_SWAP || :
    os_receipt REFUSED staged_file_cannot_be_verified; return 0
  fi
  # Check once more immediately before touching sidecars. This cannot prove
  # exclusive access forever, but narrows the race window and fails closed.
  if ! os_safe_environment || [ "$(os_sha "$DB")" != "$OS_BEFORE" ]; then
    os_write_phase REFUSED_BEFORE_SWAP || :
    os_receipt REFUSED boot_or_live_db_changed_after_staging
    return 0
  fi
  # WARNING: multi-file SQLite family swap is not atomic; journaled backups
  # remain until manual closure, and interruption recovery is one-shot only.
  if ! os_write_phase SWAP_STARTED; then
    os_receipt REFUSED unable_to_persist_mutation_intent; return 0
  fi
  OS_MOVE_OK=1
  for OS_EXT in -wal -shm -journal; do
    if [ -e "$DB$OS_EXT" ]; then
      mv "$DB$OS_EXT" "$OS_TX/retired$OS_EXT" || OS_MOVE_OK=0
    fi
  done
  if [ "$OS_MOVE_OK" -eq 1 ] && mv "$OS_STAGE" "$DB" &&
     [ "$(os_sha "$DB")" = "$OS_WANTED" ] &&
     [ "$(os_context "$DB")" = "$OS_LABEL" ]; then
    OS_AFTER="$(os_sha "$DB")"
    if os_write_phase COMMITTED_PENDING_HEALTH; then
      os_receipt COMMITTED_PENDING_HEALTH snapshot_swapped_pre_daemon
      return 0
    fi
  fi
  if os_offline_undo; then
    os_receipt ABORTED swap_failed_original_restored
  else
    os_receipt NEEDS_CUSTOM_RECOVERY swap_failed_restore_unconfirmed
  fi
  return 0
}
# Evidence-only reconciliation of the completed one-shot transaction. The
# original database family and its offline undo checksums are never modified.
# A receipt is a historical acceptance record, NOT a device-recovery permit.
os_receipt_verified() {
  [ ! -e "$OS_REQ" ] && [ ! -L "$OS_TX" ] || return 1
  [ -s "$OS_TX/phase" ] && [ -s "$OS_REPORT" ] && [ -s "$OS_HEALTH" ] || return 1
  case "$(cat "$OS_TX/phase")" in COMMITTED_PENDING_HEALTH|HEALTH_CONFIRMED) : ;; *) return 1;; esac
  OS_RBOOT="$(sed -n 's/^boot_id=//p' "$OS_REPORT")"
  OS_HBOOT="$(sed -n 's/^boot_id=//p' "$OS_HEALTH")"
  [ -n "$OS_RBOOT" ] && [ "$OS_RBOOT" = "$OS_HBOOT" ] &&
    [ "$(os_id "$OS_RBOOT")" = "$OS_RBOOT" ] || return 1
  grep -Fxq 'assessment=COMMITTED_PENDING_HEALTH' "$OS_REPORT" &&
  grep -Fxq 'phase=post-fs-data' "$OS_REPORT" &&
  grep -Fxq 'phase=post-boot-stability' "$OS_HEALTH" &&
  grep -Fxq 'vector=VECTOR_RESPONDING' "$OS_HEALTH" &&
  grep -Fxq 'enabled_manifest=MATCH' "$OS_HEALTH" &&
  grep -Fxq 'health=PASS' "$OS_HEALTH" &&
  grep -Fxq 'original_family_retained=true' "$OS_HEALTH" || return 1
  OS_RSRC="$(sed -n 's/^source_sha256=//p' "$OS_REPORT")"
  OS_RDST="$(sed -n 's/^restored_sha256=//p' "$OS_REPORT")"
  [ -n "$OS_RSRC" ] && [ "$OS_RSRC" = "$OS_RDST" ] &&
    [ "${#OS_RSRC}" -eq 64 ] || return 1
  [ "$(os_sha "$OS_ROOT/payload.db")" = "$OS_RSRC" ] || return 1
  [ -s "$OS_TX/original.db" ] && [ -s "$OS_TX/original.sha" ] || return 1
  for OS_EXT in '' -wal -shm -journal; do
    if [ -f "$OS_TX/original.db$OS_EXT" ]; then
      [ ! -L "$OS_TX/original.db$OS_EXT" ] &&
      [ -s "$OS_TX/original.sha$OS_EXT" ] &&
      [ "$(os_sha "$OS_TX/original.db$OS_EXT")" = "$(cat "$OS_TX/original.sha$OS_EXT")" ] || return 1
    else
      [ -f "$OS_TX/absent$OS_EXT" ] || return 1
    fi
  done
  [ -s "$OS_ROOT/expected.enabled" ] || return 1
}
os_finalize() {
  os_receipt_verified || { echo 'ONE_SHOT_FINALIZE_REFUSED: receipt or retained original family invalid' >&2; return 1; }
  [ "$AUTO_RECOVERY" = 0 ] && [ "$RECOVERY_DEVICE_QUALIFIED" = 0 ] || return 1
  # Validate current Vector availability and matching expected manifest, even
  # when finalizing a v0.9.3 receipt after a subsequent, healthy reboot.
  OS_FIN_MAN="$OS_ROOT/finalize-$$.enabled"
  if ! boot_complete || ! cli_ready || ! vector status >/dev/null 2>&1 ||
     ! vector_enabled_manifest "$OS_FIN_MAN" ||
     ! cmp -s "$OS_FIN_MAN" "$OS_ROOT/expected.enabled"; then
    rm -f "$OS_FIN_MAN"
    echo 'ONE_SHOT_FINALIZE_REFUSED: current Vector state not verified' >&2
    return 1
  fi
  rm -f "$OS_FIN_MAN"
  if [ "$(cat "$OS_TX/phase")" != HEALTH_CONFIRMED ]; then
    os_write_phase HEALTH_CONFIRMED || return 1
  fi
  echo 'PASS_GUARDIAN_ONE_SHOT_HEALTH_FINALIZED'
  echo "qualified_restoration_boot=$OS_RBOOT"
  echo 'original_family_retained=true'
  echo 'automatic_recovery=DISABLED'
}
os_stable() {
  [ -s "$OS_TX/phase" ] || return 0
  [ "$(cat "$OS_TX/phase")" = COMMITTED_PENDING_HEALTH ] || return 0
  OS_CURRENT="$(os_id "$(boot_id)")"
  grep -Fxq "boot_id=$OS_CURRENT" "$OS_REPORT" 2>/dev/null || return 0
  OS_HEALTH_STATE=FAILED
  OS_MAN="$OS_ROOT/current-$$.enabled"
  if cli_ready && vector status >/dev/null 2>&1 && vector_enabled_manifest "$OS_MAN" &&
     cmp -s "$OS_MAN" "$OS_ROOT/expected.enabled"; then
    OS_HEALTH_STATE=PASS
  fi
  rm -f "$OS_MAN"
  cat > "$OS_HEALTH.tmp.$$" <<EOF
schema=guardian-one-shot-stable-v1
boot_id=$OS_CURRENT
phase=post-boot-stability
vector=$( [ "$OS_HEALTH_STATE" = PASS ] && echo VECTOR_RESPONDING || echo NOT_VERIFIED )
enabled_manifest=$( [ "$OS_HEALTH_STATE" = PASS ] && echo MATCH || echo UNVERIFIED )
health=$OS_HEALTH_STATE
original_family_retained=true
automatic_recovery=DISABLED
EOF
  mv "$OS_HEALTH.tmp.$$" "$OS_HEALTH"
  sync
  if [ "$OS_HEALTH_STATE" = PASS ]; then
    os_finalize >/dev/null 2>&1 || log WARN "One-shot health observed but receipt finalization deferred"
  fi
}
os_status() {
  echo 'GUARDIAN REAL RESTORE ONE-SHOT (manual-only)'
  echo 'automatic_recovery=DISABLED'
  echo 'device_restore_qualified=UNQUALIFIED'
  [ ! -e "$OS_REQ" ] || echo 'state=STAGED_FOR_NEXT_BOOT'
  [ ! -s "$OS_TX/phase" ] || echo "transaction_phase=$(cat "$OS_TX/phase")"
  [ ! -s "$OS_REPORT" ] || cat "$OS_REPORT"
  [ ! -s "$OS_HEALTH" ] || cat "$OS_HEALTH"
  if os_receipt_verified; then
    echo 'PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE'
    echo 'note=Historical health-verified receipt only; original DB family retained; automatic recovery NOT qualified.'
    if [ "$(cat "$OS_TX/phase")" = HEALTH_CONFIRMED ]; then
      echo 'finalization=HEALTH_CONFIRMED'
    else
      echo 'finalization=PENDING_EXPLICIT_RECONCILIATION'
    fi
  else
    echo 'ONE_SHOT_RESTORE_NOT_QUALIFIED'
  fi
}
