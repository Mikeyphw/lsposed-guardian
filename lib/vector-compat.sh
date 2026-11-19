#!/system/bin/sh
# Vector integration uses capability checks, not a maximum versionCode.
# Unknown versions retain read-only diagnostics; unsupported JSON contracts
# block writes. Live SQLite replacement remains separately exact-version-gated.
VC_LAST_REASON=not_probed
vc_identity() {
  [ -f "$VECTOR_PROP" ] && [ ! -L "$VECTOR_PROP" ] &&
    grep -Fxq 'id=zygisk_vector' "$VECTOR_PROP" &&
    [ -n "$(vector_version_code)" ] || { VC_LAST_REASON=module_identity_unverified; return 1; }
}
vc_json_inventory() {
  VC_DEST="$1"
  vc_identity || return 1
  cli_ready && [ ! -L "$VECTOR_CLI" ] || { VC_LAST_REASON=cli_missing_or_unsafe; return 1; }
  vector_bounded 8 status >/dev/null 2>&1 || { VC_LAST_REASON=daemon_unreachable; return 1; }
  if ! vector_bounded 8 --json modules ls > "$VC_DEST" 2>/dev/null; then
    VC_LAST_REASON=inventory_query_failed; return 1
  fi
  # Contract-v1: exactly identifiable package/status records and an explicit
  # successful array. Do not infer enabled state from an unknown JSON schema.
  grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$VC_DEST" &&
    grep -Eq '"data"[[:space:]]*:[[:space:]]*\[' "$VC_DEST" || {
    VC_LAST_REASON=inventory_schema_unknown; return 1;
  }
  # Count field occurrences, not matching *lines*. A future CLI may emit
  # compact JSON with multiple objects on one line; line counting would treat
  # multiple records as one and could miss malformed or duplicated members.
  VC_PKG_ROWS="$STATE_DIR/vector-compat-pkgs.$$"
  grep -Eo '"PACKAGE"[[:space:]]*:[[:space:]]*"[a-zA-Z0-9_.]+"' "$VC_DEST" |
    sed -E 's/^.*:[[:space:]]*"([a-zA-Z0-9_.]+)"$/\1/' > "$VC_PKG_ROWS"
  VC_PACKAGES="$(wc -l < "$VC_PKG_ROWS" | tr -d ' ')"
  VC_STATUSES="$(grep -Eo '"STATUS"[[:space:]]*:[[:space:]]*"(enabled|disabled)"' "$VC_DEST" | wc -l | tr -d ' ')"
  if [ "$VC_PACKAGES" != "$VC_STATUSES" ] ||
     [ -n "$(LC_ALL=C sort "$VC_PKG_ROWS" | uniq -d)" ]; then
    rm -f "$VC_PKG_ROWS"
    VC_LAST_REASON=inventory_fields_mismatch_or_duplicate; return 1
  fi
  rm -f "$VC_PKG_ROWS"
  # Empty arrays are valid but cannot prove any named module is enabled.
  if [ "$VC_PACKAGES" = 0 ]; then
    grep -Eq '"data"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$VC_DEST" || {
      VC_LAST_REASON=inventory_empty_unverified; return 1;
    }
  fi
  VC_LAST_REASON=contract_v1_verified
  return 0
}
vc_inventory_has_package() {
  VC_HPK="$(printf '%s' "$2" | sed 's/\./\\./g')"
  grep -Eq '"PACKAGE"[[:space:]]*:[[:space:]]*"'"$VC_HPK"'"' "$1"
}
vc_toggle_ready() {
  VC_PRE="$STATE_DIR/vector-compat-inventory.$$"
  vc_json_inventory "$VC_PRE"
  VC_RC=$?
  rm -f "$VC_PRE"
  return "$VC_RC"
}
vc_status() {
  printf 'vector_version_code=%s\n' "$(vector_version_code)"
  printf 'vector_identity=%s\n' "$({ vc_identity && echo verified; } || echo unverified)"
  if vc_toggle_ready; then
    printf 'vector_cli_inventory=contract_v1_verified\n'
    printf 'vector_module_toggle=available_with_transaction_checks\n'
  else
    printf 'vector_cli_inventory=unverified:%s\n' "$VC_LAST_REASON"
    printf 'vector_module_toggle=blocked\n'
  fi
  printf 'vector_consistent_backup=runtime_checked_per_snapshot\n'
  if [ "$(vector_version_code)" = 3112 ]; then
    printf 'vector_offline_restore=version_pinned_additional_gates_required\n'
  else
    printf 'vector_offline_restore=blocked_unqualified_version\n'
  fi
  printf 'compatibility_policy=capability_based_fail_closed\n'
}
