#!/system/bin/sh
# Root-only, bounded, read-only Android crash-event capture. No stack traces retained.
CRASH_DIR="$STATE_DIR/crashes"
CRASH_FILE="$CRASH_DIR/events.tsv"
CRASH_MAX_EVENTS=400
CRASH_CONTINUITY="$CRASH_DIR/continuity.tsv"
MON_DIR="$STATE_DIR/monitor"

crash_init() {
  mkdir -p "$CRASH_DIR" || return 1
  chmod 700 "$CRASH_DIR" 2>/dev/null || :
  [ -f "$CRASH_FILE" ] || : > "$CRASH_FILE"
  chmod 600 "$CRASH_FILE" 2>/dev/null || :
}

# A separate parser can be tested with synthetic input in an isolated directory.
# This accepts only AndroidRuntime Process lines with Android epoch timestamps.
crash_parse_file() {
  CP_RAW="$1" CP_OUT="$2" CP_BOOT="$3"
  case "$CP_BOOT" in ''|*[!a-fA-F0-9-]*) return 1 ;; esac
  awk -v id="$CP_BOOT" '
    $1 ~ /^[0-9][0-9]*\.[0-9][0-9]*$/ && index($0, "AndroidRuntime") {
      start = index($0, "Process: ")
      if (!start) next
      tail = substr($0, start + 9)
      n = split(tail, x, ", PID: ")
      if (n < 2) next
      pkg = x[1]
      pid = x[2]
      sub(/[[:space:]].*$/, "", pid)
      if (pkg !~ /^[a-zA-Z_][a-zA-Z0-9_.:]*$/ || pid !~ /^[0-9][0-9]*$/) next
      split($1, epoch_parts, ".")
      if (epoch_parts[1] + 0 < 1500000000) next
      print id "\t" epoch_parts[1] "\t" pkg "\t" pid
    }
  ' "$CP_RAW" > "$CP_OUT"
}

# Durable root-only metadata for future retention investigations. Pre-v0.9.5
# reductions cannot be explained retroactively. A receipt records an observed
# change, NOT its cause. The crash-event file remains the source of truth.
crash_continuity_record() {
  CC_KIND="$1" CC_BEFORE="$2" CC_OLDHASH="$3"
  CC_AFTER="$(crash_count_all)"
  CC_NEWHASH="$(db_sha "$CRASH_FILE")"
  [ -n "$CC_NEWHASH" ] || return 1
  [ "$CC_KIND" = BOOT ] || [ "$CC_OLDHASH" != "$CC_NEWHASH" ] || return 0
  CC_EPOCH="$(date +%s)"
  CC_BOOT="$(boot_id | tr -cd 'a-fA-F0-9-')"
  # All fields are fixed labels or numeric/digest values; no process identities.
  case "$CC_KIND" in MERGE|TRIM_OR_DEDUP|REBUILD|BOOT|UNTRACKED_AT_BOOT) : ;; *) return 1 ;; esac
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
     "$CC_EPOCH" "$CC_BOOT" "$CC_KIND" "$CC_BEFORE" "$CC_AFTER" \
     "$CC_OLDHASH" "$CC_NEWHASH" >> "$CRASH_CONTINUITY"; then
    return 1
  fi
  chmod 600 "$CRASH_CONTINUITY" 2>/dev/null || :
}

crash_continuity_boot() {
  [ -f "$CRASH_FILE" ] || return 0
  CC_PRIOR_COUNT="$(crash_count_all)"
  CC_PRIOR_HASH="$(db_sha "$CRASH_FILE")"
  CC_BOOT_KIND=BOOT
  if [ -s "$CRASH_CONTINUITY" ]; then
    CC_LAST_COUNT="$(tail -n 1 "$CRASH_CONTINUITY" | awk -F '\t' '{print $5}')"
    CC_LAST_HASH="$(tail -n 1 "$CRASH_CONTINUITY" | awk -F '\t' '{print $7}')"
    case "$CC_LAST_COUNT" in ''|*[!0-9]*) CC_LAST_COUNT=unknown ;; esac
    if [ "$CC_LAST_HASH" != "$CC_PRIOR_HASH" ]; then
      # Changed since last recorded checkpoint: flag, never invent a cause.
      CC_BOOT_KIND=UNTRACKED_AT_BOOT
      CC_PRIOR_COUNT="$CC_LAST_COUNT"
      CC_PRIOR_HASH="$CC_LAST_HASH"
    fi
  fi
  crash_continuity_record "$CC_BOOT_KIND" "$CC_PRIOR_COUNT" "$CC_PRIOR_HASH"
}

# This is the only history mutation: bounded, deduplicated atomic replace.
crash_merge_file() {
  CM_NEW="$1"
  CM_JOIN="$CRASH_DIR/join-$$.tsv"
  CM_UNIQUE="$CRASH_DIR/unique-$$.tsv"
  CM_SORTED="$CRASH_DIR/sorted-$$.tsv"
  CM_TMP="$CRASH_DIR/merge-$$.tsv"
  CM_BEFORE="$(crash_count_all)"
  CM_BEFORE_HASH="$(db_sha "$CRASH_FILE")"
  # Check every step separately: POSIX sh has no pipefail. Failed reads/writes
  # must NEVER replace existing crash evidence with partial or empty content.
  if ! cat "$CRASH_FILE" "$CM_NEW" > "$CM_JOIN" ||
     ! sort -u "$CM_JOIN" > "$CM_UNIQUE" ||
     ! sort -t "$(printf '\t')" -k2,2n "$CM_UNIQUE" > "$CM_SORTED" ||
     ! tail -n "$CRASH_MAX_EVENTS" "$CM_SORTED" > "$CM_TMP" ||
     ! mv -f "$CM_TMP" "$CRASH_FILE"; then
    rm -f "$CM_JOIN" "$CM_UNIQUE" "$CM_SORTED" "$CM_TMP"
    return 1
  fi
  chmod 600 "$CRASH_FILE" 2>/dev/null || :
  rm -f "$CM_JOIN" "$CM_UNIQUE" "$CM_SORTED"
  CM_AFTER="$(crash_count_all)"
  CM_KIND=MERGE
  [ "$CM_AFTER" -ge "$CM_BEFORE" ] || CM_KIND=TRIM_OR_DEDUP
  if ! crash_continuity_record "$CM_KIND" "$CM_BEFORE" "$CM_BEFORE_HASH"; then
    log WARN 'Crash continuity metadata unavailable; no continuity claim'
  fi
  return 0
}

# Error codes here are intentionally fixed labels: never retain raw logcat stderr,
# APK names, arbitrary paths, or stack traces as collector diagnostic metadata.
crash_collect() {
  CR_CAPTURE_REASON=unknown
  crash_init || { CR_CAPTURE_REASON=state-unavailable; return 1; }
  command -v logcat >/dev/null 2>&1 || { CR_CAPTURE_REASON=logcat-missing; return 1; }
  CR_LOCK="$CRASH_DIR/collect.lock"
  if ! mkdir "$CR_LOCK" 2>/dev/null; then
    CR_CAPTURE_REASON=collector-busy
    return 2
  fi
  CR_TEMP="$CRASH_DIR/new-$$.tsv"
  CR_RAW="${GUARDIAN_CRASH_TMPDIR:-/dev}/lsposed-guardian-raw-$$.log"
  CR_BOOT_ID="$(boot_id | tr -cd 'a-fA-F0-9-')"
  if [ -z "$CR_BOOT_ID" ]; then
    CR_CAPTURE_REASON=boot-id-unavailable
    rmdir "$CR_LOCK" 2>/dev/null || :
    return 1
  fi
  if ! logcat -b crash -d -v epoch -t 1500 > "$CR_RAW" 2>/dev/null; then
    CR_CAPTURE_REASON=logcat-failed
    rm -f "$CR_RAW"
    rmdir "$CR_LOCK" 2>/dev/null || :
    return 1
  fi
  if ! crash_parse_file "$CR_RAW" "$CR_TEMP" "$CR_BOOT_ID"; then
    CR_CAPTURE_REASON=parse-failed
    rm -f "$CR_RAW" "$CR_TEMP"
    rmdir "$CR_LOCK" 2>/dev/null || :
    return 1
  fi
  rm -f "$CR_RAW"
  if crash_merge_file "$CR_TEMP"; then
    CR_RESULT=0
    CR_CAPTURE_REASON=ok
  else
    CR_RESULT=1
    CR_CAPTURE_REASON=history-merge-failed
  fi
  rm -f "$CR_TEMP"
  rmdir "$CR_LOCK" 2>/dev/null || :
  return "$CR_RESULT"
}

# Collector health is a current-boot observation, not proof the daemon is still alive.
monitor_recent_poll() {
  [ "$(read_first "$MON_DIR/last-boot")" = "$(boot_id)" ] || return 1
  [ "$(read_first "$MON_DIR/last-result")" = 'ok' ] || return 1
  MP_AT="$(read_first "$MON_DIR/last-epoch")"
  is_number "$MP_AT" || return 1
  MP_NOW="$(date +%s)"
  is_number "$MP_NOW" || return 1
  MP_AGE=$((MP_NOW - MP_AT))
  [ "$MP_AGE" -ge 0 ] && [ "$MP_AGE" -le $((CRASH_POLL_SECONDS * 2 + 20)) ]
}

crash_show() {
  crash_collect || echo 'Crash sampler unavailable; showing saved history only' >&2
  echo 'Guardian crash history (process, PID, epoch seconds; no hook causality implied):'
  if [ ! -s "$CRASH_FILE" ]; then
    echo '  No captured crash records'
    return 0
  fi
  awk -F '\t' '{printf "  %s  %s  PID=%s  boot=%s\n", $2, $3, $4, $1}' "$CRASH_FILE" | tail -n 30
}

crash_count_recent() {
  CR_COUNT_PKG="$1"
  CR_NOW="$(date +%s)"
  awk -F '\t' -v pkg="$CR_COUNT_PKG" -v now="$CR_NOW" -v window="$CRASH_WINDOW_SECONDS" '
    ($3 == pkg || index($3, pkg ":") == 1) && ($2 + 0 >= now - window) && ($2 + 0 <= now + 10) { n++ }
    END { print n + 0 }
  ' "$CRASH_FILE"
}

crash_count_all() {
  if [ -f "$CRASH_FILE" ]; then awk 'END {print NR+0}' "$CRASH_FILE"; else echo 0; fi
}

# The saved history contains only boot id, epoch, process, PID. Grouping a process
# is not attribution: a scoped Xposed module can be innocent or not loaded.
crash_triage() {
  echo 'Stored crash summary (all retained boots; not proof of Xposed causality):'
  if [ ! -s "$CRASH_FILE" ]; then
    echo '  No captured crash records'
    return 0
  fi
  awk -F '\t' '
    NF == 4 && $2 ~ /^[0-9]+$/ && $3 ~ /^[A-Za-z_][A-Za-z0-9_.:]*$/ && $4 ~ /^[0-9]+$/ {
      key=$3
      count[key]++
      if (last[key] < $2 + 0) last[key] = $2 + 0
      boot[$1]++
    }
    END {
      for (p in count) printf "%d\t%s\t%.0f\n", count[p], p, last[p]
    }
  ' "$CRASH_FILE" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n 30 |
    while IFS="$(printf '\t')" read -r hits proc last; do
      printf '  count=%s process=%s latest_epoch=%s\n' "$hits" "$proc" "$last"
    done
  echo 'For per-process scope candidates, use: guardian.sh correlate PACKAGE'
  echo 'For individual stored records, use: guardian.sh events'
}

# Current retained-event audit. An earlier count is not reconstructed from newer
# data: collection is bounded but must not claim an unexplained drop was trim.
crash_audit() {
  echo 'GUARDIAN CRASH HISTORY RETENTION AUDIT (read-only)'
  echo 'historical_counts_from_prior_reports=NOT_INFERRED'
  echo "retention_limit=$CRASH_MAX_EVENTS"
  if [ ! -f "$CRASH_FILE" ]; then
    echo 'history_state=MISSING'
    echo 'retained_events=0'
    echo 'retention_delta=UNKNOWN'
    return 0
  fi
  echo 'history_state=PRESENT'
  echo "retained_events=$(crash_count_all)"
  echo "history_sha256=$(db_sha "$CRASH_FILE")"
  echo "history_bytes=$(db_bytes "$CRASH_FILE")"
  echo "history_owner=$(stat -c '%u:%g' "$CRASH_FILE" 2>/dev/null || echo unknown)"
  echo "history_mode=$(stat -c '%a' "$CRASH_FILE" 2>/dev/null || echo unknown)"
  if [ -s "$CRASH_CONTINUITY" ]; then
    echo "continuity_records=$(wc -l < "$CRASH_CONTINUITY" | tr -d ' ')"
    echo "continuity_last_record=$(tail -n 1 "$CRASH_CONTINUITY")"
    LAST_HASH="$(tail -n 1 "$CRASH_CONTINUITY" | awk -F '\t' '{print $7}')"
    if [ "$LAST_HASH" = "$(db_sha "$CRASH_FILE")" ]; then
      echo 'continuity_current_digest=ATTESTED'
    else
      echo 'continuity_current_digest=UNTRACKED_CHANGE'
    fi
    echo "continuity_untracked_boot_changes=$(grep -c 'UNTRACKED_AT_BOOT' "$CRASH_CONTINUITY" 2>/dev/null || :)"
    echo 'retention_delta=TRACKED_FROM_FIRST_V095_RECEIPT_ONLY'
  else
    echo 'continuity_current_digest=NO_RECEIPT'
    echo 'retention_delta=UNKNOWN_WITHOUT_PRIOR_FILE_OR_TRIM_RECEIPT'
  fi
  echo 'automatic_quarantine=DISABLED'
}
