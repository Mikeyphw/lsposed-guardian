#!/system/bin/sh
# Post-boot TYPE_BOOT_PROGRESS softlock watch. Never use keyguard locked state,
# unlock status, or a missing HOME activity as automatic recovery evidence.
SL_DIR="$STATE_DIR/softlock"
sl_record() {
  SL_DECISION="$1" SL_REASON="$2"
  mkdir -p "$SL_DIR" || return 1
  chmod 700 "$SL_DIR" 2>/dev/null || :
  SL_ID="$(boot_id | tr -cd 'a-fA-F0-9-')"
  [ -n "$SL_ID" ] || return 1
  write_atomic "$SL_DIR/boot-id" "$SL_ID" || return 1
  write_atomic "$SL_DIR/decision" "$SL_DECISION" || return 1
  write_atomic "$SL_DIR/reason" "$SL_REASON" || return 1
  write_atomic "$SL_DIR/epoch" "$(date +%s)" || return 1
  if [ "$SL_DECISION" != observing ]; then
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$SL_ID" "$SL_DECISION" "$SL_REASON" >> "$SL_DIR/events.tsv" || :
    # Only compact receipt metadata is retained; no original dumpsys output.
    SL_EVENTS_TMP="$SL_DIR/events-compact.$$"
    tail -n 256 "$SL_DIR/events.tsv" > "$SL_EVENTS_TMP" 2>/dev/null && mv -f "$SL_EVENTS_TMP" "$SL_DIR/events.tsv" || rm -f "$SL_EVENTS_TMP"
  fi
}
sl_status() {
  echo "softlock_enabled=$AUTO_SOFTLOCK"
  echo "softlock_monitor=$SOFTLOCK_MONITOR"
  echo "softlock_grace_seconds=$SOFTLOCK_GRACE_SECONDS"
  SL_LAST="$(read_first "$SL_DIR/boot-id")"
  if [ "$SL_LAST" = "$(boot_id)" ]; then
    echo "softlock_decision=$(read_first "$SL_DIR/decision")"
    echo "softlock_reason=$(read_first "$SL_DIR/reason")"
  else
    echo 'softlock_decision=not_observed_this_boot'
    echo 'softlock_reason=no_current_boot_receipt'
  fi
  echo "softlock_last_epoch=$(read_first "$SL_DIR/epoch")"
  echo "softlock_last_boot=$SL_LAST"
  echo "softlock_recovery_attempt=$(read_first "$SL_DIR/recovery-attempt")"
}
# Exit status 0: progress window is present and explicitly visible.
# Exit status 1: no boot-progress window is reported.
# Exit status 2: visibility/reporting unavailable; NEVER infer a healthy UI.
sl_probe() {
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 2
  command -v dumpsys >/dev/null 2>&1 || return 2
  if command -v timeout >/dev/null 2>&1; then SL_TIMEOUT=timeout
  elif command -v toybox >/dev/null 2>&1 && toybox timeout 1 true >/dev/null 2>&1; then SL_TIMEOUT='toybox timeout'
  else return 2
  fi
  SL_TMP="$SL_DIR/dumpsys.$$"
  mkdir -p "$SL_DIR" || return 2
  chmod 700 "$SL_DIR" 2>/dev/null || :
  # Timeout bounds a hung binder call; never store the original dump persistently.
  if ! $SL_TIMEOUT 8 dumpsys window windows > "$SL_TMP" 2>/dev/null; then
    rm -f "$SL_TMP"; return 2
  fi
  [ -s "$SL_TMP" ] || { rm -f "$SL_TMP"; return 2; }
  # A boot-progress *WindowState* is needed; bare text in policy or grep hits
  # are insufficient. A candidate without explicit visible status is UNKNOWN.
  SL_RESULT="$(awk '
    function close_window() {
      if (active && progress && visible) seen=1
      if (active && progress && !visible) uncertain=1
    }
    /^[[:space:]]*Window #[0-9]+ Window\{/ {
      close_window(); active=1; windows++; progress=0; visible=0; lines=0
    }
    active && lines++ < 65 {
      if ($0 ~ /(mAttrs=|Attrs:|LayoutParams)/ && $0 ~ /(^|[[:space:],{])(ty|type)=(2021|TYPE_BOOT_PROGRESS)([[:space:],}]|$)/) progress=1
      if ($0 ~ /isOnScreen=true|isVisible=true/) visible=1
    }
    END {close_window(); if(seen) print "visible"; else if(uncertain || !windows) print "unverified"; else print "absent"}
  ' "$SL_TMP")"
  rm -f "$SL_TMP"
  case "$SL_RESULT" in visible) return 0;; absent) return 1;; *) return 2;; esac
}
# A confirmed softlock requires sustained, current-boot evidence and cannot
# be claimed from one snapshot. If the probe never verifies the dialog, report
# unverified rather than an imaginary clean result.
sl_observe() {
  [ "$SOFTLOCK_MONITOR" = 1 ] || { sl_record disabled monitor_disabled; return 0; }
  SL_SPENT=0 SL_FIRST=-1 SL_HITS=0 SL_ABSENT=0 SL_UNKNOWN=0
  sl_record observing observation_started || :
  while [ "$SL_SPENT" -le "$SOFTLOCK_GRACE_SECONDS" ]; do
    if ! boot_complete || [ "$(read_first "$BOOT_DIR/pending-id")" != "$(boot_id)" ]; then
      sl_record unverified boot_identity_changed || :; return 3
    fi
    if sl_probe; then
      SL_HITS=$((SL_HITS + 1)); SL_ABSENT=0
      [ "$SL_FIRST" -ge 0 ] || SL_FIRST="$SL_SPENT"
      if [ "$SL_HITS" -ge 4 ] && [ "$((SL_SPENT - SL_FIRST))" -ge "$SOFTLOCK_GRACE_SECONDS" ]; then
        sl_record confirmed persistent_visible_boot_progress || :
        log WARN 'Persistent visible boot progress detected; boot deliberately not marked healthy'
        return 2
      fi
    else
      SL_PROBE_RESULT=$?
      if [ "$SL_PROBE_RESULT" -eq 1 ]; then
        SL_ABSENT=$((SL_ABSENT + 1))
        SL_HITS=0 SL_FIRST=-1
        if [ "$SL_ABSENT" -ge 2 ]; then
          sl_record clear boot_progress_absent_twice || :
          return 0
        fi
      else
        SL_UNKNOWN=$((SL_UNKNOWN + 1)); SL_HITS=0 SL_FIRST=-1
      fi
    fi
    [ "$SL_SPENT" -lt "$SOFTLOCK_GRACE_SECONDS" ] || break
    sleep 15
    SL_SPENT=$((SL_SPENT + 15))
  done
  sl_record unverified insufficient_sustained_visible_evidence || :
  return 3
}
# One-shot automatic rescue, only from sl_observe confirmed branch.
sl_recover() {
  load_config # Re-read emergency disarm after the extended observation window.
  [ "$AUTO_SOFTLOCK" = 1 ] && [ "$AUTO_SAFE_MODE" = 1 ] &&
    [ "$AUTO_BOOTLOOP_REBOOT" = 1 ] && [ "$AUTO_RECOVERY" = 0 ] || {
      log WARN 'Softlock confirmed, automatic action not fully armed'; return 1;
    }
  [ "$(read_first "$SL_DIR/decision")" = confirmed ] &&
    [ "$(read_first "$SL_DIR/boot-id")" = "$(boot_id)" ] &&
    [ "$(read_first "$BOOT_DIR/pending-id")" = "$(boot_id)" ] &&
    [ "$(read_first "$BOOT_DIR/last-success-id")" != "$(boot_id)" ] || return 1
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    sl_record confirmed ashrexcue_owns_reboot || :; return 1
  fi
  [ ! -e "$SL_DIR/recovery-attempt" ] || return 1
  # Strict path and ID attestation before touching the next-boot Vector marker.
  SL_MOD="${VECTOR_PROP%/*}"
  [ "$SL_MOD" = /data/adb/modules/zygisk_vector ] &&
    [ -d "$SL_MOD" ] && [ ! -L "$SL_MOD" ] &&
    [ -f "$VECTOR_PROP" ] && [ ! -L "$VECTOR_PROP" ] &&
    grep -Fxq 'id=zygisk_vector' "$VECTOR_PROP" &&
    [ ! -e "$SL_MOD/disable" ] && [ ! -L "$SL_MOD/disable" ] || {
      sl_record confirmed vector_marker_not_safe || :; return 1;
    }
  # Latch BEFORE mutation; do not retry automatically on partial failure.
  write_atomic "$SL_DIR/recovery-attempt" "$(boot_id)" || return 1
  if ! (umask 077; : > "$SL_MOD/disable"); then
    sl_record confirmed marker_write_failed || :; return 1
  fi
  chmod 600 "$SL_MOD/disable" 2>/dev/null || :
  [ -f "$SL_MOD/disable" ] && [ ! -L "$SL_MOD/disable" ] || return 1
  write_atomic "$SL_DIR/recovery-result" marker_written_reboot_requested || :
  log WARN 'Post-boot softlock: Vector disabled for next boot; one bounded rescue reboot requested'
  sync
  guardian_notify softlock-rescue "$(boot_id | tr -cd 'a-fA-F0-9-')" || :
  /system/bin/reboot || { write_atomic "$SL_DIR/recovery-result" reboot_command_failed || :; return 1; }
}
