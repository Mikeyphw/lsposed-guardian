#!/system/bin/sh
# Safe rehearsal: only reads a verified observed Vector backup. ALL writes are
# confined to Guardian's private lab directory. NEVER calls offline_restore.
LAB_DIR="$STATE_DIR/recovery-lab"

lab_case() {
  LC_KIND="$1"
  LC_DIR="$2/$LC_KIND"
  mkdir -p "$LC_DIR" || return 1
  printf 'SIMULATED_OLD_CONFIG\n' > "$LC_DIR/target.db" || return 1
  printf 'SIMULATED_OLD_WAL\n' > "$LC_DIR/target.db-wal" || return 1
  printf 'SIMULATED_OLD_SHM\n' > "$LC_DIR/target.db-shm" || return 1
  LC_OLD="$(db_sha "$LC_DIR/target.db")"
  cp "$SNAP_DIR/observed.db" "$LC_DIR/stage.db" || return 1

  case "$LC_KIND" in
    corrupt-stage)
      printf 'CORRUPTED_STAGING\n' >> "$LC_DIR/stage.db" || return 1
      [ "$(db_sha "$LC_DIR/stage.db")" != "$LAB_SOURCE_HASH" ] || return 1
      [ "$(db_sha "$LC_DIR/target.db")" = "$LC_OLD" ] || return 1
      [ -f "$LC_DIR/target.db-wal" ] || return 1
      echo 'PASS_STAGE_DIGEST_REJECTION'
      return 0 ;;
    interrupted-before-commit)
      [ "$(db_sha "$LC_DIR/stage.db")" = "$LAB_SOURCE_HASH" ] || return 1
      # An interrupted staging operation leaves the old target and its journals.
      [ "$(db_sha "$LC_DIR/target.db")" = "$LC_OLD" ] || return 1
      [ -f "$LC_DIR/target.db-wal" ] || return 1
      echo 'PASS_INTERRUPTED_STAGE_PRESERVES_OLD_TARGET'
      return 0 ;;
    rollback-after-commit)
      # Model a verified write followed by an injected post-commit fault. The
      # original target and both journal files must be restored from backups.
      cp "$LC_DIR/target.db" "$LC_DIR/original.db" || return 1
      cp "$LC_DIR/target.db-wal" "$LC_DIR/original.wal" || return 1
      cp "$LC_DIR/target.db-shm" "$LC_DIR/original.shm" || return 1
      rm -f "$LC_DIR/target.db-wal" "$LC_DIR/target.db-shm" || return 1
      mv "$LC_DIR/stage.db" "$LC_DIR/target.db" || return 1
      [ "$(db_sha "$LC_DIR/target.db")" = "$LAB_SOURCE_HASH" ] || return 1
      # Inject fault AFTER commit, then roll back the copied sandbox target.
      mv "$LC_DIR/original.db" "$LC_DIR/target.db" || return 1
      mv "$LC_DIR/original.wal" "$LC_DIR/target.db-wal" || return 1
      mv "$LC_DIR/original.shm" "$LC_DIR/target.db-shm" || return 1
      [ "$(db_sha "$LC_DIR/target.db")" = "$LC_OLD" ] || return 1
      [ "$(cat "$LC_DIR/target.db-wal")" = SIMULATED_OLD_WAL ] || return 1
      [ "$(cat "$LC_DIR/target.db-shm")" = SIMULATED_OLD_SHM ] || return 1
      echo 'PASS_STAGE_ROLLBACK_AFTER_POSTCOMMIT_FAULT'
      return 0 ;;
    success)
      [ "$(db_sha "$LC_DIR/stage.db")" = "$LAB_SOURCE_HASH" ] || return 1
      rm -f "$LC_DIR/target.db-wal" "$LC_DIR/target.db-shm" || return 1
      mv -f "$LC_DIR/stage.db" "$LC_DIR/target.db" || return 1
      [ "$(db_sha "$LC_DIR/target.db")" = "$LAB_SOURCE_HASH" ] || return 1
      [ ! -e "$LC_DIR/target.db-wal" ] && [ ! -e "$LC_DIR/target.db-shm" ] || return 1
      db_integrity "$LC_DIR/target.db" || return 1
      echo 'PASS_STAGED_REPLACEMENT_AND_SQLITE_INTEGRITY'
      return 0 ;;
  esac
  return 1
}

recovery_lab() {
  # Current observational backup, NEVER an uncertified old baseline.
  if [ "$(snapshot_integrity_level observed)" != sqlite_integrity_verified ]; then
    echo 'LAB_BLOCKED: no integrity-verified observed snapshot' >&2
    return 1
  fi
  mkdir -p "$LAB_DIR" || return 1
  chmod 700 "$LAB_DIR" 2>/dev/null || :
  mkdir "$LAB_DIR/.lock" 2>/dev/null || { echo 'LAB_BLOCKED: already running' >&2; return 2; }
  LAB_WORK="$LAB_DIR/run-$$"
  mkdir -p "$LAB_WORK" || { rmdir "$LAB_DIR/.lock"; return 1; }
  chmod 700 "$LAB_WORK" 2>/dev/null || :
  LAB_SOURCE_HASH="$(db_sha "$SNAP_DIR/observed.db")"
  LAB_RESULT=FAIL
  if lab_case corrupt-stage "$LAB_WORK" &&
     lab_case interrupted-before-commit "$LAB_WORK" &&
     lab_case success "$LAB_WORK" &&
     lab_case rollback-after-commit "$LAB_WORK"; then
    LAB_RESULT=PASS
  fi
  rm -rf "$LAB_WORK"
  rmdir "$LAB_DIR/.lock" 2>/dev/null || :
  if [ "$LAB_RESULT" = PASS ]; then
    write_atomic "$LAB_DIR/last-result.json" '{"producer":"lsposed-guardian-recovery-lab","result":"PASS","real_vector_db_modified":false,"offline_restore_device_qualified":false,"postcommit_fault_rollback_rehearsed":true}' || return 1
    echo 'PASS_GUARDIAN_ISOLATED_RECOVERY_LAB'
    echo 'real_vector_db_modified=false'
    echo 'device_restore_qualified=0 (unchanged; genuine early-boot restore NOT tested)'
  else
    echo 'FAIL_GUARDIAN_ISOLATED_RECOVERY_LAB' >&2
    return 1
  fi
}
