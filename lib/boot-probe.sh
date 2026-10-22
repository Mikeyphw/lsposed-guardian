#!/system/bin/sh
# One-shot, read-only observation of the *real* KernelSU post-fs-data ordering.
# Does not modify Vector, does not arm restore, and does not infer exclusive access.
BP_DIR="$STATE_DIR/boot-probe"

bp_setup() {
  mkdir -p "$BP_DIR" || return 1
  chmod 700 "$BP_DIR" 2>/dev/null || :
}

bp_clean_boot_id() { printf '%s' "$1" | tr -cd 'a-fA-F0-9-'; }

bp_stage() {
  bp_setup || return 1
  [ "$AUTO_RECOVERY" = 0 ] || { echo 'Refusing: Guardian must be OBSERVE' >&2; return 1; }
  [ "$RECOVERY_DEVICE_QUALIFIED" = 0 ] || { echo 'Refusing: device qualification must remain disabled' >&2; return 1; }
  [ ! -e "$BOOT_DIR/manual-restore" ] || { echo 'Refusing: manual restoration already queued' >&2; return 1; }
  [ ! -e "$BP_DIR/request" ] || { echo 'Boot probe already requested' >&2; return 1; }
  boot_complete || { echo 'Refusing: boot incomplete' >&2; return 1; }
  ID="$(bp_clean_boot_id "$(boot_id)")"
  [ -n "$ID" ] || return 1
  [ "$(bp_clean_boot_id "$(read_first "$BOOT_DIR/last-success-id")")" = "$ID" ] || {
    echo 'Refusing: current boot not yet classified stable' >&2; return 1;
  }
  cli_ready && vector status >/dev/null 2>&1 || { echo 'Refusing: Vector not responding' >&2; return 1; }
  write_atomic "$BP_DIR/request" "$ID" || return 1
  echo 'PASS_GUARDIAN_BOOT_PROBE_STAGED'
  echo 'request_from_boot_id='"$ID"
  echo 'Vector unchanged; reboot manually when ready. Guardian stays OBSERVE.'
}

bp_early() {
  [ -s "$BP_DIR/request" ] || return 0
  NEW="$(bp_clean_boot_id "$(boot_id)")"
  OLD="$(bp_clean_boot_id "$(read_first "$BP_DIR/request")")"
  [ -n "$NEW" ] && [ -n "$OLD" ] && [ "$NEW" != "$OLD" ] || return 0
  # Record before any Guardian automatic recovery decision. Read-only Vector observations.
  BOOTED="$(getprop sys.boot_completed 2>/dev/null)"
  case "$BOOTED" in 1) BOOTED=1 ;; *) BOOTED=0 ;; esac
  VP="$(pidof vectord 2>/dev/null | tr -cd '0-9 ')"
  [ -n "$VP" ] || VP=none
  SE="$(getenforce 2>/dev/null)"
  case "$SE" in Enforcing|Permissive|Disabled) : ;; *) SE=unknown ;; esac
  DB_SEEN=no; [ ! -f "$DB" ] || DB_SEEN=yes
  WAL_SEEN=no; [ ! -e "$DB-wal" ] || WAL_SEEN=yes
  SHM_SEEN=no; [ ! -e "$DB-shm" ] || SHM_SEEN=yes
  STATUS=EARLY_CANDIDATE
  [ "$BOOTED" = 0 ] || STATUS=TOO_LATE_BOOT_COMPLETED
  [ "$VP" = none ] || STATUS=TOO_LATE_VECTOR_RUNNING
  CONTENT="schema=guardian-boot-probe-v1
observed_boot_id=$NEW
request_from_boot_id=$OLD
phase=post-fs-data
boot_completed=$BOOTED
vectord_pid=$VP
selinux=$SE
db_present=$DB_SEEN
wal_present=$WAL_SEEN
shm_present=$SHM_SEEN
assessment=$STATUS
observed_epoch=$(date +%s)"
  write_atomic "$BP_DIR/early.txt" "$CONTENT" || { log ERROR 'Boot probe observation could not be stored'; return 1; }
  rm -f "$BP_DIR/stable.txt" "$BP_DIR/request"
  log BOOT_PROBE "Read-only post-fs-data order evidence saved: $STATUS"
}

bp_stable() {
  [ -s "$BP_DIR/early.txt" ] || return 0
  ID="$(bp_clean_boot_id "$(boot_id)")"
  grep -Fxq "observed_boot_id=$ID" "$BP_DIR/early.txt" || return 0
  grep -Fxq "observed_boot_id=$ID" "$BP_DIR/stable.txt" 2>/dev/null && return 0
  RESULT=VECTOR_NOT_RESPONDING
  if cli_ready && vector status >/dev/null 2>&1; then RESULT=VECTOR_RESPONDING; fi
  CONTENT="schema=guardian-boot-probe-stability-v1
observed_boot_id=$ID
phase=post-boot-stability
boot_completed=$(getprop sys.boot_completed 2>/dev/null)
vector=$RESULT
observed_epoch=$(date +%s)"
  write_atomic "$BP_DIR/stable.txt" "$CONTENT" || log ERROR 'Boot probe stable receipt failed'
}

bp_status() {
  echo 'GUARDIAN REAL BOOT ORDER PROBE (read-only)'
  echo 'device_restore_qualification=UNQUALIFIED'
  echo "automatic_recovery=$([ "$AUTO_RECOVERY" = 0 ] && echo DISABLED || echo ARMED)"
  if [ -s "$BP_DIR/request" ]; then
    echo 'state=AWAITING_NEXT_HARDWARE_BOOT'
    echo "request_from_boot_id=$(read_first "$BP_DIR/request")"
    return 0
  fi
  if [ ! -s "$BP_DIR/early.txt" ]; then
    echo 'state=NOT_OBSERVED'
    return 0
  fi
  cat "$BP_DIR/early.txt"
  if [ -s "$BP_DIR/stable.txt" ]; then cat "$BP_DIR/stable.txt"; fi
  if grep -Fxq 'assessment=EARLY_CANDIDATE' "$BP_DIR/early.txt" &&
     grep -Fxq 'vector=VECTOR_RESPONDING' "$BP_DIR/stable.txt" 2>/dev/null &&
     grep -Fxq "observed_boot_id=$(bp_clean_boot_id "$(boot_id)")" "$BP_DIR/early.txt"; then
    echo 'PASS_GUARDIAN_BOOT_ORDER_OBSERVED'
    echo 'note=Observed pre-daemon once; race-free exclusive DB access and restore remain UNVERIFIED.'
  else
    echo 'BOOT_ORDER_NOT_YET_ACCEPTED'
  fi
}
