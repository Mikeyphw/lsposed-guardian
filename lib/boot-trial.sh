#!/system/bin/sh
# Opt-in, one-hardware-boot rehearsal of WAL/SHM retirement on ISOLATED copies
# in Vector's own configuration filesystem. NEVER mutates live DB or sidecars.
BT_ROOT="$STATE_DIR/boot-trial"
BT_REQUEST="$BT_ROOT/request"
BT_REPORT="$BT_ROOT/early.txt"
BT_STABLE="$BT_ROOT/stable.txt"

bt_setup() { mkdir -p "$BT_ROOT" && chmod 700 "$BT_ROOT" 2>/dev/null; }
bt_id() { printf '%s' "$1" | tr -cd 'a-fA-F0-9-'; }
bt_sha() {
  BT_DIGEST="$(/system/bin/sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$BT_DIGEST" in *[!a-fA-F0-9]*|'') return 1;; esac
  [ "${#BT_DIGEST}" -eq 64 ] || return 1
  printf '%s' "$BT_DIGEST"
}
# Host and recovery environments may not have /system/bin/sha256sum; Android
# uses that exact binary when present. Never use a function called `hash`.
bt_sha_checked() {
  if [ -x /system/bin/sha256sum ]; then bt_sha "$1"; return $?; fi
  BT_DIGEST="$(sha256sum "$1" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$BT_DIGEST" in *[!a-fA-F0-9]*|'') return 1;; esac
  [ "${#BT_DIGEST}" -eq 64 ] && printf '%s' "$BT_DIGEST"
}
bt_record() {
  BT_RECEIPT="schema=guardian-boot-trial-v1
observed_boot_id=$(bt_id "$(boot_id)")
request_from_boot_id=$BT_FROM
phase=post-fs-data
assessment=$1
reason=$2
boot_completed=${BT_BOOTED:-unknown}
vectord_pid=${BT_PID:-unknown}
vector_version=${BT_VECTOR_VERSION:-unknown}
live_db_hash_before=${BT_DB_BEFORE:-unknown}
live_db_hash_after=${BT_DB_AFTER:-unknown}
wal_present=${BT_WAL_PRESENT:-unknown}
shm_present=${BT_SHM_PRESENT:-unknown}
context=${BT_CONTEXT:-unknown}
observed_epoch=$(date +%s)"
  write_atomic "$BT_REPORT" "$BT_RECEIPT"
}
bt_stage() {
  bt_setup || return 1
  [ "$AUTO_RECOVERY" = 0 ] && [ "$RECOVERY_DEVICE_QUALIFIED" = 0 ] || {
    echo 'Refusing: OBSERVE mode and device qualification=0 required' >&2; return 1;
  }
  [ ! -e "$BOOT_DIR/manual-restore" ] || { echo 'Manual restore already queued' >&2; return 1; }
  [ ! -e "$BT_REQUEST" ] || { echo 'Boot trial already pending' >&2; return 1; }
  [ ! -e "$BT_ROOT/in-progress" ] || { echo 'Unresolved boot trial, refusing' >&2; return 1; }
  boot_complete || { echo 'Android boot not complete' >&2; return 1; }
  BT_OLD="$(bt_id "$(boot_id)")"
  [ -n "$BT_OLD" ] && [ "$(bt_id "$(read_first "$BOOT_DIR/last-success-id")")" = "$BT_OLD" ] || {
    echo 'Current hardware boot not yet stable' >&2; return 1;
  }
  # Strictly require the exact, previously successful real-device boot-order receipt.
  grep -Fxq "observed_boot_id=$BT_OLD" "$STATE_DIR/boot-probe/early.txt" 2>/dev/null &&
  grep -Fxq "observed_boot_id=$BT_OLD" "$STATE_DIR/boot-probe/stable.txt" 2>/dev/null &&
  grep -Fxq 'assessment=EARLY_CANDIDATE' "$STATE_DIR/boot-probe/early.txt" 2>/dev/null &&
  grep -Fxq 'vector=VECTOR_RESPONDING' "$STATE_DIR/boot-probe/stable.txt" 2>/dev/null || {
    echo 'Real boot-order observation must have passed on this exact boot' >&2; return 1;
  }
  BT_RESCUE="${GUARDIAN_RESCUE_SCRIPT:-/data/local/tmp/guardian-recover.sh}"
  [ -f "$BT_RESCUE" ] && sh "$BT_RESCUE" status 2>/dev/null | grep -Fxq 'backup_integrity=PASS' || {
    echo 'Verified custom-recovery rescue backup required' >&2; return 1;
  }
  cli_ready && vector status >/dev/null 2>&1 || { echo 'Vector not responding' >&2; return 1; }
  [ "$(snapshot_integrity_level observed)" = sqlite_integrity_verified ] || {
    echo 'Observed consistent Vector backup not integrity-qualified' >&2; return 1;
  }
  BT_VER="$(vector_version_code)"
  [ -n "$BT_VER" ] && [ "$BT_VER" = "$(read_first "$SNAP_DIR/observed.vector-version")" ] || {
    echo 'Observed backup Vector version mismatch' >&2; return 1;
  }
  BT_SHA="$(bt_sha_checked "$SNAP_DIR/observed.db")" || return 1
  [ "$BT_SHA" = "$(read_first "$SNAP_DIR/observed.sha256")" ] || return 1
  # Record request last. Source snapshot is already pinned read-only and verified.
  write_atomic "$BT_REQUEST" "$BT_OLD|$BT_VER|$BT_SHA" || return 1
  echo 'PASS_GUARDIAN_BOOT_TRIAL_STAGED'
  echo 'scope=isolated_copy_in_vector_config_directory'
  echo 'real_vector_db_mutation=FORBIDDEN'
  echo 'reboot_manually=yes'
}
bt_cancel() {
  bt_setup || return 1
  [ ! -e "$BT_ROOT/in-progress" ] || { echo 'Cannot cancel an in-progress transaction' >&2; return 1; }
  rm -f "$BT_REQUEST"
  echo 'PASS_GUARDIAN_BOOT_TRIAL_REQUEST_CANCELLED'
}
bt_early() {
  [ -s "$BT_REQUEST" ] || return 0
  BT_NOW="$(bt_id "$(boot_id)")"
  BT_FROM="$(sed -n '1s/|.*//p' "$BT_REQUEST")"
  BT_FROM="$(bt_id "$BT_FROM")"
  [ -n "$BT_NOW" ] && [ -n "$BT_FROM" ] && [ "$BT_NOW" != "$BT_FROM" ] || return 0
  # Consume request BEFORE all file I/O; no automatic retry after a partial run.
  mv "$BT_REQUEST" "$BT_ROOT/in-progress" || return 1
  BT_REC="$(sed -n '1p' "$BT_ROOT/in-progress")"
  BT_VER_WANTED="$(printf '%s\n' "$BT_REC" | cut -d '|' -f2)"
  BT_SHA_WANTED="$(printf '%s\n' "$BT_REC" | cut -d '|' -f3)"
  BT_BOOTED="$(getprop sys.boot_completed 2>/dev/null)"
  BT_PID="$(pidof vectord 2>/dev/null | tr -cd '0-9 ')"
  [ -n "$BT_PID" ] || BT_PID=none
  BT_VECTOR_VERSION="$(vector_version_code)"
  BT_DB_BEFORE=unknown BT_DB_AFTER=unknown BT_CONTEXT=unknown
  BT_WAL_PRESENT=no BT_SHM_PRESENT=no
  [ ! -f "$DB-wal" ] || BT_WAL_PRESENT=yes
  [ ! -f "$DB-shm" ] || BT_SHM_PRESENT=yes
  BT_RESULT=REFUSED BT_REASON=prerequisite_failure
  # Do not allow trial operations after startup or while Vector is running.
  if [ "$AUTO_RECOVERY" != 0 ] || [ "$RECOVERY_DEVICE_QUALIFIED" != 0 ] ||
     [ "$BT_BOOTED" = 1 ] || [ "$BT_PID" != none ] ||
     [ -e "$BOOT_DIR/manual-restore" ] || [ -e "$BOOT_DIR/recovery-performed" ]; then
    BT_REASON=unsafe_boot_state
  elif [ "$BT_VER_WANTED" != "$BT_VECTOR_VERSION" ] || [ -z "$BT_VER_WANTED" ] ||
       [ "$(printf '%s' "$BT_SHA_WANTED" | tr -cd 'a-fA-F0-9')" != "$BT_SHA_WANTED" ] ||
       [ "${#BT_SHA_WANTED}" -ne 64 ]; then
    BT_REASON=invalid_or_mismatched_request
  elif [ -L "$DB" ] || [ -L "$DB-wal" ] || [ -L "$DB-shm" ] ||
       [ ! -f "$DB" ] || [ ! -d "${DB%/*}" ]; then
    BT_REASON=live_database_path_invalid
  elif [ "$(bt_sha_checked "$SNAP_DIR/observed.db")" != "$BT_SHA_WANTED" ]; then
    BT_REASON=snapshot_digest_mismatch
  else
    # All write operations below are in a NEW hidden directory and never use
    # the live DB or live sidecars as destinations. No unlink/mv of live paths.
    BT_TEST_DIR="${DB%/*}/.guardian-trial-$BT_NOW"
    if [ -e "$BT_TEST_DIR" ] || [ -L "$BT_TEST_DIR" ]; then
      BT_REASON=trial_path_preexists
    elif mkdir -m 700 "$BT_TEST_DIR"; then
      BT_DB_BEFORE="$(bt_sha_checked "$DB")"
      BT_WAL_BEFORE=missing BT_SHM_BEFORE=missing
      [ ! -f "$DB-wal" ] || BT_WAL_BEFORE="$(bt_sha_checked "$DB-wal")"
      [ ! -f "$DB-shm" ] || BT_SHM_BEFORE="$(bt_sha_checked "$DB-shm")"
      BT_REASON=copy_or_verify_failure
      if [ -n "$BT_DB_BEFORE" ] &&
         cp "$DB" "$BT_TEST_DIR/copy.db" &&
         cp "$SNAP_DIR/observed.db" "$BT_TEST_DIR/replacement.db"; then
        BT_SIDE_OK=1
        for BT_EXT in wal shm journal; do
          if [ -f "$DB-$BT_EXT" ]; then
            cp "$DB-$BT_EXT" "$BT_TEST_DIR/copy.db-$BT_EXT" || BT_SIDE_OK=0
          fi
        done
        if [ "$BT_SIDE_OK" -eq 1 ]; then
          # Exercise WAL retirement and DB rename ONLY against the copies.
          for BT_EXT in wal shm journal; do
            [ ! -e "$BT_TEST_DIR/copy.db-$BT_EXT" ] ||
              mv "$BT_TEST_DIR/copy.db-$BT_EXT" "$BT_TEST_DIR/retired-$BT_EXT" || BT_SIDE_OK=0
          done
          if [ "$BT_SIDE_OK" -eq 1 ] &&
             mv "$BT_TEST_DIR/replacement.db" "$BT_TEST_DIR/copy.db" &&
             [ "$(bt_sha_checked "$BT_TEST_DIR/copy.db")" = "$BT_SHA_WANTED" ]; then
            BT_DB_AFTER="$(bt_sha_checked "$DB")"
            BT_WAL_AFTER=missing BT_SHM_AFTER=missing
            [ ! -f "$DB-wal" ] || BT_WAL_AFTER="$(bt_sha_checked "$DB-wal")"
            [ ! -f "$DB-shm" ] || BT_SHM_AFTER="$(bt_sha_checked "$DB-shm")"
            if [ "$BT_DB_BEFORE" = "$BT_DB_AFTER" ] &&
               [ "$BT_WAL_BEFORE" = "$BT_WAL_AFTER" ] &&
               [ "$BT_SHM_BEFORE" = "$BT_SHM_AFTER" ]; then
              BT_RESULT=PASS_COPY_ONLY BT_REASON=isolated_transaction_verified
              BT_CONTEXT="$(ls -ldZ "$BT_TEST_DIR/copy.db" 2>/dev/null | awk '{print $(NF-3)}')"
            else BT_REASON=live_family_changed_during_rehearsal; fi
          fi
        fi
      fi
      # Keep copy-only artifacts for offline inspection, never delete during boot.
    else BT_REASON=cannot_create_isolated_directory; fi
  fi
  bt_record "$BT_RESULT" "$BT_REASON" || :
  rm -f "$BT_ROOT/in-progress" || :
  log BOOT_TRIAL "Copy-only post-fs-data rehearsal: $BT_RESULT ($BT_REASON)"
  [ "$BT_RESULT" = PASS_COPY_ONLY ]
}
bt_stable() {
  [ -s "$BT_REPORT" ] || return 0
  BT_CURRENT="$(bt_id "$(boot_id)")"
  grep -Fxq "observed_boot_id=$BT_CURRENT" "$BT_REPORT" 2>/dev/null || return 0
  grep -Fxq "observed_boot_id=$BT_CURRENT" "$BT_STABLE" 2>/dev/null && return 0
  BT_HEALTH=VECTOR_NOT_RESPONDING
  if cli_ready && vector status >/dev/null 2>&1; then BT_HEALTH=VECTOR_RESPONDING; fi
  write_atomic "$BT_STABLE" "schema=guardian-boot-trial-stable-v1
observed_boot_id=$BT_CURRENT
phase=post-boot-stability
vector=$BT_HEALTH
observed_epoch=$(date +%s)"
}
bt_status() {
  echo 'GUARDIAN EARLY BOOT COPY-ONLY REHEARSAL'
  echo 'real_vector_db_modified_by_trial=false'
  echo 'automatic_restore=DISABLED'
  echo 'device_restore_qualified=UNQUALIFIED'
  [ ! -e "$BT_REQUEST" ] || echo 'state=STAGED_NEXT_HARDWARE_BOOT'
  [ ! -e "$BT_ROOT/in-progress" ] || echo 'state=UNRESOLVED_IN_PROGRESS'
  [ ! -s "$BT_REPORT" ] || cat "$BT_REPORT"
  [ ! -s "$BT_STABLE" ] || cat "$BT_STABLE"
  BT_CURRENT="$(bt_id "$(boot_id)")"
  if [ ! -e "$BT_REQUEST" ] && [ ! -e "$BT_ROOT/in-progress" ] &&
     grep -Fxq "observed_boot_id=$BT_CURRENT" "$BT_REPORT" 2>/dev/null &&
     grep -Fxq 'assessment=PASS_COPY_ONLY' "$BT_REPORT" 2>/dev/null &&
     grep -Fxq "observed_boot_id=$BT_CURRENT" "$BT_STABLE" 2>/dev/null &&
     grep -Fxq 'vector=VECTOR_RESPONDING' "$BT_STABLE" 2>/dev/null; then
    echo 'PASS_GUARDIAN_REAL_BOOT_COPY_ONLY_TRIAL'
    echo 'note=Live DB never intentionally changed; exclusive access and true restore remain unqualified.'
  else
    echo 'BOOT_TRIAL_NOT_QUALIFIED'
  fi
}
