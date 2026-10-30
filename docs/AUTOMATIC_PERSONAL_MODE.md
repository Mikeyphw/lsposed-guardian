# Guardian v0.11.0 — automatic personal protection

## Intent

Single one-time activation, then no per-incident confirmations or per-module
allowlist required. Inspired by AshReXcue's automatic bootloop response, but
Guardian targets **Vector/LSPosed modules**, whereas AshReXcue primarily guards
Magisk/KernelSU/APatch modules. Guardian does not claim to implement AshReXcue's
multi-stage root-module/script differential recovery, nor guarantee boot recovery.

## Enable once

After installing the **active** v0.11.0 KernelSU module and rebooting:

```sh
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh automatic-on --apply
```

The activation checks that Android booted and Vector responds. This explicit
one-time command updates root-private settings and arms:

- `AUTO_QUARANTINE=1`, `AUTO_QUARANTINE_POLICY=all_scoped`: On every crash-poll
  (default 60s), disable an eligible enabled Vector module only after ≥3 recent
  crash records with ≥2 distinct PIDs, all tied to the same kernel boot and to
  trusted historical scope checkpoints. There must be **exactly one** same
  candidate module across those events, which must still be enabled and scoped
  to the crashed process. Otherwise no mutation. The change is journaled and
  can be manually rolled back. A module's scope does **not** establish causality.
- `AUTO_SAFE_MODE=1`: On repeated incomplete hardware boots, prepare to disable
  the `zygisk_vector` KernelSU module with an on-disk `disable` marker, without
  modifying SQLite. It takes effect on the next reboot.
- `AUTO_BOOTLOOP_REBOOT=1`: When Android never reaches `sys.boot_completed`
  before the 210-second default timeout, or SystemUI fails three times in the
  stability window, request a bounded automatic reboot (maximum 3 per unresolved
  incident). A successful boot clears that watchdog counter. If AshReXcue is
  installed, **defer all Vector safe-mode/reboot handling** to AshReXcue to
  avoid competing bootloop protectors.

`com.openai.chatgpt` crashes are always excluded; system process identifiers
and non-package module identifiers are not candidates. At most one quarantine
attempt is made per boot; successful actions have a 12-hour cooldown. No
modules are toggled merely by enabling automatic mode.

## Disable instantly

```sh
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh automatic-off
```

The live collector reloads policy each poll. The early boot hook reads settings
on every boot. Existing quarantine records and any prior Vector `disable`
marker are **retained**, not silently reversed. To inspect:

```sh
sudo /system/bin/sh /data/adb/modules/lsposed_guardian/guardian.sh automatic-status
```

## Important limits

- This is automatic bounded quarantine + KernelSU Vector fallback, **not**
  unattended SQLite recovery. The legacy unjournaled SQLite restore remains
  disabled, including when a stale `AUTO_RECOVERY=1` is present.
- If **AshReXcue** is installed, it owns platform bootloop protection; Guardian
  still performs scoped app-crash quarantine while Android and Vector run.
- If root services never start, Guardian cannot recover autonomously.
- SystemUI crash detection can misattribute errors. Disable/rollback may need
  an app restart, and an emergency Vector disable may require manual re-enable.
- The documented manual v0.9.4 restoration acceptance remains historical; it
  does not qualify power-loss-safe, exclusive early-boot DB operations.
- Installation/upgrading does not silently arm existing installations. The
  `automatic-on --apply` command is the authorization to activate.

This implementation is based on Guardian's local sources, with host fixtures.
It is **not** claimed device-tested until actually installed and observed.
