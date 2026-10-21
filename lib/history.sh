#!/system/bin/sh
# Bounded, root-private, READ-ONLY Vector configuration observations.
# Every checkpoint is an observation at sample time, never a historical assertion.
HIST_DIR="$STATE_DIR/history"
HIST_CHECKPOINTS="$HIST_DIR/checkpoints"
HIST_INDEX="$HIST_DIR/samples.tsv"
HISTORY_MAX_SAMPLES=512

history_init() {
  mkdir -p "$HIST_CHECKPOINTS" || return 1
  chmod 700 "$HIST_DIR" "$HIST_CHECKPOINTS" 2>/dev/null || :
  [ -f "$HIST_INDEX" ] || : > "$HIST_INDEX" || return 1
  chmod 600 "$HIST_INDEX" 2>/dev/null || :
}

history_scope_rows() {
  # Vector emits pretty JSON. Parse the limited two-field scope objects, fail
  # closed on missing or malformed fields. Never use eval or parse CLI stderr.
  awk '
    /"APP_PACKAGE"[[:space:]]*:/ {
      n=split($0, a, "\""); p=a[4]
      if(n < 4 || p !~ /^[a-zA-Z_][a-zA-Z0-9_.:]*$/) {bad=1;next}
      app=p
    }
    /"USER_ID"[[:space:]]*:/ {
      x=$0; sub(/^.*"USER_ID"[[:space:]]*:[[:space:]]*/, "", x)
      sub(/[ ,}].*$/, "", x)
      if(x !~ /^[0-9]+$/) {bad=1;next}
      uid=x
    }
    /}/ {
      if (app != "" && uid != "") { print app "\t" uid; app="";uid="" }
    }
    END { if (bad || app != "" || uid != "") exit 1 }
  ' "$1"
}

history_unlock() { rmdir "$HIST_DIR/.lock" 2>/dev/null || :; }

history_capture() {
  history_init || return 1
  [ ! -d "$STATE_DIR/quarantine/.lock" ] || { echo 'history_sampling_deferred=quarantine_active' >&2; return 2; }
  mkdir "$HIST_DIR/.lock" 2>/dev/null || { echo 'history_sampling_deferred=busy' >&2; return 2; }
  HC_BOOT="$(boot_id | tr -cd 'a-fA-F0-9-')"
  HC_EPOCH="$(date +%s)"
  if [ -z "$HC_BOOT" ] || ! is_number "$HC_EPOCH" || ! boot_complete; then
    history_unlock; return 1
  fi
  HC_BASE="$HIST_DIR/capture-$$"
  HC_ENABLED="$HC_BASE.enabled"
  HC_RAW="$HC_BASE.raw"
  HC_SCOPE="$HC_BASE.scope"
  HC_SORTED="$HC_BASE.sorted"
  HC_IDX="$HC_BASE.index"
  HC_TRIM="$HC_BASE.trim"
  if ! vector_enabled_manifest "$HC_ENABLED"; then
    history_unlock; return 1
  fi
  : > "$HC_RAW" || { rm -f "$HC_ENABLED"; history_unlock; return 1; }
  HC_FAILED=0
  while IFS= read -r HC_MOD; do
    [ -n "$HC_MOD" ] || continue
    case "$HC_MOD" in *[!a-zA-Z0-9_.]*|''|*..*) HC_FAILED=1; break ;; esac
    printf 'M\t%s\n' "$HC_MOD" >> "$HC_RAW" || { HC_FAILED=1; break; }
    if ! vector --json scope ls "$HC_MOD" > "$HC_SCOPE" 2>/dev/null ||
       ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$HC_SCOPE" ||
       ! history_scope_rows "$HC_SCOPE" > "$HC_BASE.rows"; then
      HC_FAILED=1; break
    fi
    while IFS="$(printf '\t')" read -r HC_TARGET HC_USER; do
      [ -n "$HC_TARGET" ] || continue
      printf 'S\t%s\t%s\t%s\n' "$HC_MOD" "$HC_TARGET" "$HC_USER" >> "$HC_RAW" || { HC_FAILED=1; break; }
    done < "$HC_BASE.rows"
    [ "$HC_FAILED" -eq 0 ] || break
  done < "$HC_ENABLED"
  if [ "$HC_FAILED" -ne 0 ] || ! LC_ALL=C sort -u "$HC_RAW" > "$HC_SORTED"; then
    rm -f "$HC_BASE".*; history_unlock; return 1
  fi
  HC_SHA="$(db_sha "$HC_SORTED")"
  case "$HC_SHA" in ''|*[!a-fA-F0-9]*) rm -f "$HC_BASE".*; history_unlock; return 1 ;; esac
  HC_FILE="$HC_BOOT-$HC_EPOCH-$$.tsv"
  HC_COUNT_M="$(awk -F '\t' '$1=="M"{n++} END{print n+0}' "$HC_SORTED")"
  HC_COUNT_S="$(awk -F '\t' '$1=="S"{n++} END{print n+0}' "$HC_SORTED")"
  if ! mv "$HC_SORTED" "$HIST_CHECKPOINTS/$HC_FILE" ||
     ! { cat "$HIST_INDEX"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$HC_BOOT" "$HC_EPOCH" "$HC_FILE" "$HC_SHA" "$HC_COUNT_M" "$HC_COUNT_S"; } > "$HC_IDX" ||
     ! tail -n "$HISTORY_MAX_SAMPLES" "$HC_IDX" > "$HC_TRIM" ||
     ! mv "$HC_TRIM" "$HIST_INDEX"; then
    rm -f "$HC_BASE".*; history_unlock; return 1
  fi
  chmod 600 "$HIST_CHECKPOINTS/$HC_FILE" "$HIST_INDEX" 2>/dev/null || :
  # Remove orphaned/aged samples after the committed index is in place.
  for HC_OLD in "$HIST_CHECKPOINTS"/*.tsv; do
    [ -f "$HC_OLD" ] || continue
    HC_NAME="${HC_OLD##*/}"
    awk -F '\t' -v name="$HC_NAME" '$3==name{found=1} END{exit !found}' "$HIST_INDEX" || rm -f "$HC_OLD"
  done
  rm -f "$HC_BASE".*
  history_unlock
  return 0
}

history_recent() {
  history_init || return 1
  echo 'Historical Vector observations (timestamps are sampling times, not change times):'
  if [ ! -s "$HIST_INDEX" ]; then echo '  No recorded checkpoints'; return 0; fi
  tail -n 12 "$HIST_INDEX" | awk -F '\t' 'NF==6 {printf "  boot=%s sampled_epoch=%s enabled=%s scoped_rows=%s sha256=%s\n",$1,$2,$5,$6,$4}'
}

history_sample_for_event() {
  # Only use an observation from the SAME boot, captured BEFORE a crash, within
  # a bounded interval. A current scope is never imputed to historical crashes.
  HE_BOOT="$1" HE_AT="$2"
  awk -F '\t' -v b="$HE_BOOT" -v t="$HE_AT" -v max="$HISTORY_MAX_AGE_SECONDS" '
    NF==6 && $1==b && $2 ~ /^[0-9]+$/ && $2+0<=t+0 && t+0-$2+0<=max+0 && $2+0>=best {
      best=$2+0; file=$3; digest=$4
    }
    END {if(file!="") print file " " digest}
  ' "$HIST_INDEX"
}

history_decision() {
  HD_TARGET="$1"
  case ",$CRASH_EXCLUDE_PACKAGES," in
    *,"$HD_TARGET",*) echo 'decision=EXCLUDED_BY_USER'; echo 'automatic_action=disabled'; return 0 ;;
  esac
  history_init || return 1
  HD_BASE="$HIST_DIR/decision-$$"
  HD_EVENTS="$HD_BASE.events"
  HD_NOW="$(date +%s)"
  [ -s "$CRASH_FILE" ] || { echo 'decision=INSUFFICIENT_CRASH_EVIDENCE'; echo 'automatic_action=disabled'; return 0; }
  awk -F '\t' -v p="$HD_TARGET" -v now="$HD_NOW" -v window="$CRASH_WINDOW_SECONDS" '
    NF==4 && ($3==p || index($3,p ":")==1) && $2+0 >= now-window && $2+0 <= now+10 {print $1 "\t" $2 "\t" $4}
  ' "$CRASH_FILE" > "$HD_EVENTS" || return 1
  HD_COUNT="$(wc -l < "$HD_EVENTS" | tr -d ' ')"
  printf 'recent_crash_count=%s\n' "$HD_COUNT"
  if [ "$HD_COUNT" -lt 3 ]; then
    echo 'decision=INSUFFICIENT_CRASH_EVIDENCE'; echo 'automatic_action=disabled'
    rm -f "$HD_EVENTS"; return 0
  fi
  HD_UNIQUE_PIDS="$(cut -f3 "$HD_EVENTS" | sort -u | wc -l | tr -d ' ')"
  if [ "$HD_UNIQUE_PIDS" -lt 2 ]; then
    echo 'decision=INSUFFICIENT_DISTINCT_PROCESSES'; echo 'automatic_action=disabled'
    rm -f "$HD_EVENTS"; return 0
  fi
  HD_RESULT=REVIEW_SINGLE_SCOPED_MODULE
  HD_CANDIDATE=''
  HD_SCOPED="$HD_BASE.candidates"
  HD_NORMAL_TARGET="$HD_TARGET"
  [ "$HD_TARGET" != system_server ] || HD_NORMAL_TARGET=system
  while IFS="$(printf '\t')" read -r HD_BOOT HD_EPOCH HD_PID; do
    HD_REF="$(history_sample_for_event "$HD_BOOT" "$HD_EPOCH")"
    [ -n "$HD_REF" ] || { HD_RESULT=HISTORICAL_COVERAGE_MISSING; break; }
    HD_FILE="${HD_REF%% *}" HD_HASH="${HD_REF#* }"
    case "$HD_FILE" in *[!a-zA-Z0-9_.-]*|''|*..*) HD_RESULT=HISTORICAL_CHECKPOINT_INVALID; break ;; esac
    HD_PATH="$HIST_CHECKPOINTS/$HD_FILE"
    if [ ! -f "$HD_PATH" ] || [ "$(db_sha "$HD_PATH")" != "$HD_HASH" ]; then
      HD_RESULT=HISTORICAL_CHECKPOINT_INVALID; break
    fi
    awk -F '\t' -v p="$HD_NORMAL_TARGET" '
      $1=="M" {on[$2]=1}
      $1=="S" && $3==p {scope[$2]=1}
      END {for(m in on) if(scope[m]) print m}
    ' "$HD_PATH" | LC_ALL=C sort -u > "$HD_SCOPED" || { HD_RESULT=HISTORICAL_CHECKPOINT_INVALID; break; }
    HD_N="$(wc -l < "$HD_SCOPED" | tr -d ' ')"
    if [ "$HD_N" -eq 0 ]; then HD_RESULT=NO_EXPLICIT_SCOPED_CANDIDATES; break; fi
    if [ "$HD_N" -ne 1 ]; then HD_RESULT=MULTIPLE_SCOPED_CANDIDATES; break; fi
    HD_ONE="$(head -n 1 "$HD_SCOPED")"
    if [ -n "$HD_CANDIDATE" ] && [ "$HD_CANDIDATE" != "$HD_ONE" ]; then
      HD_RESULT=INCONSISTENT_HISTORICAL_CANDIDATES; break
    fi
    HD_CANDIDATE="$HD_ONE"
  done < "$HD_EVENTS"
  if [ "$HD_RESULT" = REVIEW_SINGLE_SCOPED_MODULE ]; then
    # Compare with current config. Never assume historical modules remain enabled.
    if ! vector_enabled_manifest "$HD_BASE.current"; then
      HD_RESULT=CURRENT_VECTOR_STATE_UNAVAILABLE
    elif ! grep -Fxq "$HD_CANDIDATE" "$HD_BASE.current"; then
      HD_RESULT=CONFIGURATION_CHANGED_SINCE_CRASH
    elif ! vector --json scope ls "$HD_CANDIDATE" > "$HD_BASE.scope" 2>/dev/null ||
         ! grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$HD_BASE.scope" ||
         ! history_scope_rows "$HD_BASE.scope" > "$HD_BASE.current-scope"; then
      HD_RESULT=CURRENT_VECTOR_STATE_UNAVAILABLE
    elif ! cut -f1 "$HD_BASE.current-scope" | grep -Fxq "$HD_NORMAL_TARGET"; then
      HD_RESULT=CONFIGURATION_CHANGED_SINCE_CRASH
    fi
  fi
  printf 'decision=%s\n' "$HD_RESULT"
  if [ "$HD_RESULT" = REVIEW_SINGLE_SCOPED_MODULE ]; then
    printf 'candidate_for_manual_review=%s\n' "$HD_CANDIDATE"
    echo 'causality=NOT_ESTABLISHED'
  fi
  echo 'automatic_action=disabled'
  echo 'note=Scope presence is not proof of hook injection or crash causality'
  rm -f "$HD_BASE".*
}

# Health reflects the most recent completed sampler iteration in this boot.
history_recent_poll() {
  [ "$(read_first "$HIST_DIR/last-boot")" = "$(boot_id)" ] || return 1
  [ "$(read_first "$HIST_DIR/last-result")" = ok ] || return 1
  HR_AT="$(read_first "$HIST_DIR/last-epoch")"
  is_number "$HR_AT" || return 1
  HR_NOW="$(date +%s)"
  is_number "$HR_NOW" || return 1
  HR_AGE=$((HR_NOW - HR_AT))
  [ "$HR_AGE" -ge 0 ] && [ "$HR_AGE" -le $((HISTORY_POLL_SECONDS * 2 + 20)) ]
}
history_health() {
  printf 'history_recent_poll=%s\n' "$({ history_recent_poll && echo yes; } || echo no)"
  printf 'history_last_poll_boot=%s\n' "$(read_first "$HIST_DIR/last-boot")"
  printf 'history_last_poll_epoch=%s\n' "$(read_first "$HIST_DIR/last-epoch")"
  printf 'history_last_poll_result=%s\n' "$(read_first "$HIST_DIR/last-result")"
  printf 'history_last_error_epoch=%s\n' "$(read_first "$HIST_DIR/last-error-epoch")"
  echo 'note=Historical timestamps are observations, not module activation times'
}
