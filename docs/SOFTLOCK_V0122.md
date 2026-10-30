# Guardian v0.12.2 — Post-boot soft-lock protection

## Failure model

Android may set `sys.boot_completed=1` and keep a stable `com.android.systemui` process while the framework still displays its non-cancelable boot-progress dialog, sometimes labeled “Phone is starting” or “Phone is loading.” Successful PID checks alone do not establish a usable session. Conversely, a legitimately locked device, delayed credential unlock, disabled launcher, or unavailable `dumpsys` is **not** sufficient evidence to reboot.

AOSP `PhoneWindowManager` gives the startup progress dialog `TYPE_BOOT_PROGRESS` (window type 2021), and this window can consume user events. An OEM loading screen can use a different implementation; detection is intentionally not claimed for those variants.

Sources:
- https://android.googlesource.com/platform/frameworks/base/+/android16-qpr1-release/services/core/java/com/android/server/policy/PhoneWindowManager.java
- https://kernelsu.org/guide/rescue-from-bootloop.html

## State machine

1. Existing boot completion and SystemUI stability checks remain mandatory.
2. Before Guardian clears a pending boot, the read-only observer samples WindowManager using a time-bounded `dumpsys window windows` call. It examines `Window #... Window{...}` entries for `ty=2021` / `TYPE_BOOT_PROGRESS` plus explicit `isOnScreen=true` / `isVisible=true`.
3. Two consecutive snapshots that show a valid window inventory but no boot-progress window qualify as `clear`. No usable window inventory, an ambiguous visibility flag, timeout, or an unsupported ROM becomes `unverified`.
4. To qualify as `confirmed`, the startup window must be explicitly visible on at least four samples and persist across the configured full grace period (180 seconds by default, admissible range 120–600 seconds). If visibility disappears, the continuity counter resets.
5. A `confirmed` observation prevents Guardian from marking the boot stable or starting the healthy-boot collectors. An `unverified` observation cannot trigger rescue; the older process-health qualification may proceed, but must not be represented as a verified usable UI.

This observer is intentionally confined to initial boot qualification; it does not claim to detect freezes appearing much later in a running session.

## Recovery policy

Detection is enabled in v0.12.2 by default (`SOFTLOCK_MONITOR=1`), but no upgrade arms an automatic action (`AUTO_SOFTLOCK=0`). The **Enable bounded rescue** control / `softlock-on --apply` independently arms only the required bootloop fallback (`AUTO_SAFE_MODE=1`) and bounded watchdog (`AUTO_BOOTLOOP_REBOOT=1`), after checking retired legacy recovery (`AUTO_RECOVERY=0`), a verified stable boot, a functioning Vector, and a parseable healthy ROM window inventory. It does not require the crash collector, historical scope sampler, or crash-quarantine automatic mode to be armed. Failure or an already visible boot-progress dialog blocks arming.

A rescue is attempted only on `confirmed` evidence in the same pending kernel boot, after re-reading effective policy to honor last-moment disarming. It refuses coexistence with AshReXcue/AshLooper, reboots without altering Vector SQLite, and will only write `/data/adb/modules/zygisk_vector/disable` if the exact module directory and `module.prop` are verified and there is no existing marker. The one-shot latch is persisted before any write, preventing reboot storms. A successful later boot with Vector restored and its disable marker removed releases that latch. No unknown Magisk/KernelSU module is ever disabled.

Bootloop fallback disarm and general automatic disarm both clear `AUTO_SOFTLOCK`, without removing existing disable markers or prior receipts.

## Operations and receipts

Read-only:

```sh
su -c '/data/adb/modules/lsposed_guardian/guardian.sh softlock-status'
su -c '/data/adb/modules/lsposed_guardian/guardian.sh softlock-probe'
su -c '/data/adb/modules/lsposed_guardian/guardian.sh softlock-events'
```

To explicitly arm this independent capability and its necessary bounded fallback, activate it in the WebUI or:

```sh
su -c '/data/adb/modules/lsposed_guardian/guardian.sh softlock-on --apply'
```

Emergency disarm:

```sh
su -c '/data/adb/modules/lsposed_guardian/guardian.sh softlock-off'
```

The receipt directory `/data/adb/lsposed-guardian/softlock/` stores last boot ID, decision, reason, timestamp, last recovery attempt, and a bounded 256-entry action/observation journal. Complete raw WindowManager dumps are deleted immediately and are not included in Guardian logs.

## Acceptance evidence / important limits

PASS (host): shell syntax, repository safety validation, 13 dedicated failure/safety tests, 70 core tests, 83 existing recovery/integration tests across five suites, WebUI bridge regression checks.

OPEN (device): Verify the actual Android 16 ROM's window-dump schema and accessibility of `timeout`/`toybox timeout`, measure real elapsed time, confirm visual startup condition and whether the UI is restored with Vector disabled, observe emergency disarm, confirm KernelSU reboot side effects. An OEM-specific loading screen or a frozen SystemUI with no TYPE_BOOT_PROGRESS cannot be automatically attributed to Vector by this detector; it remains outside this narrow rescue strategy.

No unattended live-device reboot, KernelSU module disable, rollback or live recovery was executed in the host environment. Do **not** report any such acceptance as passed until device receipts and the visible screen are checked.
