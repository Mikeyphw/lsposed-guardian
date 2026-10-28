#!/system/bin/sh
# PERSONAL explicit-allowlist automatic quarantine. No causality claim.
AG_DIR="$STATE_DIR/auto-quarantine"
ag_init() { mkdir -p "$AG_DIR" && chmod 700 "$AG_DIR" 2>/dev/null; }
ag_pkg_safe() {
  case "$1" in ''|lspd|com.openai.chatgpt|com.openai.chatgpt:*|android|system_server|zygote*|com.android.systemui|*[!a-zA-Z0-9_.]*|*..*) return 1;;
    *.*) return 0;; *) return 1;; esac
}
ag_allowlisted() {
  ag_pkg_safe "$1" || return 1
  case ",$AUTO_QUARANTINE_ALLOWLIST," in *,"$1",*) return 0;; *) return 1;; esac
}
ag_status() {
  echo "auto_quarantine=$AUTO_QUARANTINE"
  echo "allowlist=$AUTO_QUARANTINE_ALLOWLIST"
  echo "cooldown_seconds=$AUTO_QUARANTINE_COOLDOWN_SECONDS"
  echo "attempted_boot=$(read_first "$AG_DIR/attempted-boot")"
  echo "last_action_epoch=$(read_first "$AG_DIR/last-action-epoch")"
  echo "last_action_module=$(read_first "$AG_DIR/last-action-module")"
  echo 'causality=NOT_ESTABLISHED'
}
ag_plan_app() {
  # Only recent same-boot samples are eligible. A matching scope is not proof
  # of causality; opt-in allowlist provides the final authorization boundary.
  AG_APP="$1"
  ag_pkg_safe "$AG_APP" || return 1
  case ",$CRASH_EXCLUDE_PACKAGES," in *,"$AG_APP",*) return 1;; esac
  AG_DECISION="$(history_decision "$AG_APP")" || return 1
  printf '%s\n' "$AG_DECISION" | grep -Fxq 'decision=REVIEW_SINGLE_SCOPED_MODULE' || return 1
  AG_MOD="$(printf '%s\n' "$AG_DECISION" | sed -n 's/^candidate_for_manual_review=//p')"
  [ -n "$AG_MOD" ] && ag_allowlisted "$AG_MOD" || return 1
  printf '%s\n' "$AG_MOD"
}
ag_candidates() {
  [ -s "$CRASH_FILE" ] || return 0
  AG_NOW="$(date +%s)"; AG_BOOT="$(boot_id)"
  is_number "$AG_NOW" && [ -n "$AG_BOOT" ] || return 1
  # Count distinct PIDs only within the same boot and time window.
  awk -F '\t' -v now="$AG_NOW" -v win="$CRASH_WINDOW_SECONDS" -v b="$AG_BOOT" '
    NF==4 && $1==b && $2 ~ /^[0-9]+$/ && $2+0<=now+10 && $2+0>=now-win {
      x=$3; sub(/:.*/, "", x); k=x SUBSEP $4;
      if(!(k in distinct)){distinct[k]=1;pid[x]++};count[x]++
    }
    END {for(x in count) if(count[x]>=3 && pid[x]>=2) print x}
  ' "$CRASH_FILE" | LC_ALL=C sort -u
}
ag_tick_inner() {
  [ "$AUTO_QUARANTINE" = 1 ] && [ "$PASSIVE_CRASH_MONITOR" = 1 ] && [ "$HISTORY_MONITOR" = 1 ] || return 0
  boot_complete && [ "$(read_first "$BOOT_DIR/last-success-id")" = "$(boot_id)" ] || return 0
  monitor_recent_poll && history_recent_poll || return 0
  [ "$(read_first "$AG_DIR/attempted-boot")" != "$(boot_id)" ] || return 0
  [ ! -e "$BOOT_DIR/manual-restore" ] && [ ! -e "$OS_REQ" ] || return 0
  [ ! -e "$STATE_DIR/quarantine/.lock" ] || return 0
  AG_PEND="$(find "$STATE_DIR/quarantine/pending" -maxdepth 1 -type f \( -name '*.record' -o -name '*.rollback' \) 2>/dev/null | wc -l | tr -d ' ')"
  [ "$AG_PEND" = 0 ] || return 0
  AG_LAST="$(read_first "$AG_DIR/last-action-epoch")"; AG_NOW="$(date +%s)"
  if is_number "$AG_LAST" && is_number "$AG_NOW" &&
     [ "$AG_NOW" -ge "$AG_LAST" ] &&
     [ $((AG_NOW - AG_LAST)) -lt "$AUTO_QUARANTINE_COOLDOWN_SECONDS" ]; then return 0; fi
  AG_MATCHED=''
  AG_LIST="$(ag_candidates)" || return 0
  for AG_APP in $AG_LIST; do
    AG_ONE="$(ag_plan_app "$AG_APP")" || continue
    [ -z "$AG_MATCHED" ] || { log AUTO 'Ambiguous multi-app crash evidence; refusing action'; return 0; }
    AG_MATCHED="$AG_ONE"
  done
  [ -n "$AG_MATCHED" ] || return 0
  # The attempt marker is committed before the first Vector write. Never
  # retry automatically on an uncertain or interrupted toggle.
  write_atomic "$AG_DIR/attempted-boot" "$(boot_id)" || return 0
  write_atomic "$AG_DIR/last-attempt-module" "$AG_MATCHED" || return 0
  if q_apply "$AG_MATCHED" auto; then
    write_atomic "$AG_DIR/last-action-epoch" "$AG_NOW" || :
    write_atomic "$AG_DIR/last-action-module" "$AG_MATCHED" || :
    log AUTO "Explicitly allowlisted module $AG_MATCHED disabled after repeated scoped crashes; causality unknown"
  else
    log WARN "Automatic quarantine failed or pending reconciliation for $AG_MATCHED; no retry this boot"
  fi
}
ag_tick() {
  ag_init || return 0
  mkdir "$AG_DIR/.lock" 2>/dev/null || return 0
  (trap 'rmdir "$AG_DIR/.lock" 2>/dev/null || :' EXIT HUP INT TERM; ag_tick_inner)
}
