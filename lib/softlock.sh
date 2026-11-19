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
  echo "softlock_selective_enabled=$SOFTLOCK_SELECTIVE"
  echo "softlock_suspect=$SOFTLOCK_SUSPECT"
  echo "softlock_selective_attempt=$(read_first "$SL_DIR/selective-attempt")"
  echo "softlock_selective_result=$(read_first "$SL_DIR/selective-result")"
  echo "softlock_restart_verification=$(read_first "$SL_DIR/restart-verification")"
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
# Probe FallbackHome as a distinct Android mechanism. Its presence alone can
# be entirely legitimate while Android waits for first unlock. Never classify
# that state as a failure without independent KEYGUARD or process-start evidence.
sl_session_signal() {
  if sl_probe; then echo boot_progress; return 0
  else SL_WINDOW_RC=$?; fi
  [ "$SL_WINDOW_RC" -eq 1 ] || { echo unverified; return 0; }
  SL_ACT="$SL_DIR/activity.$$"
  SL_LOG="$SL_DIR/logcat.$$"
  SL_FRESH="$SL_DIR/logcat-fresh.$$"
  if ! $SL_TIMEOUT 8 dumpsys activity activities > "$SL_ACT" 2>/dev/null || [ ! -s "$SL_ACT" ]; then
    rm -f "$SL_ACT"; echo unverified; return 0
  fi
  # Require the RESUMED activity to be FallbackHome; a historical task entry is
  # never proof that FallbackHome is displayed now.
  # Do not call an empty or unparsable ActivityManager result "healthy".
  # Unknown OEM activity formats remain UNVERIFIED until explicitly supported.
  SL_TOP="$(grep -E 'mResumedActivity|topResumedActivity|ResumedActivity:' "$SL_ACT")"
  [ -n "$SL_TOP" ] || { rm -f "$SL_ACT"; echo unverified; return 0; }
  if ! printf '%s\n' "$SL_TOP" | grep -Eq '([/.]FallbackHome)([ /}]|$)'; then
    rm -f "$SL_ACT"
    if printf '%s\n' "$SL_TOP" | grep -Eq '[A-Za-z0-9_.]+/[.A-Za-z0-9_$]+'; then echo clear
    else echo unverified; fi
    return 0
  fi
  rm -f "$SL_ACT"
  command -v logcat >/dev/null 2>&1 || { echo fallback_unverified; return 0; }
  # Epoch timestamps are mandatory; plain logcat output or old buffered events
  # never authorize a recovery action. Logcat is global, not scoped to a boot.
  if ! $SL_TIMEOUT 8 logcat -d -v epoch -b system -b events -b main -t 600 > "$SL_LOG" 2>/dev/null; then
    rm -f "$SL_LOG"; echo fallback_unverified; return 0
  fi
  SL_NOW="$(date +%s)" || { rm -f "$SL_LOG"; echo fallback_unverified; return 0; }
  # Initial boot, stability and observation phases all fit this bounded window.
  # Accept no un-timestamped or future log evidence; avoid older-boot replay.
  SL_AGE=$((BOOT_WAIT_SECONDS + STABILITY_SECONDS + SOFTLOCK_GRACE_SECONDS + 90))
  if ! awk -v now="$SL_NOW" -v age="$SL_AGE" '
    $1 ~ /^[0-9]+[.][0-9]+$/ && length($1) >= 12 &&
    ($1+0) <= now+2 && ($1+0) >= now-age {print}
  ' "$SL_LOG" > "$SL_FRESH"; then
    rm -f "$SL_LOG" "$SL_FRESH"; echo fallback_unverified; return 0
  fi
  rm -f "$SL_LOG"
  if grep -Eiq '(CR DEAD|died|disconnect(ed)?|DeadObjectException).{0,120}(keyguard|KeyguardService)|(keyguard|KeyguardService).{0,120}(CR DEAD|died|disconnect(ed)?|DeadObjectException)' "$SL_FRESH"; then
    rm -f "$SL_FRESH"; echo fallback_keyguard_failure; return 0
  fi
  # Require failures for at least two distinct critical Android processes.
  SL_FAILS="$(grep -Ei '(failed to attach|attach.*timeout|process.*start.*timeout)' "$SL_FRESH" |
     grep -Eio 'com\.android\.(systemui|phone|settings)|com\.google\.android\.apps\.nexuslauncher' |
     LC_ALL=C sort -u | wc -l | tr -d ' ')"
  rm -f "$SL_FRESH"
  if is_number "$SL_FAILS" && [ "$SL_FAILS" -ge 2 ]; then
    echo fallback_process_start_storm
  else
    echo fallback_unverified
  fi
}
# Repeated same-boot observations: process health is not UI health. An ambiguous
# foreground FallbackHome blocks a clean UI receipt, but never triggers rescue.
sl_observe() {
  [ "$SOFTLOCK_MONITOR" = 1 ] || { sl_record disabled monitor_disabled; return 0; }
  SL_SPENT=0 SL_FIRST=-1 SL_HITS=0 SL_ABSENT=0 SL_SUSPECT=0 SL_PREV=
  # A late onset must receive the same full evidence window as an early onset.
  # Normal clear boots still finish at the single configured grace period.
  SL_MAX_SPENT=$((SOFTLOCK_GRACE_SECONDS * 2))
  sl_record observing observation_started || :
  while [ "$SL_SPENT" -le "$SL_MAX_SPENT" ]; do
    if ! boot_complete || [ "$(read_first "$BOOT_DIR/pending-id")" != "$(boot_id)" ]; then
      sl_record unverified boot_identity_changed || :; return 3
    fi
    SL_SIGNAL="$(sl_session_signal)"
    case "$SL_SIGNAL" in
      boot_progress|fallback_keyguard_failure|fallback_process_start_storm)
        SL_ABSENT=0
        if [ "$SL_SIGNAL" = "$SL_PREV" ]; then SL_HITS=$((SL_HITS + 1));
        else SL_PREV="$SL_SIGNAL"; SL_HITS=1; SL_FIRST="$SL_SPENT"; fi
        if [ "$SL_HITS" -ge 4 ] && [ "$((SL_SPENT - SL_FIRST))" -ge "$SOFTLOCK_GRACE_SECONDS" ]; then
          case "$SL_SIGNAL" in
            boot_progress) SL_REASON=persistent_visible_boot_progress ;;
            fallback_keyguard_failure) SL_REASON=persistent_fallback_keyguard_failure ;;
            fallback_process_start_storm) SL_REASON=persistent_fallback_process_start_storm ;;
          esac
          sl_record confirmed "$SL_REASON" || :
          log WARN "Post-boot UI failure confirmed: $SL_REASON; healthy receipt withheld"
          return 2
        fi ;;
      clear)
        SL_ABSENT=$((SL_ABSENT + 1)); SL_PREV=; SL_HITS=0; SL_FIRST=-1
        # A late failure can follow two normal early polls. Only qualify the
        # initial boot after a complete grace period, not after 15 seconds.
        if [ "$SL_SPENT" -ge "$SOFTLOCK_GRACE_SECONDS" ] && [ "$SL_ABSENT" -ge 2 ]; then
          sl_record clear no_boot_dialog_or_fallback_home || :; return 0
        fi ;;
      fallback_unverified)
        SL_SUSPECT=1; SL_ABSENT=0; SL_PREV=; SL_HITS=0; SL_FIRST=-1 ;;
      *) SL_ABSENT=0; SL_PREV=; SL_HITS=0; SL_FIRST=-1 ;;
    esac
    [ "$SL_SPENT" -lt "$SL_MAX_SPENT" ] || break
    sleep 15
    SL_SPENT=$((SL_SPENT + 15))
  done
  if [ "$SL_ABSENT" -ge 2 ]; then
    sl_record clear no_boot_dialog_or_fallback_home || :
    return 0
  fi
  if [ "$SL_SUSPECT" -eq 1 ]; then
    sl_record unverified fallback_home_no_independent_failure_evidence || :
    return 4  # Do not mark UI healthy, but never reboot or quarantine.
  fi
  sl_record unverified insufficient_correlated_evidence || :
  return 3
}
# Explicitly preselected suspect only. No automated attribution from a scope.
# If a single module is not preapproved, do not disable any module.
sl_selective_candidate() {
  [ "$SOFTLOCK_SELECTIVE" = 1 ] && [ "$AUTO_SOFTLOCK" = 1 ] || return 1
  case "$SOFTLOCK_SUSPECT" in
    ''|.*|*..*|*.*[!a-zA-Z0-9_.]*|*[!a-zA-Z0-9_.]*|com.android.*|android.*|lspd) return 1 ;;
    *.*) : ;;
    *) return 1 ;;
  esac
  case ",$CRASH_EXCLUDE_PACKAGES," in *,"$SOFTLOCK_SUSPECT",*) return 1;; esac
  [ -z "$(read_first "$SL_DIR/selective-attempt")" ] || return 1
  [ ! -e "$STATE_DIR/quarantine/active/$SOFTLOCK_SUSPECT.record" ] &&
    [ ! -e "$STATE_DIR/quarantine/pending/$SOFTLOCK_SUSPECT.record" ] &&
    [ ! -e "$STATE_DIR/quarantine/pending/$SOFTLOCK_SUSPECT.rollback" ] || return 1
  vector_bounded 8 status >/dev/null 2>&1 || return 1
}
# Independent post-restart verification. A successful setprop call is NOT
# evidence that the Zygote was restarted or the phone became usable.
sl_watch_restart() {
  SL_OLD_PID="$1"
  SL_TICKS=0 SL_CLEAR=0 SL_CHANGED=0
  while [ "$SL_TICKS" -lt 18 ]; do
    sleep 5
    SL_TICKS=$((SL_TICKS + 1))
    [ "$(read_first "$SL_DIR/restart-request")" = "$(boot_id)" ] || return 1
    SL_NEW_PID="$(pidof system_server 2>/dev/null | awk '{print $1}')"
    if [ -n "$SL_NEW_PID" ] && [ "$SL_NEW_PID" != "$SL_OLD_PID" ]; then
      SL_CHANGED=1
      if boot_complete && vector_bounded 8 status >/dev/null 2>&1 &&
         [ "$(sl_session_signal)" = clear ]; then
        SL_CLEAR=$((SL_CLEAR + 1))
        if [ "$SL_CLEAR" -ge 2 ]; then
          write_atomic "$SL_DIR/restart-verification" ui_signals_clear_not_device_certified || :
          return 0
        fi
      else
        SL_CLEAR=0
      fi
    fi
  done
  if [ "$SL_CHANGED" = 1 ]; then SL_RESULT=framework_restarted_ui_unverified
  else SL_RESULT=framework_restart_unverified; fi
  write_atomic "$SL_DIR/restart-verification" "$SL_RESULT" || :
  return 1
}
# A framework restart is a major operation; it is NOT Android's deprecated
# userspace reboot. Vector itself restarts the primary Zygote via ctl.restart.
# Never change RescueParty counters; never repeat an attempted restart.
sl_soft_restart() {
  [ "$SOFTLOCK_ZYGOTE_RESTART" = 1 ] || return 1
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] &&
    [ "$(getprop init.svc.zygote 2>/dev/null)" = running ] || return 1
  command -v setprop >/dev/null 2>&1 || return 1
  SL_BEFORE_PID="$(pidof system_server 2>/dev/null | awk '{print $1}')"
  [ -n "$SL_BEFORE_PID" ] || return 1
  write_atomic "$SL_DIR/restart-request" "$(boot_id)" || return 1
  write_atomic "$SL_DIR/restart-verification" pending_framework_restart || return 1
  # No automatic full reboot after an unverified framework restart.
  setprop ctl.restart zygote || {
    write_atomic "$SL_DIR/restart-verification" restart_command_failed || :; return 1;
  }
  # A restart request is NOT success. If the original shell survives, the
  # monitor must prove a changed system_server PID and two clear observations.
  # If it dies, the durable receipt remains pending/unknown for manual review.
  sl_watch_restart "$SL_BEFORE_PID"
}
sl_try_selective() {
  sl_selective_candidate || {
    write_atomic "$SL_DIR/selective-result" candidate_unqualified || :; return 1;
  }
  [ "$SOFTLOCK_ZYGOTE_RESTART" = 1 ] &&
    [ "$(getprop init.svc.zygote 2>/dev/null)" = running ] &&
    command -v setprop >/dev/null 2>&1 || return 1
  # Latch BEFORE the Vector write so a failed/partial transaction cannot loop.
  write_atomic "$SL_DIR/selective-attempt" "$(boot_id)" || return 1
  write_atomic "$SL_DIR/selective-suspect" "$SOFTLOCK_SUSPECT" || return 1
  if ! sh "$MODDIR/guardian.sh" quarantine "$SOFTLOCK_SUSPECT" --apply        > "$SL_DIR/quarantine-result" 2>&1; then
    write_atomic "$SL_DIR/selective-result" quarantine_unverified_reconcile_manually || :
    return 1
  fi
  [ -s "$STATE_DIR/quarantine/active/$SOFTLOCK_SUSPECT.record" ] || {
    write_atomic "$SL_DIR/selective-result" missing_quarantine_receipt || :; return 1;
  }
  write_atomic "$SL_DIR/selective-result" quarantined_restart_requested || :
  if ! sl_soft_restart; then
    write_atomic "$SL_DIR/selective-result" quarantined_restart_unverified || :
    return 1
  fi
  write_atomic "$SL_DIR/selective-result" framework_restarted_signals_clear || :
  return 0
}
# One-shot automatic rescue, only from sl_observe confirmed branch.
sl_recover() {
  load_config # Re-read emergency disarm after the extended observation window.
  [ "$AUTO_SOFTLOCK" = 1 ] && [ "$AUTO_RECOVERY" = 0 ] || {
      log WARN 'Softlock confirmed but automatic response is not armed'; return 1;
    }
  [ "$(read_first "$SL_DIR/decision")" = confirmed ] &&
    [ "$(read_first "$SL_DIR/boot-id")" = "$(boot_id)" ] &&
    [ "$(read_first "$BOOT_DIR/pending-id")" = "$(boot_id)" ] &&
    [ "$(read_first "$BOOT_DIR/last-success-id")" != "$(boot_id)" ] || return 1
  if [ -d /data/adb/modules/AshLooper ] || [ -d /data/adb/modules/ashrexcue ]; then
    sl_record confirmed ashrexcue_owns_reboot || :; return 1
  fi
  # Selective intervention is an independent, explicit policy and one-shot.
  # A failed or unverifiable selective attempt NEVER falls through to a full reboot.
  if [ "$SOFTLOCK_SELECTIVE" = 1 ]; then
    sl_try_selective || log WARN 'Selective softlock rescue refused/failed; manual inspection required'
    return 0
  fi
  # Full-reboot fallback is a separate permission; selective rescue never
  # silently enables or escalates to it.
  [ "$AUTO_SAFE_MODE" = 1 ] && [ "$AUTO_BOOTLOOP_REBOOT" = 1 ] || {
    sl_record confirmed full_reboot_fallback_not_armed || :; return 1;
  }
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

sl_verify_restart() {
  # Read-only inspection. A single manual clean sample must NEVER turn an
  # unverified restart into a success receipt, even when the command was sent.
  [ "$(read_first "$SL_DIR/restart-request")" = "$(boot_id)" ] || {
    echo 'softlock_restart_verification=not_requested_this_boot'; return 1;
  }
  echo "softlock_restart_verification=$(read_first "$SL_DIR/restart-verification")"
  echo "softlock_current_session_signal=$(sl_session_signal)"
  [ "$(read_first "$SL_DIR/restart-verification")" = ui_signals_clear_not_device_certified ]
}
