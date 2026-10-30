# LSPosed Guardian v0.12.1 — audited protection WebUI

Guardian is an on-device recovery/control interface, not proof of the cause of Xposed crashes. This is a cumulative v0.11.0 -> v0.12.1 source-bound upgrade, and a separate v0.12.0 -> v0.12.1 audit hotfix. No upgrade enables automatic changes by itself.

## Product behavior

- **Overview:** protection-first screen. Automatic crash response is Disabled, Armed with current evidence, Armed waiting for healthy evidence, or Unavailable (when effective root policy cannot be read). Bootloop fallback separately shows Off, Armed with/without bounded watchdog, or AshReXcue-deferred. Automatic SQLite restore is disabled.
- **Health:** crash collector and historical sampler are independent. Show background poll times, failure reasons, affected module and separate one-time diagnostic actions. A manual capture does NOT certify the background monitor is running, and cannot erase its last recorded background failure.
- **Modules:** verified Vector inventory and filters, fixed-height responsive rows, verified structured scope count and UID, original Vector output behind details, checksum-verified per-module observations (up to last 12 retained snapshots), and quarantine status. Vector CLI does not expose a reliable human description, so the UI says this explicitly.
- **Activity:** Guardian quarantines are parsed as journal events with timestamp, attribution and state digests. Observed configuration differences are shown only when the last two SHA-verified historical snapshots can be compared. These are bounded intervals, NOT module-toggle timestamps; the oldest 510 stored snapshots are not presented as automatically scanned for changes. Sampling and configuration changes remain separate views.
- **Review:** recent crash count, distinct PID count, last matched scope count when known, decision, candidate and explicit human-readable refusal reason. Scope matching never proves a module caused a crash; reviewing cannot toggle modules.
- **Settings:** explicit root-backed confirmation before automatic arm/disarm, safe-mode fallback, optional crash exclusions, and an enumerated 1h–7d cooldown. The immutable ChatGPT crash exclusion remains. After each action, the effective policy is read again and failures are not silently converted into success.
- **Notifications:** `notifications-on --apply` opt-in, `notifications-off`, `notifications-status`, `notifications-test --apply`. Guardian sends best-effort Android shell notifications for automatic quarantine outcomes and bootloop rescue attempts. A return value of zero is only shell acceptance; manual Android shade acceptance is still required. Some ROMs may reject the transport. The journal remains authoritative.
- **Diagnostics:** readable fields, expandable raw receipts and one-tap copy where clipboard support exists. All output uses text nodes instead of HTML injection, all root bridge commands are allowlisted and callback-based.

## Automatic recovery safety

`automatic-on --apply` opts into all uniquely eligible historical scopes, Vector safe-mode fallback, and a bounded reboot watchdog only after boot and Vector preflight. Guardian still requires repeated crashes from at least two PIDs, same-boot pre-crash scope evidence, one unique scoped candidate, no pending quarantine, one attempt per hardware boot and a cooldown. It cannot attribute causality. `automatic-off` disarms future action without automatically rolling back past quarantines or removing a previously written Vector disable marker. `safe-mode-arm` by itself does not turn the watchdog on. Guardian defers platform bootloop action to AshReXcue when detected.

**Automatic SQLite restoration is NOT qualified and remains disabled**. Manual one-shot verified restore is a separate recovery path with its own acceptance requirements. No UI action mutates Vector SQLite directly.

## Installation and device verification

1. Choose **one** source-bound updater: use the consolidated upgrade on the original v0.11.0 checkout, OR the audit hotfix if the v0.12.0 WebUI release is already applied. Never run both.
2. Run its `APPLY-TERMUX.py --dry-run`, then `--apply` only after the expected hashes match. All operations are limited to the source checkout; no `/data/adb` writes occur.
3. Run `cd ~/Code/lsposed-guardian && ./devtoolw install`. A successful KernelSU install may stage under `/data/adb/modules_update`; reboot before deciding active runtime parity.
4. In KernelSU WebUI, confirm v0.12.1 and the five navigation screens, then check effective policy, crash collector, scope sampler and notification test output. Do not arm automatic actions until satisfied with policy and backups.
5. If historical sampling still fails, record Activity → Sampling → background failure stage and module, plus the original `history-health` and module-specific `scope-structured` outputs. Do not call that a fix until background polling succeeds again.

## Evidence boundaries

Host tests (fake Vector, Node WebUI, shell and package checks) cannot prove actual device callbacks, Android notification delivery, Android startup timing, recovery after loss of power, or an unassisted real crash/bootloop recovery. Refer to `docs/WEBUI_V012_AUDIT.md` for the entire promise-by-promise audit. No one-shot restore, surprise quarantine, bootloop injection, or hardware reboot is required for UI acceptance.
