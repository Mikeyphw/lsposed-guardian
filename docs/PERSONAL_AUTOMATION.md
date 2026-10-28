# Guardian v0.10.0 — Personal automation (opt-in)

**No upgrade implicitly arms anything.** OBSERVE v0.9.4 acceptance remains historically valid.

## What is live

- Automatic quarantine can disable **only explicitly allowlisted module packages** after 3 recent app crashes involving 2 distinct process IDs, each with a verified same-boot historical checkpoint identifying **exactly one** enabled/scoped module. It makes **no claim of causality**. A single ambiguous case, stale heartbeat, or a pending manual transaction stops all actions. One automatic attempt per boot and 12-hour successful-action cooldown.
- Automatic quarantine is journaled through the same tested `q_apply` path. Its ledger identifies `AUTO_CORRELATED_NOT_CAUSAL`. Manual `rollback PKG --apply` remains available. No app restarts and no automatic reboots.
- Bootloop fallback (`AUTO_SAFE_MODE`) never modifies Vector SQLite. After repeated incomplete boots it writes KernelSU's `disable` marker for `zygisk_vector`, effective on a subsequent boot. The user must manually troubleshoot and remove that marker after stability; Guardian never silently reenables Vector.
- Old `AUTO_RECOVERY` and `restore --apply` unjournaled SQLite replacement are retired and refused, even when a stale config contains `AUTO_RECOVERY=1`.
- The verified one-shot, custom recovery rescue backup, and journal remain intact; the old manual one-shot acceptance remains independent of automatic features.

## Enable in controlled steps (root via Termux)

After `./devtoolw install`, reboot once. Confirm `./devtoolw runtime-parity` reports `ACTIVE_MATCH`. Then:

```
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh auto-allow YOUR.MODULE.PACKAGE --apply
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh auto-arm --apply
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh auto-status
```

Only select non-system modules you are willing to have automatically disabled. Do not allowlist every module. The collector runs evaluations as part of its existing 60-second polling loop; `auto-tick --apply` forces a guarded evaluation without bypassing any checks. `auto-preview APP` makes no changes. You can `auto-disarm` instantly; previously disabled modules remain disabled until you manually run `rollback PKG --apply`.

To opt into the separate *non-SQLite* bootloop fallback:

```
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh safe-mode-arm --apply
```

If it triggers, inspect `safe-mode-status`. To reverse the KernelSU disable marker **after recovery**, use KernelSU's module management or custom recovery; simply disarming future fallback does not reenable Vector.

## Boundaries

User-level active-runtime acceptance, external root-safe tests, and validated historical one-shot success **do not prove** unattended SQLite family replacement across power loss, exclusive access at Android startup, or custom recovery offline undo. Those remain out of scope. A personal-use preference doesn't change SQLite crash consistency guarantees. No auto boot DB restoration is enabled in this version.

## Auditability

New `tools/runtime_parity.py` compares active and staged KernelSU files, including automation helpers. Crash continuity and upgrade receipts come from v0.9.5 hardening. All source updates require exact v0.9.4 hashes; no install or live-device mutation occurs when applying the repository overlay.
