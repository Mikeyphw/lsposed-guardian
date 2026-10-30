#!/system/bin/sh
# Shared code; sources must define MODDIR before loading.
umask 077
STATE_DIR="${GUARDIAN_STATE_DIR:-/data/adb/lsposed-guardian}"
BOOT_DIR="$STATE_DIR/boot"
SNAP_DIR="$STATE_DIR/snapshots"
LOG_DIR="$STATE_DIR/logs"
DB="${GUARDIAN_VECTOR_DB:-/data/adb/lspd/config/modules_config.db}"
VECTOR_CLI="${GUARDIAN_VECTOR_CLI:-/data/adb/modules/zygisk_vector/cli}"
VECTOR_PROP="${GUARDIAN_VECTOR_MODULE_PROP:-/data/adb/modules/zygisk_vector/module.prop}"
BOOT_ID_PATH="${GUARDIAN_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
CFG="$STATE_DIR/config.conf"

init_state() {
  mkdir -p "$BOOT_DIR" "$SNAP_DIR" "$LOG_DIR" || return 1
  chmod 700 "$STATE_DIR" "$BOOT_DIR" "$SNAP_DIR" "$LOG_DIR" 2>/dev/null || :
  if [ ! -f "$CFG" ]; then
    cp "$MODDIR/config.defaults" "$CFG" || return 1
    chmod 600 "$CFG" 2>/dev/null || :
  fi
}

is_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

load_config() {
  AUTO_RECOVERY=0 FAILURE_THRESHOLD=2 STABILITY_SECONDS=60
  BOOT_WAIT_SECONDS=210 CHECK_SYSTEMUI=1
  PASSIVE_CRASH_MONITOR=1 CRASH_POLL_SECONDS=60 CRASH_WINDOW_SECONDS=300
  RECOVERY_DEVICE_QUALIFIED=0 CRASH_EXCLUDE_PACKAGES=com.openai.chatgpt
  HISTORY_MONITOR=1 HISTORY_POLL_SECONDS=180 HISTORY_MAX_AGE_SECONDS=240
  AUTO_QUARANTINE=0 AUTO_QUARANTINE_ALLOWLIST= AUTO_QUARANTINE_POLICY=allowlist AUTO_QUARANTINE_COOLDOWN_SECONDS=43200 AUTO_SAFE_MODE=0 AUTO_BOOTLOOP_REBOOT=0
  [ -f "$CFG" ] && . "$CFG"
  case "$AUTO_RECOVERY" in 0|1) : ;; *) AUTO_RECOVERY=0 ;; esac
  # Legacy unattended SQLite restore is deliberately retired. Never let its
  # persisted config flag re-enable the unsafe unjournaled restore function.
  case "$AUTO_QUARANTINE" in 0|1) : ;; *) AUTO_QUARANTINE=0 ;; esac
  case "$AUTO_SAFE_MODE" in 0|1) : ;; *) AUTO_SAFE_MODE=0 ;; esac
  case "$AUTO_BOOTLOOP_REBOOT" in 0|1) : ;; *) AUTO_BOOTLOOP_REBOOT=0 ;; esac
  case "$AUTO_QUARANTINE_POLICY" in allowlist|all_scoped) : ;; *) AUTO_QUARANTINE_POLICY=allowlist; AUTO_QUARANTINE=0 ;; esac
  case "$AUTO_QUARANTINE_ALLOWLIST" in
    *[!a-zA-Z0-9_.,]*|*..*|*,,*) AUTO_QUARANTINE=0; AUTO_QUARANTINE_ALLOWLIST= ;; esac
  if ! is_number "$AUTO_QUARANTINE_COOLDOWN_SECONDS" ||
     [ "$AUTO_QUARANTINE_COOLDOWN_SECONDS" -lt 3600 ] ||
     [ "$AUTO_QUARANTINE_COOLDOWN_SECONDS" -gt 604800 ]; then
    AUTO_QUARANTINE_COOLDOWN_SECONDS=43200
  fi
  case "$RECOVERY_DEVICE_QUALIFIED" in 0|1) : ;; *) RECOVERY_DEVICE_QUALIFIED=0 ;; esac
  # Explicit user instruction: ChatGPT crashes are unrelated to LSPosed.
  # Preserve this exclusion even when upgrading old config.conf without the key.
  case ",$CRASH_EXCLUDE_PACKAGES," in
    *,com.openai.chatgpt,*) : ;;
    *) CRASH_EXCLUDE_PACKAGES="${CRASH_EXCLUDE_PACKAGES:+$CRASH_EXCLUDE_PACKAGES,}com.openai.chatgpt" ;;
  esac
  if ! is_number "$FAILURE_THRESHOLD" || [ "$FAILURE_THRESHOLD" -lt 2 ] || [ "$FAILURE_THRESHOLD" -gt 10 ]; then FAILURE_THRESHOLD=2; fi
  if ! is_number "$STABILITY_SECONDS" || [ "$STABILITY_SECONDS" -lt 15 ] || [ "$STABILITY_SECONDS" -gt 600 ]; then STABILITY_SECONDS=60; fi
  if ! is_number "$BOOT_WAIT_SECONDS" || [ "$BOOT_WAIT_SECONDS" -lt 30 ] || [ "$BOOT_WAIT_SECONDS" -gt 900 ]; then BOOT_WAIT_SECONDS=210; fi
  case "$CHECK_SYSTEMUI" in 0|1) : ;; *) CHECK_SYSTEMUI=1 ;; esac
  case "$PASSIVE_CRASH_MONITOR" in 0|1) : ;; *) PASSIVE_CRASH_MONITOR=1 ;; esac
  if ! is_number "$CRASH_POLL_SECONDS" || [ "$CRASH_POLL_SECONDS" -lt 30 ] || [ "$CRASH_POLL_SECONDS" -gt 600 ]; then CRASH_POLL_SECONDS=60; fi
  if ! is_number "$CRASH_WINDOW_SECONDS" || [ "$CRASH_WINDOW_SECONDS" -lt 60 ] || [ "$CRASH_WINDOW_SECONDS" -gt 3600 ]; then CRASH_WINDOW_SECONDS=300; fi
  case "$HISTORY_MONITOR" in 0|1) : ;; *) HISTORY_MONITOR=1 ;; esac
  if ! is_number "$HISTORY_POLL_SECONDS" || [ "$HISTORY_POLL_SECONDS" -lt 60 ] || [ "$HISTORY_POLL_SECONDS" -gt 1800 ]; then HISTORY_POLL_SECONDS=180; fi
  if ! is_number "$HISTORY_MAX_AGE_SECONDS" || [ "$HISTORY_MAX_AGE_SECONDS" -lt 60 ] || [ "$HISTORY_MAX_AGE_SECONDS" -gt 1800 ]; then HISTORY_MAX_AGE_SECONDS=240; fi
}

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date; }
log() {
  MSG="$(stamp) [$1] $2"
  printf '%s\n' "$MSG" >> "$LOG_DIR/guardian.log" 2>/dev/null || :
  /system/bin/log -t LSPosedGuardian -p i "$2" >/dev/null 2>&1 || :
}

read_first() { [ -f "$1" ] && IFS= read -r OUT < "$1" && printf '%s' "$OUT"; }
write_atomic() {
  TO="$1" VALUE="$2" TMP="$1.tmp.$$"
  printf '%s\n' "$VALUE" > "$TMP" || return 1
  mv -f "$TMP" "$TO"
}
# Read the single installed source of truth. Never hardcode a second version in reports.
guardian_version() {
  GV="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
  case "$GV" in ''|*[!0-9.]*) printf '%s' unknown ;; *) printf '%s' "$GV" ;; esac
}

# Older v0.4 snapshots did not retain their originating kernel boot ID.
# Preserve them as-is but never claim that the current observation is their origin.
baseline_provenance() {
  if [ ! -f "$SNAP_DIR/last-good.db" ]; then
    printf '%s' unavailable
  elif [ -s "$SNAP_DIR/last-good.boot-id" ] && [ -s "$SNAP_DIR/last-good.complete" ]; then
    printf '%s' recorded
  else
    printf '%s' unknown_legacy
  fi
}
baseline_boot_label() {
  BID="$(read_first "$SNAP_DIR/last-good.boot-id")"
  if [ -n "$BID" ]; then
    printf '%s' "$BID"
  elif [ -f "$SNAP_DIR/last-good.db" ]; then
    printf '%s' unknown_legacy
  else
    printf '%s' unavailable
  fi
}
boot_id() { [ -r "$BOOT_ID_PATH" ] && read_first "$BOOT_ID_PATH"; }
boot_complete() { [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; }
cli_ready() { [ -f "$VECTOR_CLI" ] && [ -x "$VECTOR_CLI" ]; }
vector() { cli_ready || return 127; "$VECTOR_CLI" "$@"; }
vector_version_code() {
  [ -r "$VECTOR_PROP" ] || return 1
  sed -n 's/^versionCode=\([0-9][0-9]*\)$/\1/p' "$VECTOR_PROP" | head -n 1
}
valid_db() {
  [ -s "$1" ] || return 1
  [ "$(dd if="$1" bs=15 count=1 2>/dev/null)" = 'SQLite format 3' ]
}

# Snapshot attestation: a cryptographic digest is required for safety, not just
# SQLite's 15-byte header. SQLite's CLI is not guaranteed on stock Android.
# If absent, snapshots remain observable but CANNOT be promoted or restored.
sqlite_tool() {
  if [ -n "${GUARDIAN_SQLITE_CLI:-}" ]; then
    [ -x "$GUARDIAN_SQLITE_CLI" ] || return 1
    printf '%s' "$GUARDIAN_SQLITE_CLI"
  else
    command -v sqlite3 2>/dev/null
  fi
}
db_integrity() {
  [ -s "$1" ] && valid_db "$1" || return 1
  ST="$(sqlite_tool)" || return 2
  [ "$("$ST" -readonly "$1" 'PRAGMA integrity_check;' 2>/dev/null)" = ok ] || return 1
  # Disallow unrelated databases and truncated / wrong Vector schemas.
  SC="$("$ST" -readonly "$1" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('modules','scope','configs');" 2>/dev/null)" || return 1
  [ "$SC" = 3 ] || return 1
  COL="$("$ST" -readonly "$1" "SELECT COUNT(*) FROM pragma_table_info('modules') WHERE name IN ('module_pkg_name','enabled','apk_path');" 2>/dev/null)" || return 1
  [ "$COL" = 3 ] || return 1
}
db_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
db_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
attest_snapshot() {
  AS_PREFIX="$1"
  valid_db "$SNAP_DIR/$AS_PREFIX.db" || return 1
  AH="$(db_sha "$SNAP_DIR/$AS_PREFIX.db")"
  AB="$(db_bytes "$SNAP_DIR/$AS_PREFIX.db")"
  case "$AH" in *[!a-fA-F0-9]*|'') return 1 ;; esac
  [ "${#AH}" -eq 64 ] || return 1
  is_number "$AB" && [ "$AB" -gt 512 ] || return 1
  db_integrity "$SNAP_DIR/$AS_PREFIX.db" || return 1
  write_atomic "$SNAP_DIR/$AS_PREFIX.sha256" "$AH" || return 1
  write_atomic "$SNAP_DIR/$AS_PREFIX.bytes" "$AB" || return 1
  write_atomic "$SNAP_DIR/$AS_PREFIX.validation" 'sqlite_integrity_verified' || return 1
}
snapshot_integrity_level() {
  IL_PREFIX="$1"
  [ ! -f "$SNAP_DIR/baseline-in-progress" ] || { echo interrupted; return 1; }
  valid_db "$SNAP_DIR/$IL_PREFIX.db" || { echo missing_or_header_invalid; return 1; }
  if [ ! -s "$SNAP_DIR/$IL_PREFIX.sha256" ] || [ ! -s "$SNAP_DIR/$IL_PREFIX.bytes" ]; then
    echo legacy_header_only; return 1
  fi
  IL_SHA="$(read_first "$SNAP_DIR/$IL_PREFIX.sha256")"
  IL_BYTES="$(read_first "$SNAP_DIR/$IL_PREFIX.bytes")"
  [ "$(db_sha "$SNAP_DIR/$IL_PREFIX.db")" = "$IL_SHA" ] &&
    [ "$(db_bytes "$SNAP_DIR/$IL_PREFIX.db")" = "$IL_BYTES" ] || { echo digest_mismatch; return 1; }
  [ "$(read_first "$SNAP_DIR/$IL_PREFIX.validation")" = sqlite_integrity_verified ] || {
    echo checksum_only; return 1;
  }
  # If a verifier is present, re-check live on disk. Otherwise require the
  # integrity attestation made when the digest was pinned (never infer it).
  if sqlite_tool >/dev/null 2>&1; then
    db_integrity "$SNAP_DIR/$IL_PREFIX.db" || { echo sqlite_integrity_failed; return 1; }
  fi
  echo sqlite_integrity_verified
}

# Explicitly offline-only. Never write over a database while Vector may have it open.
offline_restore() {
  # RETIRED: the legacy implementation removed live WAL/SHM before persisting
  # a rollback journal. All restoration must use the guarded one-shot engine.
  log ERROR 'Legacy unjournaled offline_restore retired; use one-shot-stage'
  return 1
}

# Reads the module configuration from Vector's authenticated CLI, not the live DB.
# A failed/empty CLI response must NEVER be interpreted as all modules disabled.
vector_enabled_manifest() {
  VEM_DEST="$1"
  VEM_JSON="$VEM_DEST.json.$$"
  if ! vector --json modules ls -e > "$VEM_JSON" 2>/dev/null ||
     ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$VEM_JSON"; then
    rm -f "$VEM_JSON"
    return 1
  fi
  if ! sed -n 's/.*"PACKAGE"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_.]*\)".*/\1/p' "$VEM_JSON" | grep -v '^lspd$' | LC_ALL=C sort -u > "$VEM_DEST"; then
    rm -f "$VEM_JSON" "$VEM_DEST"
    return 1
  fi
  rm -f "$VEM_JSON"
  return 0
}

# The pinned baseline cannot be silently overwritten by a boot that only looks stable.
# The observed candidate is only diagnostic until manually promoted. A completion marker
# is written LAST so interrupted candidate creation is never treated as complete.
successful_snapshot() {
  cli_ready || { log WARN 'Vector CLI unavailable; skipping observation'; return 1; }
  TMPDB="$SNAP_DIR/observed-new-$$.db"
  TMPMAN="$SNAP_DIR/observed-new-$$.enabled"
  rm -f "$SNAP_DIR/observed.complete" "$TMPDB" "$TMPMAN"
  if ! vector db backup "$TMPDB" > "$LOG_DIR/last-backup-output.log" 2>&1 ||
     ! valid_db "$TMPDB"; then
    rm -f "$TMPDB"; log ERROR 'Vector consistent candidate backup failed'; return 1
  fi
  VC="$(vector_version_code)"
  if [ -z "$VC" ] || ! vector_enabled_manifest "$TMPMAN"; then
    rm -f "$TMPDB" "$TMPMAN"
    log ERROR 'Candidate manifest or Vector version unavailable'
    return 1
  fi
  OID="$(boot_id | tr -cd 'a-fA-F0-9-')"
  [ -n "$OID" ] || { rm -f "$TMPDB" "$TMPMAN"; return 1; }
  if ! mv -f "$TMPDB" "$SNAP_DIR/observed.db" ||
     ! mv -f "$TMPMAN" "$SNAP_DIR/observed.enabled" ||
     ! write_atomic "$SNAP_DIR/observed.vector-version" "$VC" ||
     ! write_atomic "$SNAP_DIR/observed.boot-id" "$OID"; then
    log ERROR 'Candidate observation incomplete; no baseline changes made'
    return 1
  fi
  if ! attest_snapshot observed || ! write_atomic "$SNAP_DIR/observed.complete" "$OID"; then
    log ERROR 'Candidate integrity unavailable or invalid; refusing baseline changes'
    return 1
  fi
  # First installation only. For v0.4 upgrades, keep the existing baseline as-is.
  if [ ! -f "$SNAP_DIR/last-good.db" ]; then
    write_atomic "$SNAP_DIR/baseline-in-progress" "$OID" || return 1
    if ! cp "$SNAP_DIR/observed.db" "$SNAP_DIR/last-good.db" ||
       ! cp "$SNAP_DIR/observed.enabled" "$SNAP_DIR/last-good.enabled" ||
       ! write_atomic "$SNAP_DIR/last-good.vector-version" "$VC" ||
       ! write_atomic "$SNAP_DIR/last-good.boot-id" "$OID" ||
       ! cp "$SNAP_DIR/observed.sha256" "$SNAP_DIR/last-good.sha256" ||
       ! cp "$SNAP_DIR/observed.bytes" "$SNAP_DIR/last-good.bytes" ||
       ! cp "$SNAP_DIR/observed.validation" "$SNAP_DIR/last-good.validation" ||
       ! write_atomic "$SNAP_DIR/last-good.complete" "$OID"; then
      log ERROR 'Initial recovery baseline setup incomplete'
      return 1
    fi
    rm -f "$SNAP_DIR/baseline-in-progress"
    log SNAPSHOT 'Created initial pinned Vector recovery baseline'
  else
    log SNAPSHOT 'Saved current Vector observation; pinned recovery baseline preserved'
  fi
  return 0
}

# Only a user-explicit operation may change an already pinned recovery baseline.
# Capture a fresh candidate from the current daemon first, then rotate the baseline.
promote_snapshot() {
  # A v0.5 legacy baseline is intentionally not restore-qualified, but an
  # explicit promotion must still be possible to migrate away from it safely.
  if [ -e "$SNAP_DIR/baseline-in-progress" ] ||
     ! valid_db "$SNAP_DIR/last-good.db" ||
     [ ! -s "$SNAP_DIR/last-good.vector-version" ]; then
    echo 'Pinned baseline missing or an earlier promotion was interrupted' >&2; return 1
  fi
  [ "$(read_first "$BOOT_DIR/last-success-id")" = "$(boot_id)" ] || {
    echo 'Current hardware boot has not passed stability observation' >&2; return 1;
  }
  boot_complete || { echo 'Boot not complete' >&2; return 1; }
  successful_snapshot || { echo 'Cannot create a consistent candidate' >&2; return 1; }
  [ "$(read_first "$SNAP_DIR/observed.complete")" = "$(boot_id | tr -cd 'a-fA-F0-9-')" ] || return 1
  [ "$(snapshot_integrity_level observed)" = sqlite_integrity_verified ] || return 1
  # Prepare copies before touching the pinned baseline.
  cp "$SNAP_DIR/observed.db" "$SNAP_DIR/promote-new-$$.db" || return 1
  cp "$SNAP_DIR/observed.enabled" "$SNAP_DIR/promote-new-$$.enabled" || return 1
  PN="$SNAP_DIR/promote-new-$$"
  if [ -f "$SNAP_DIR/last-good.db" ]; then
    cp "$SNAP_DIR/last-good.db" "$SNAP_DIR/previous-good.db" || return 1
    for EXT in enabled vector-version boot-id sha256 bytes validation complete; do
      [ ! -f "$SNAP_DIR/last-good.$EXT" ] || cp "$SNAP_DIR/last-good.$EXT" "$SNAP_DIR/previous-good.$EXT" || return 1
    done
  fi
  # The in-progress marker FAILS CLOSED after an interrupted promotion, including
  # devices upgraded from v0.4 that had no .complete marker.
  write_atomic "$SNAP_DIR/baseline-in-progress" "$(boot_id)" || return 1
  rm -f "$SNAP_DIR/last-good.complete"
  mv -f "$PN.db" "$SNAP_DIR/last-good.db" || return 1
  mv -f "$PN.enabled" "$SNAP_DIR/last-good.enabled" || return 1
  write_atomic "$SNAP_DIR/last-good.vector-version" "$(read_first "$SNAP_DIR/observed.vector-version")" || return 1
  write_atomic "$SNAP_DIR/last-good.boot-id" "$(boot_id)" || return 1
  for EXT in sha256 bytes validation; do cp "$SNAP_DIR/observed.$EXT" "$SNAP_DIR/last-good.$EXT" || return 1; done
  write_atomic "$SNAP_DIR/last-good.complete" "$(boot_id)" || return 1
  rm -f "$SNAP_DIR/baseline-in-progress"
  log SNAPSHOT 'User promoted current consistent Vector observation to pinned recovery baseline'
  echo 'Pinned recovery baseline promoted. Previous baseline retained as previous-good.db.'
}

# Legacy backups stay untouched for auditing, but may not be armed/restored
# until explicitly promoted with a verified SQLite database.
recovery_baseline_ready() {
  [ ! -e "$SNAP_DIR/baseline-in-progress" ] || return 1
  [ "$(snapshot_integrity_level last-good)" = sqlite_integrity_verified ] || return 1
  [ -s "$SNAP_DIR/last-good.vector-version" ] || return 1
  [ -s "$SNAP_DIR/last-good.enabled" ] || return 1
  [ -s "$SNAP_DIR/last-good.complete" ] || return 1
  [ -s "$SNAP_DIR/last-good.boot-id" ] || return 1
  [ "$(read_first "$SNAP_DIR/last-good.complete")" = "$(read_first "$SNAP_DIR/last-good.boot-id")" ] || return 1
}
