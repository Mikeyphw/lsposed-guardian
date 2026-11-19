#!/system/bin/sh
# Optional manual-only Vector DB snapshots. No cron, service.d, restore or
# implicit automatic action. Original live config directory is never modified.
BV_BASE="$STATE_DIR/backup-vault"
BV_SNAPS="$BV_BASE/snapshots"
BV_LIMIT=5
bv_limit_refresh() {
  BV_LIMIT="${BACKUP_VAULT_LIMIT:-5}"
  case "$BV_LIMIT" in ''|*[!0-9]*) BV_LIMIT=5 ;; esac
  [ "$BV_LIMIT" -ge 1 ] && [ "$BV_LIMIT" -le 20 ] || BV_LIMIT=5
}
bv_init() {
  bv_limit_refresh
  for BV_PATH in "$STATE_DIR" "$BV_BASE" "$BV_SNAPS"; do
    [ ! -L "$BV_PATH" ] || return 1
    mkdir -p "$BV_PATH" && [ -d "$BV_PATH" ] || return 1
    chmod 700 "$BV_PATH" || return 1
  done
}
bv_names() {
  for BV_P in "$BV_SNAPS"/snap-*; do
    [ -d "$BV_P" ] && [ ! -L "$BV_P" ] || continue
    BV_N="${BV_P##*/}"
    case "$BV_N" in
      snap-????????_??????_??????) case "$BV_N" in *[!0-9_a-z-]*) continue ;; esac; printf '%s\n' "$BV_N" ;;
    esac
  done | LC_ALL=C sort -r
}
bv_safe_id() {
  case "$1" in snap-????????_??????_??????)
    case "$1" in *[!0-9_a-z-]*) return 1;; esac
    [ -d "$BV_SNAPS/$1" ] && [ ! -L "$BV_SNAPS/$1" ] ;; *) return 1 ;; esac
}
bv_hash_good() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -f "$2" ] && [ ! -L "$2" ] || return 1
  BV_WANT="$(read_first "$2")"
  case "$BV_WANT" in ''|*[!a-fA-F0-9]*) return 1 ;; esac
  [ "${#BV_WANT}" -eq 64 ] && [ "$(db_sha "$1")" = "$BV_WANT" ]
}
bv_verify() {
  bv_init && bv_safe_id "$1" || return 1
  BV_D="$BV_SNAPS/$1"
  [ -f "$BV_D/.complete" ] && [ ! -L "$BV_D/.complete" ] || return 1
  bv_hash_good "$BV_D/modules_config.db" "$BV_D/db.sha256" &&
    bv_hash_good "$BV_D/enabled.txt" "$BV_D/enabled.sha256" &&
    bv_hash_good "$BV_D/metadata.txt" "$BV_D/metadata.sha256" &&
    bv_hash_good "$BV_D/config.tar.gz" "$BV_D/archive.sha256" &&
    db_integrity "$BV_D/modules_config.db" || return 1
  # Bind *all* independently verified digests to one publication marker.
  BV_SEAL="$(cat "$BV_D/db.sha256" "$BV_D/enabled.sha256" \
    "$BV_D/metadata.sha256" "$BV_D/archive.sha256" | sha256sum | cut -d ' ' -f 1)"
  [ "$(read_first "$BV_D/.complete")" = "$BV_SEAL" ] || return 1
  # Archive is never extracted by Guardian; paths and links still must be safe
  # before it can be exported to a separately qualified offline recovery path.
  BV_VLIST="$BV_BASE/.verify-$$"
  [ ! -e "$BV_VLIST" ] && [ ! -L "$BV_VLIST" ] || return 1
  tar -tzf "$BV_D/config.tar.gz" > "$BV_VLIST" 2>/dev/null || {
    rm -f "$BV_VLIST"; return 1;
  }
  BV_ARC_OK=1
  while IFS= read -r BV_MEMBER; do
    case "$BV_MEMBER" in config|config/|config/*) : ;; *) BV_ARC_OK=0 ;; esac
    case "/$BV_MEMBER/" in *'/../'*|*'/./'*) BV_ARC_OK=0 ;; esac
    case "$BV_MEMBER" in *'//'*) BV_ARC_OK=0 ;; esac
  done < "$BV_VLIST"
  rm -f "$BV_VLIST"
  [ "$BV_ARC_OK" = 1 ] || return 1
  ! tar -tvzf "$BV_D/config.tar.gz" 2>/dev/null | grep -Eq '^[lh]| -> | link to '
}
bv_list() {
  bv_init || return 1
  BV_COUNT=0
  for BV_ID in $(bv_names); do
    BV_COUNT=$((BV_COUNT + 1))
    if bv_verify "$BV_ID"; then BV_LABEL=verified; else BV_LABEL=invalid; fi
    printf 'snapshot=%s status=%s\n' "$BV_ID" "$BV_LABEL"
  done
  [ "$BV_COUNT" -gt 0 ] || echo 'No manual backups found'
}
bv_status() {
  bv_limit_refresh
  echo "backup_vault_enabled=$BACKUP_VAULT_ENABLED"
  echo 'backup_vault_mode=manual_only'
  echo "backup_vault_limit=$BV_LIMIT"
  echo 'backup_vault_restore=unqualified_offline_only'
  [ -d "$BV_SNAPS" ] && echo "backup_vault_count=$(bv_names | wc -l | tr -d ' ')" || echo 'backup_vault_count=0'
  echo 'backup_vault_content=consistent_Vector_DB_plus_checked_config_files'
  echo 'backup_vault_tools=explicit_sha256_trusted_or_numbered_fallback'
  echo "backup_vault_sqlite=$({ sqlite_tool >/dev/null && echo available; } || echo unavailable)"
}
bv_prune() {
  BV_KEEP=0
  for BV_ID in $(bv_names); do
    # Keep the newest N *verified* snapshots. Invalid entries are quarantined
    # in place, not counted toward retention or silently deleted.
    bv_verify "$BV_ID" || continue
    BV_KEEP=$((BV_KEEP + 1))
    [ "$BV_KEEP" -gt "$BV_LIMIT" ] || continue
    rm -rf -- "$BV_SNAPS/$BV_ID" || return 1
  done
}
# Allow only a root operator's deliberately approved hash-pinned ARM64 static
# binary under /data/adb/modules. Arbitrary recursive discoveries are shown,
# never executed as root. A numbered terminal menu always remains available.
# Explicit opt-in tools deliberately require a path+digest. Android kernels
# may lack native shell interfaces used by optional terminal utilities.
bv_approved_tool() {
  BV_TOOL_PATH="$1" BV_TOOL_SHA="$2"
  case "$BV_TOOL_PATH" in /data/adb/modules/*) : ;; *) return 1 ;; esac
  [ -f "$BV_TOOL_PATH" ] && [ ! -L "$BV_TOOL_PATH" ] && [ -x "$BV_TOOL_PATH" ] || return 1
  case "$BV_TOOL_SHA" in *[!a-fA-F0-9]*|'') return 1 ;; esac
  [ "${#BV_TOOL_SHA}" -eq 64 ] && [ "$(db_sha "$BV_TOOL_PATH")" = "$BV_TOOL_SHA" ] || return 1
  # Static ELF header and missing PT_INTERP check (no execution on probing).
  BV_ELF="$(od -An -tx1 -N6 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' \n')"
  [ "$BV_ELF" = 7f454c460201 ] || return 1
  BV_MACHINE="$(od -An -tu2 -j18 -N2 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' ')"
  [ "$BV_MACHINE" = 183 ] || return 1
  BV_PHOFF="$(od -An -tu8 -j32 -N8 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' ')"
  BV_PHSIZE="$(od -An -tu2 -j54 -N2 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' ')"
  BV_PHNUM="$(od -An -tu2 -j56 -N2 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' ')"
  case "$BV_PHOFF:$BV_PHSIZE:$BV_PHNUM" in *[!0-9:]*|'') return 1 ;; esac
  [ "$BV_PHOFF" -ge 64 ] && [ "$BV_PHOFF" -le 10000000 ] &&
  [ "$BV_PHSIZE" -ge 56 ] && [ "$BV_PHSIZE" -le 256 ] &&
  [ "$BV_PHNUM" -ge 1 ] && [ "$BV_PHNUM" -le 128 ] || return 1
  BV_I=0
  while [ "$BV_I" -lt "$BV_PHNUM" ]; do
    BV_TYPE="$(od -An -tu4 -j "$((BV_PHOFF + BV_I * BV_PHSIZE))" -N4 "$BV_TOOL_PATH" 2>/dev/null | tr -d ' ')"
    [ "$BV_TYPE" != 3 ] && [ -n "$BV_TYPE" ] || return 1
    BV_I=$((BV_I + 1))
  done
  printf '%s\n' "$BV_TOOL_PATH"
}
bv_tools() {
  [ -d /data/adb/modules ] || { echo 'No module tools directory'; return 0; }
  for BV_TOOL in fzf bat; do
    find /data/adb/modules -type f -name "$BV_TOOL" 2>/dev/null | while IFS= read -r BV_CAND; do
      [ -x "$BV_CAND" ] && [ ! -L "$BV_CAND" ] || continue
      printf 'untrusted_candidate=%s sha256=%s (explicit approval required)\n' "$BV_CAND" "$(db_sha "$BV_CAND")"
    done
  done
}
bv_create() (
  [ "$BACKUP_VAULT_ENABLED" = 1 ] || { echo 'Backup vault disabled; use backup-enable --apply' >&2; return 1; }
  bv_init || return 1
  [ ! -L "$BV_BASE/.lock" ] || return 1
  mkdir -m 700 "$BV_BASE/.lock" 2>/dev/null || { echo 'Backup vault busy' >&2; return 1; }
  BV_STAGE=
  trap '[ -z "$BV_STAGE" ] || rm -rf -- "$BV_STAGE"; rmdir "$BV_BASE/.lock" 2>/dev/null || :' 0
  trap 'exit 130' 1 2 3 15
  boot_complete && [ "$(read_first "$BOOT_DIR/last-success-id")" = "$(boot_id)" ] || {
    echo 'A verified stable boot is required' >&2; return 1;
  }
  vc_toggle_ready || { echo 'Vector inventory contract unavailable' >&2; return 1; }
  [ -n "$(sqlite_tool)" ] || { echo 'No SQLite integrity verifier; refusing raw backup' >&2; return 1; }
  BV_SEQ="$(read_first "$BV_BASE/sequence")"
  case "$BV_SEQ" in ''|*[!0-9]*) BV_SEQ=0 ;; esac
  [ "$BV_SEQ" -lt 999999 ] || return 1
  BV_SEQ=$((BV_SEQ + 1))
  BV_ID="snap-$(date -u '+%Y%m%d_%H%M%S')_$(printf '%06d' "$BV_SEQ")"
  [ ! -e "$BV_SNAPS/$BV_ID" ] && [ ! -L "$BV_SNAPS/$BV_ID" ] || return 1
  BV_STAGE="$BV_BASE/.building-$$"
  [ ! -e "$BV_STAGE" ] && [ ! -L "$BV_STAGE" ] || return 1
  mkdir -m 700 "$BV_STAGE" || return 1
  # Vector's own SQLite backup API, not a potentially inconsistent live WAL copy.
  vector_bounded 45 db backup "$BV_STAGE/modules_config.db" >/dev/null 2>&1 || return 1
  db_integrity "$BV_STAGE/modules_config.db" || return 1
  vector_enabled_manifest "$BV_STAGE/enabled.txt" || return 1
  BV_SQL="$(sqlite_tool)" || return 1
  # Do not let a successful sort mask a failed SQLite query (POSIX sh has no
  # portable pipefail). Always verify the producer's return code directly.
  "$BV_SQL" -readonly "$BV_STAGE/modules_config.db" \
    'SELECT module_pkg_name FROM modules WHERE enabled=1 ORDER BY module_pkg_name;' \
    > "$BV_STAGE/db-enabled.raw" 2>/dev/null || return 1
  grep -v '^lspd$' "$BV_STAGE/db-enabled.raw" |
    LC_ALL=C sort -u > "$BV_STAGE/db-enabled.txt" || return 1
  cmp -s "$BV_STAGE/db-enabled.txt" "$BV_STAGE/enabled.txt" || {
    echo 'Database and CLI module states disagree; refusing snapshot' >&2; return 1;
  }
  rm -f "$BV_STAGE/db-enabled.txt" "$BV_STAGE/db-enabled.raw"
  # Capture additional regular configuration files without live DB/WAL races.
  # Reject links, special files and path components that cannot be safely
  # represented in the archive. No live database is ever copied raw.
  BV_SOURCE="${DB%/*}"
  [ -d "$BV_SOURCE" ] && [ ! -L "$BV_SOURCE" ] || return 1
  mkdir -m 700 "$BV_STAGE/config" || return 1
  cp "$BV_STAGE/modules_config.db" "$BV_STAGE/config/modules_config.db" || return 1
  BV_LIST="$BV_STAGE/source-paths.txt"
  find "$BV_SOURCE" -print > "$BV_LIST" || return 1
  BV_BYTES=0 BV_COUNT=0
  while IFS= read -r BV_ITEM; do
    [ ! -L "$BV_ITEM" ] || { echo 'Configuration symlink refused' >&2; return 1; }
    [ -d "$BV_ITEM" ] && continue
    [ -f "$BV_ITEM" ] || { echo 'Special configuration file refused' >&2; return 1; }
    BV_REL="${BV_ITEM#"$BV_SOURCE"/}"
    [ "$BV_ITEM" != "$BV_SOURCE" ] || return 1
    case "$BV_REL" in
      modules_config.db|modules_config.db-wal|modules_config.db-shm|modules_config.db-journal) continue ;;
      ''|*'..'*|*'//'*|*[!a-zA-Z0-9_./-]*) echo 'Unsafe configuration filename' >&2; return 1 ;;
    esac
    BV_COUNT=$((BV_COUNT + 1))
    [ "$BV_COUNT" -le 256 ] || return 1
    BV_SIZE="$(wc -c < "$BV_ITEM" | tr -d ' ')"
    BV_BYTES=$((BV_BYTES + BV_SIZE))
    [ "$BV_BYTES" -le 8388608 ] || { echo 'Configuration extras exceed 8 MiB safety limit' >&2; return 1; }
    # For top-level extras dirname computation is not meaningful.
    BV_PARENT="${BV_REL%/*}"
    [ "$BV_PARENT" = "$BV_REL" ] || mkdir -p "$BV_STAGE/config/$BV_PARENT" || return 1
    cp "$BV_ITEM" "$BV_STAGE/config/$BV_REL" || return 1
  done < "$BV_LIST"
  rm -f "$BV_LIST"
  tar -czf "$BV_STAGE/config.tar.gz" -C "$BV_STAGE" config || return 1
  rm -rf "$BV_STAGE/config"
  printf 'created_utc=%s\nvector_code=%s\nboot_id=%s\nmode=sqlite_online\nextras=regular_files_bounded_consistency_not_attested\n' \
    "$(stamp)" "$(vector_version_code)" "$(boot_id | tr -cd 'a-fA-F0-9-')" > "$BV_STAGE/metadata.txt" || return 1
  for BV_F in db:modules_config.db enabled:enabled.txt metadata:metadata.txt archive:config.tar.gz; do
    BV_LABEL="${BV_F%%:*}" BV_NAME="${BV_F#*:}"
    db_sha "$BV_STAGE/$BV_NAME" > "$BV_STAGE/$BV_LABEL.sha256" || return 1
  done
  cat "$BV_STAGE/db.sha256" "$BV_STAGE/enabled.sha256" \
      "$BV_STAGE/metadata.sha256" "$BV_STAGE/archive.sha256" |
    sha256sum | cut -d ' ' -f 1 > "$BV_STAGE/.complete" || return 1
  mv "$BV_STAGE" "$BV_SNAPS/$BV_ID" || return 1
  BV_STAGE=
  printf '%s\n' "$BV_SEQ" > "$BV_BASE/sequence.tmp.$$" || return 1
  mv -f "$BV_BASE/sequence.tmp.$$" "$BV_BASE/sequence" || return 1
  bv_verify "$BV_ID" || { echo 'Published snapshot failed verification' >&2; return 1; }
  BV_NEW_ID="$BV_ID"
  bv_prune || return 1
  printf 'BACKUP_PASS id=%s mode=sqlite_online\n' "$BV_NEW_ID"
)
bv_show_text() {
  BV_BAT=$(bv_approved_tool "${GUARDIAN_BACKUP_BAT:-}" "${GUARDIAN_BACKUP_BAT_SHA256:-}" 2>/dev/null) || BV_BAT=
  if [ -n "$BV_BAT" ] && [ -t 1 ]; then
    "$BV_BAT" --paging=never --style=plain -- "$1" || cat "$1"
  else cat "$1"; fi
}
bv_inspect() {
  bv_verify "$1" || { echo 'Snapshot invalid, incompatible or absent' >&2; return 1; }
  bv_show_text "$BV_SNAPS/$1/metadata.txt"
  echo 'enabled_modules:'
  bv_show_text "$BV_SNAPS/$1/enabled.txt"
  echo 'integrity=verified'
}
bv_restore_preview() {
  bv_verify "$1" || return 1
  echo "snapshot=$1"
  echo 'restore=BLOCKED_UNQUALIFIED'
  echo 'reason=Guardian does not mutate the live Vector database; hardware/offline restore is separately qualified'
  echo 'manual_export_path=private_root_snapshot'
  # --apply does not bypass the offline device recovery qualification.
  return 1
}

# A read-only comparison is useful before considering an independently
# qualified restore; it never promotes a recovery baseline.
bv_compare() {
  bv_verify "$1" && bv_verify "$2" || return 1
  echo "comparison=$1..$2"
  echo 'disabled_between_snapshots:'
  grep -Fvx -f "$BV_SNAPS/$2/enabled.txt" "$BV_SNAPS/$1/enabled.txt" || :
  echo 'enabled_between_snapshots:'
  grep -Fvx -f "$BV_SNAPS/$1/enabled.txt" "$BV_SNAPS/$2/enabled.txt" || :
  echo "database_same=$([ "$(db_sha "$BV_SNAPS/$1/modules_config.db")" = "$(db_sha "$BV_SNAPS/$2/modules_config.db")" ] && echo yes || echo no)"
}
bv_show_modules() {
  bv_verify "$1" || return 1
  cat "$BV_SNAPS/$1/enabled.txt"
}
bv_menu() {
  bv_init || return 1
  BV_FZF=$(bv_approved_tool "${GUARDIAN_BACKUP_FZF:-}" "${GUARDIAN_BACKUP_FZF_SHA256:-}" 2>/dev/null) || BV_FZF=
  while :; do
    if [ -n "$BV_FZF" ] && [ -t 0 ] && [ -t 1 ]; then
      BV_CHOICE="$(printf '%s\n' '1 Create snapshot' '2 List snapshots' '3 Inspect snapshot' '4 Compare snapshots' '5 Verify snapshot' '6 Show enabled modules' '7 Backup status' '8 Discover tools (not execute)' '0 Exit' | "$BV_FZF" --reverse --prompt='Guardian backups > ')" || return 0
      BV_CHOICE="${BV_CHOICE%% *}"
    else
      printf '%s\n' 'Guardian backup vault (manual only)' '1) Create snapshot' '2) List snapshots' '3) Inspect snapshot' '4) Compare snapshots' '5) Verify snapshot' '6) Show enabled modules' '7) Backup status' '8) Discover optional static tools' '0) Exit'
      printf 'Choice: '; IFS= read -r BV_CHOICE || return 0
    fi
    case "$BV_CHOICE" in
      1) bv_create || echo 'Snapshot creation refused or failed' >&2 ;;
      2) bv_list ;;
      3|5|6)
        printf 'Snapshot ID: '; IFS= read -r BV_CHOICE_ID || return 0
        case "$BV_CHOICE" in 3) bv_inspect "$BV_CHOICE_ID" ;; 5) bv_verify "$BV_CHOICE_ID" && echo 'Verified' ;; 6) bv_show_modules "$BV_CHOICE_ID" ;; esac ;;
      4) printf 'First snapshot ID: '; IFS= read -r BV_A || return 0
         printf 'Second snapshot ID: '; IFS= read -r BV_B || return 0
         bv_compare "$BV_A" "$BV_B" ;;
      7) bv_status ;;
      8) bv_tools ;;
      0) return 0 ;;
      *) echo 'Invalid selection' >&2 ;;
    esac
  done
}
