# Roadmap and qualification ledger

## Phase 1 — Vector-backed boot recovery (implemented, unqualified)
- [x] Read-only boot failure detection and stable window
- [x] Native Vector CLI adapter and consistent SQLite backup
- [x] Early-boot restore guarded by manual arming and daemon absence
- [x] CLI module toggling, scopes and crash diagnostics
- [x] Local host unit tests and module ZIP packaging
- [x] Real KernelSU installation and normal boot check on intended Android device (v0.1–v0.5 logs; recovery not exercised)
- [x] Observe multiple normal hardware boots to verify boot-ID/state behavior
- [ ] Confirm CLI permissions, `VACUUM INTO` backup, WAL and SELinux context
- [ ] Confirm early-boot ordering relative to Vector daemon
- [ ] Test recovery on isolated device/emulator with disposable Vector fixture
- [ ] Record device-derived JSON evidence and precise tested commit/archive digest

## Phase 2 — Per-app crash correlations (in progress, passive v0.4 implemented)
- [x] Native logcat crash-buffer parser with boot ID / epoch / process / PID (UID enrichment still pending)
- [x] Track bounded, de-duplicated process/PID crash observations and recent time windows (exception bucketing pending)
- [x] Read-only collector heartbeat and isolated synthetic fixture test for deduplication and history persistence
- [ ] Verify actual logcat capture and nonempty event retention across hardware boots on a disposable app fixture
- [x] Cross-reference enabled modules with explicit scope, including `system_server` → `system` (implicit/auto scopes and module change time pending)
- [ ] Separate action outcomes: suspect, tentative, quarantine, verified recovery
- [ ] Transactional scope-only quarantine and rollback via Vector CLI
- [ ] Avoid false positives caused by system components crashing without Xposed
- [ ] Rate-limit or disable automation around SystemUI/system_server

## Phase 3 — selective early-boot recovery (not implemented)
- [ ] Cross-version safe offline SQLite mutation with integrity and schema checks
- [ ] Diff enabled modules against last-known-good manifest and APK signatures
- [ ] Prefer suspicious module disable before full backup restoration
- [ ] Reboot-independent recovery attempt ledger and fail-closed rollback
- [ ] Integration tests: WAL replay prevention, power loss, SELinux, storage full
- [ ] Escalation policy coordinated with AshLooper rather than issuing reboots

## Phase 4 — presentation/experience (not implemented)
- [ ] Local WebUI / Android surface with protected control endpoint
- [ ] Recent crash timeline, suspected responsible hook module and reasoning
- [ ] Manage backup history, per-scope quarantine, and one-click restore
- [ ] User-configured thresholds and observe/armed/quarantined states
- [ ] Device evidence export with sanitized JSON

## Audit limitations
- L001: Vector `db restore` closes SQLite handle and copies the main DB without visibly removing stale WAL sidecars. Guardian intentionally does NOT invoke live `db restore`; its recovery is offline early-boot only. Investigate upstream changes before supporting it.
- L002: Snapshot rotation currently keeps only two backups and does not account for latent hook failures that manifest after stable boot. Retain an out-of-band backup before arming.
- L003: PID-based SystemUI restarts alone do not prove an Xposed module caused the crash; no automatic app quarantine is enabled.
- L004: Root module boot-stage ordering on KernelSU late-load is device-dependent and must be verified before arming.

- L005: The bounded crash event history relies on the Android crash log buffer; it cannot detect missing, cleared, or native-only failures, and timestamp/PID associations are not causal proof. No automatic quarantine.

- L006: Startup log proves a collector was launched, not that it is still polling. v0.3 adds a bounded current-boot polling heartbeat and exposes its provenance in diagnostics.
- L007: Historical v0.3 note: crash history was initially empty. Superseded by v0.4/v0.5 device evidence with real stored ChatGPT process crash records across three boot IDs. Source attribution remains unqualified.

- L008: v0.3 collector logged unclassified failures; v0.4 records finite privacy-safe reasons and distinguishes a concurrent collector from actual logcat failures. The 2026-10-19 19:17:18 UTC failure cannot be reclassified retroactively.
- L009: Two genuine records exist in current v0.3 history, but their process names and boot IDs have not yet been reviewed. Do not infer hook causality from event count.

## v0.4 device evidence received (2026-10-19)
- PASS: normal boot on Vector 2.2 (versionCode 3112), snapshots, current-boot collector poll, isolated parser selftest; OBSERVE.
- Stored three crashes all from `com.openai.chatgpt`, across two prior boot IDs; not attributed to Vector/Xposed.
- Enabled module count changed from 2 in v0.3 to 6 in v0.4, exact toggles and their timing unknown.
- `github.tornaco.android.thanos` currently scoped to `system_server` but with zero recent system-server crashes; do not quarantine by inference.
- Recovery remains UNQUALIFIED; no device offline restore or automatic app recovery demonstrated.

## v0.5 baseline policy and review (implemented; host 30/30 PASS, device unqualified)
- [x] Preserve existing `last-good.db` on every later stable boot; write separate observed candidate.
- [x] Read-only `changes` against pinned baseline (name/enablement only, not historic timing).
- [x] Read-only `assess PACKAGE` using retained crash history and current Vector scopes.
- [x] `promote --apply` with previous-good rotation and interruption fail-closed guard.
- [x] Distinguish never-recorded collector failure as JSON null.
- [ ] Verify device upgrade from v0.4 preserves exact baseline digest and all existing crash history.
- [ ] Verify cross-boot observed/pinned manifest deltas with disposable Vector fixture.
- [ ] Record module/version/target-scope changes with trustworthy timestamps (not yet implemented).
- [ ] Verify promotion interruption on real filesystem and check database integrity beyond SQLite header.
- [ ] Implement opt-in explicit reversible per-module quarantine (no unattended auto-quarantine).

## Known risk: historical provenance gap
Historical v0.4 snapshots were automatically overwritten after stable boots. This may already have replaced the original 2-module baseline with a 6-module snapshot. v0.5 freezes whichever baseline is found during upgrade; it cannot honestly label its age or infer whether newly observed crashes predate a configuration change. Store attribution separately from suspicion and never auto-quarantine based on count alone.

## v0.5.1 device investigation and correction
- Device boot on v0.5.0 reached stable state and collector reported healthy, but `doctor` and JSON `report` misleadingly claimed version 0.4.0 because of hard-coded strings in `guardian.sh`; the archive's `module.prop` correctly identified version 0.5.0.
- Upgraded v0.4 baseline had no `last-good.boot-id` metadata, so `baseline_boot` displayed empty. No origin boot ID can be inferred retroactively. v0.5.1 labels it `unknown_legacy` and exports JSON null.
- Current module manifest equals pinned manifest with six enabled modules; no historical toggle timestamps are available. Five retained `com.openai.chatgpt` crashes across three boots; current scopes showed no explicitly enabled module targeting ChatGPT. No causality established.
- v0.5.1 leaves baseline/history state untouched and remains in observation mode. Full SQLite integrity and offline restore remain open obligations.

## v0.6 consolidated integrity and quarantine gate (2026-10-20)
- [x] SHA-256/size attestation of complete Vector VACUUM backups; SQLite `integrity_check` and schema check when sqlite3 is available
- [x] Imported legacy snapshot preservation; fail-closed on legacy / tampered / interrupted snapshots; explicitly qualified promotion path
- [x] Default disabled device-recovery qualification gate; automatic restore and queue denied while unqualified
- [x] Manual per-module quarantine preview, confirmed CLI toggle, persistent pending/active journal and exact-module rollback
- [x] Explicit interrupted-quarantine reconciliation and sanitized event ledger with before/after manifest hashes
- [x] Explicit exclusion of ChatGPT crash records from recovery decisions; history is still retained diagnostically
- [ ] Verify `sqlite3` availability and acceptable Android-native integrity verifier on target device
- [ ] Validate schema/version metadata and imported baseline digest with real-device read-only reports
- [ ] Test selective quarantine with an **intentionally disposable**, benign Xposed module before enabling any automatic logic
- [ ] Test offline recovery on expendable device and establish WAL/SELinux/startup-order acceptance
- [ ] Ensure previous-good rotation is crash-atomic across filesystem power loss; current process-marker prevents automatic restore after incomplete promotion but does not prove full power-loss ACID semantics
- [ ] Historical package/scope state at crash timestamp cannot be reconstructed. No automatic suspect attribution.


## v0.6 real-device acceptance update (2026-10-20)
- PASS: v0.6.0 stable boot, Vector 2.2/3112, fresh collector polls and observed SQLite integrity; 0 failed boots. Initial legacy pinned baseline remains `legacy_header_only`, not restore qualified. Guardian stayed in `OBSERVE`.
- PASS: manual quarantine **previews only** for enabled `github.tornaco.android.thanos` (system_server-scoped) and disabled `com.waenhancer`; no mutations and no quarantine ledger events.
- User confirmed `com.openai.chatgpt` crashes have nothing to do with LSPosed; excluded from recovery actions. Later count 7 is diagnostic only.
- TODO: live quarantine/rollback on disposable Xposed module and actual offline database restore on expendable test environment; neither is implied by v0.7 host tests.

## v0.7 consolidated historical evidence and rollback-journal development
- [x] Record post-install enabled modules and their **explicit** scopes in root-only per-boot, per-epoch samples; SHA-256 digest and bounded index/file retention.
- [x] Never reconstruct pre-v0.7 scopes from current Vector state. Only use samples from same boot captured before crash and within freshness window.
- [x] Distinguish excluded package, too few events/distinct processes, no matching scope, multiple/inconsistent candidates, missing/corrupt/stale checkpoint, state changed, and review-only single candidate.
- [x] Enforce automatic action disabled in every decision path, with ChatGPT exclusion.
- [x] Add rollback interruption journal and explicit manual reconciliation, refusal to reconcile when unrelated module inventory changes.
- [x] Add isolated fake-Vector fault injection for lost-response/no-op/concurrent mutation and provenance protection.
- [x] Add independent historical sampler heartbeat and read-only diagnostics; not started until stable boot.
- [ ] Device acceptance for nonempty history and sample persistence across hardware boots.
- [ ] Cross-check actual Vector scope JSON shape and Android shell portability on the target device.
- [ ] Test reconciliation after physical interruption and durability under power loss on disposable hardware.
- [ ] Instrument loaded-hook visibility if available; scope presence is not proof that hooks executed.
- [ ] Verify automating any quarantine via an isolated fixture before exposing a user-accessible auto-quarantine option (not present).

## Deferred v0.8 and v1.0 (no premature implementation)
- v0.8: controlled recovery and optional per-scope test isolation (must earn explicit device qualification, no daily-phone destructive testing).
- v1.0: Android management UX, full release and device qualification, privacy/security audit and tested recovery/rollback documentation.


## v0.8.0 consolidated milestone (2026-10)

Implemented: read-only KernelSU WebUI, isolated recovery lab (copy-only staged restore scenarios), read-only recovery-plan command, Termux panel, retained v0.7 failure-journal safeguards. Lab does **not** qualify real offline restore; device gate remains 0.

Deferred to independent device qualification: true early-boot recovery including Vector daemon absence and WAL/SELinux ordering, injected interruption/power-loss on a disposable target, real noncritical module quarantine and verified rollback, non-observational automated recovery. No background work or blind arming on daily-use device.

## v0.9.0 consolidated implementation and evidence (host/device acceptance pending)
- [x] Fold v0.8 KernelSU full-output repair into canonical WebUI (all installed modules, complete multiline output)
- [x] Add read-only scope inspection per listed module, sanitize package argument and render as text
- [x] Add explicit read-only `qualification` status; never equate host/isolated laboratory pass with device restore qualification
- [x] Implement synthetic Vector quarantine lab exercising actual manual toggle/reconcile code and fault-injected lost responses, no-op, ledger failure and unrelated inventory change
- [x] Add sandbox restore post-commit rollback scenario, preserving synthetic WAL/SHM from before staged replacement
- [ ] Qualify WebUI scope inspection and both new labs on target Android device
- [ ] Separate real-device controlled quarantine/rollback of disposable module
- [ ] Genuine early-boot recovery with fault injection on disposable Android environment
- [ ] Confirm Vector boot ordering, SELinux, stale WAL handling and reliable rollback in the presence of power loss
- [ ] v1.0 general release requires ALL device qualification gates; no automatic actions before then

Note: `RECOVERY_DEVICE_QUALIFIED=1` configured in certain host fixtures is solely for
negative-test coverage. It is NOT evidence of a qualified physical device. The
`qualification` command reports this as `CONFIG_FLAG_SET_NOT_DEVICE_PROOF`.

### Real-device qualification campaign (after v0.9 host acceptance)

- [ ] Live Guardian/Vector quarantine+rollback for `eu.hxreborn.remembermysort` on the owner's device; requires explicit authorized invocation, exact before/during/after inventory and no pending journals.
- [ ] Fresh independent confirmation after test that target is enabled and other seven enabled modules remain unaffected.
- [ ] Disposable Android early-boot offline database restore under genuine boot timing and SELinux/WAL conditions; daily-driver preflight alone does not close this gate.
- [ ] Fault-inject interrupted early-boot restore and verify deterministic recovery / rescue; no promotion to automatic recovery without this evidence.

### GATE-2: real offline restoration — current state (2026-10-21)

**OPEN / NOT_VERIFIED.** Android fingerprint, SELinux, root context and real nonempty WAL/SHM sidecars have been recorded via Devtool. The pre-existing `offline_restore` is not safe to qualify yet: sidecars are deleted before DB swap. New `early-boot-lab` models nine checkpointed WAL-family transactions, but is intentionally not called by `post-fs-data.sh`. See `docs/EARLY_BOOT_REAL_DEVICE_GATE.md` for actual disposable-device acceptance obligations. Keep `RECOVERY_DEVICE_QUALIFIED=0` and automatic recovery OFF; live module quarantine/rollback was separately demonstrated PASS for `eu.hxreborn.remembermysort`.

## Current hardware boot-stage ordering verification (opt-in, device NOT qualified)
- [x] Real Vector manual quarantine/rollback on `eu.hxreborn.remembermysort`: 20/20 before-and-after inventory identical; no pending transaction, two ledger records. 2026-10-21 device evidence.
- [x] Recovery v4 manually staged and SHA-256 verified (`backup_integrity=PASS`) at `/data/local/tmp/guardian-rescue`, and user confirmed read-only access from custom recovery. Rescue path is independent from Guardian's old restore code.
- [x] 9/9 isolated WAL prototype scenarios PASS on Termux. Still host filesystem simulation, not early-boot qualification.
- [x] Add a one-shot, **read-only** `post-fs-data` ordering probe with next-boot receipt and post-stability Vector observation. New commands: `boot-probe-stage --apply`, `boot-probe-status`, Devtool `boot-order-stage` / `boot-order-status`. Does not alter the DB or authorize restore.
- [ ] Observe actual KernelSU hook before Vector DB opens on this specific phone after upgrading installed Guardian and requesting the probe.
- [ ] Implement and validate production WAL-aware rollback code under an explicit one-time offline transaction; no automatic restore on daily phone.
- [ ] Fault-inject real Android interruption during early-boot restore and validate custom recovery rescue from independent backup. Record SELinux context, daemon ordering, module scope persistence and device health.
- [ ] Only after accepted evidence revisit `RECOVERY_DEVICE_QUALIFIED`; do not enable automatic quarantine/recovery by proxy.


## v0.9.2 — copy-only real boot rehearsal + test-speed optimization

- [x] v0.9.1 boot-order probe PASSED on real Rosemary: early observed before vectord PID, later Vector healthy (not proof of exclusive access).
- [x] Real RememberMySort Vector quarantine/rollback passed with identical 20-module inventory and 2 ledger entries.
- [x] Add opt-in copy-only WAL rehearsal in real post-fs-data environment with nine hermetic safety checks, no live DB replacement (real hardware run pending).
- [x] Optimize mock Python startup without dropping, caching or combining isolated GuardianTests cases; host suite 69/69 in 13.67 sec.
- [ ] Real hardware copy-only rehearsal + healthy-boot receipt.
- [ ] Genuine offline full-family restoration, SELinux/startup exclusivity and injected interruption test; unqualified until then.

## v0.9.3 real restore acceptance (2026-10-25)
- [x] Real single-module reversible Vector quarantine; exact original inventory restored (device operator receipt)
- [x] Real pre-daemon boot-order observation and post-boot Vector response (v0.9.2)
- [x] Real `post-fs-data` copy-only WAL transaction rehearsal with unchanged live DB main-file SHA-256 (v0.9.2)
- [x] SHA-256 verified custom-recovery rescue and refreshed 9-module candidate; previous verified backup archived
- [x] Source implementation of manually staged and one-shot journaled live DB swap, offline undo script and isolated host fixtures (v0.9.3; **device acceptance pending**)
- [ ] Run full native-Termux Devtool `check` and install v0.9.3; verify preflight on actual device
- [ ] Perform user-approved one-shot **real Vector database** restoration during actual hardware boot with healthy Vector and unchanged expected module enablement afterward
- [ ] Validate custom recovery offline undo of retained original family, SELinux labels and sidecars
- [ ] Exclude races with early Vector DB access via stronger framework startup coordination, and establish power-interruption recovery evidence
- [ ] Device automatic recovery qualification remains 0; automatic quarantine remains disabled

## v0.9.4 — acceptance consolidation (source prepared 2026-10-27)

Evidence received from the owner's **actual Android 13 / Vector 3112** environment (operator-provided receipts; not independently reproduced by hosted CI):

- [x] `PASS_GUARDIAN_LIVE_VECTOR_QUARANTINE_ROUNDTRIP` on `eu.hxreborn.remembermysort`. Twenty-module enabled/disabled inventory identical before/after; event ledger `QUARANTINED` then `ROLLED_BACK`; zero pending quarantines.
- [x] `PASS_GUARDIAN_BOOT_ORDER_OBSERVED` from one real post-fs-data run with `boot_completed=0`, no `vectord` PID, followed by `VECTOR_RESPONDING`. **Does not establish exclusive DB locks.**
- [x] `PASS_GUARDIAN_REAL_BOOT_COPY_ONLY_TRIAL`: isolated WAL transaction during a real boot; live main DB unchanged and Vector responded later. Metadata fields `boot_completed=unknown` and `context=Oct` are explicitly NOT qualified as boot or SELinux evidence.
- [x] `PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE`, boot ID `dc83413b-5588-4dff-9c34-905f83767399`: actual main DB SHA-256 changed from `f0b5ddc885183ac46e5c7dfbcbeb609ff7e31d21ac48b1721d916d72f1163c1a` to rescue source `2f90f4d986d2e0874a67a81e1953720af08d1b0913823b327f8a8ccb20827e3c`. Post-boot `health=PASS`, Vector 3112 responding, exact 12 enabled modules matched, receipt reports original DB family retained. Verified independent rescue backup remained `backup_integrity=PASS`.
- [x] v0.9.4 source adds `one-shot-finalize`: checks matching early/stable receipts, payload digest, preserved DB/WAL/SHM/journal checksums, and *current* healthy Vector enabled manifest before atomically sealing the transaction phase `HEALTH_CONFIRMED`; supports prior v0.9.3 `COMMITTED_PENDING_HEALTH` without re-running a swap. Automatic recovery remains disabled.
- [x] Read-only `qualification` distinguishes specific on-device historical acceptance evidence from overall `device_restore_qualification=UNQUALIFIED`; quarantine ledger pairs are reported as *historical ledger evidence*, not independent attestation.
- [x] `crash-audit` provides current file identity and count without guessing the cause of the reported retained event drop from 73 to 8. The 400-record retention cap alone does not explain a drop of this size; old raw history is not present in the provided diagnostic evidence. No evidence recovery is claimed.
- [ ] Confirm v0.9.4 installed-device finalization and persisted `HEALTH_CONFIRMED` evidence with no new swap or reboot test.
- [ ] Investigate crash-history file transitions using real on-device snapshots/logs/backups. `retained_events=8` alone is not proof of records being lost, deleted, or trimmed.
- [ ] Run an offline custom recovery **undo** test of the retained original SQLite family (not the same as backup `status` PASS); only when separately authorized and with rescue path ready.
- [ ] Qualify real interrupted-boot/power-loss behavior and startup exclusivity. A successful one-shot does not certify every failure boundary.
- [ ] Automatic restore/quarantine still disabled; pinned `unknown_legacy` baseline remains `legacy_header_only`, and `RECOVERY_DEVICE_QUALIFIED=0`. No auto-promotion or arming.

## v0.9.5 consolidated hardening — pending native-Termux acceptance (2026-10-28)

- [x] **Source-bound build, not an installed hotfix.** The v0.9.4 repository source was reconstructed from the original Devtool R2 package and all seven chronological overlay hash transitions, with zero mismatched inputs. No user device state was imported into the source tree.
- [x] **KernelSU installation activation parity.** `tools/runtime_parity.py`, fixed root digest helper, `devtoolw runtime-parity`: compare active module under `/data/adb/modules/lsposed_guardian` and pending `/data/adb/modules_update/lsposed_guardian` against eight canonical source files. Distinguish `ACTIVE_MATCH`, `STAGED_PENDING_REBOOT`, and unexpected drift. Never repair installed files automatically.
- [x] **Install and read-only device acceptance.** `devtoolw install` records crash/restoration metadata before and after the KernelSU installer, then verifies active/staged hashes; `devtoolw device-check` includes parity and a machine-readable manual acceptance export. No boot script mutates Vector or changes the recovery gate for this work.
- [x] **Forward-looking crash continuity.** Root-only `continuity.tsv` records every *changed* crash-file hash/count at the existing merge lock, and a boot checkpoint detects a change since the last checkpoint. Crash-audit reports `UNTRACKED_CHANGE` or an untracked-boot record without claiming a cause; earlier loss from 73 to 8/9 cannot be retroactively explained.
- [x] **Manual qualification evidence.** `tools/acceptance_export.py` writes a local file with source digests, hashes of on-device receipt outputs, and historical manual success flags, while hard-setting `overall_automatic_recovery_qualified=false` and explicitly leaving power-loss/SQLite exclusivity/offline undo unverified. This is a snapshot of root-readable evidence, not trusted remote attestation.
- [x] **Regression + CI parity.** A new isolated parity/continuity test job is mandatory in Devtool `test`/`check`/`install` and GitHub CI/release-candidate mirror. No live tests enter default checks.
- [ ] **Native Termux acceptance:** Apply v0.9.5 source-checked update, pass all `devtoolw check`, install interactively, reboot, confirm `runtime-parity=ACTIVE_MATCH` and new continuity/evidence output.
- [ ] **Remaining real safety gates:** independent custom-recovery offline undo and injected interruption + exclusive DB startup access, explicitly not qualified by a successful manual one-shot.
- [ ] **Production automatic recovery:** continue disabled; `RECOVERY_DEVICE_QUALIFIED=0`, pinned legacy baseline unchanged, `com.openai.chatgpt` excluded.


## Guardian v0.10.0 personal automation consolidation (2026-10-28)
Source-bound v0.9.4 -> v0.10.0 integrates v0.9.5 staged/active KernelSU parity and crash-continuity receipts, explicit allowlist auto quarantine with reversible journal, and optional non-SQLite bootloop safe mode. Old unjournaled `offline_restore()` is permanently retired; automatic SQLite restoration is not qualified or enabled. See `docs/PERSONAL_AUTOMATION.md`. Open evidence: real Android opt-in behavior, offline undo in custom recovery, startup-race/power-loss interruption. Status: host implementation; native device acceptance pending.

## Guardian v0.11.0 — Automatic personal protection (2026-10-29)

- [x] Single `automatic-on --apply` switch: no per-module allowlist, with only
  one uniquely matched enabled/scoped Vector module eligible for a journaled
  quarantine; `automatic-off` disarms both engines.
- [x] Root-only policy validation, crash/scope checks, protected package list,
  same-boot/recency constraints, cooldown, one attempt per boot, ledger + undo.
- [x] Bounded 3-attempt watchdog for incomplete boot / 3 SystemUI strikes;
  single safe-mode disable marker for Vector; no SQLite family modification.
- [x] Do not compete with an installed AshReXcue on platform bootloop control.
- [x] Legacy unsafe unattended SQLite replacement remains retired.
- [x] Host fixtures: automatic-on/off, single-candidate response, protected apps,
  legacy flag refusal; full fake-Vector and Devtool contract gates.
- [ ] Native v0.11.0 installed runtime automatic behavior after first enable.
- [ ] Real bootloop/safe-mode response on disposable device (intentionally not
  forced on the personal daily driver).
- [ ] Exclusive Vector DB access and interruption-safe automated restore.

## v0.12.0 consolidated KernelSU WebUI (host acceptance)
- [x] New responsive overview with distinct boot, crash collector, scope sampler, automatic crash protection and safe mode status.
- [x] Persistent five-item navigation; full module inventory, search/filter, compact scope-detail panels without direct toggle side effects.
- [x] Activity timeline for explicit quarantine and newly observed configuration differences; past snapshots are **observations**, not exact module toggle times.
- [x] Reader-friendly reviewer and expandable technical qualification/integrity/boot diagnostics; copyable redacted diagnostic report.
- [x] Explicit KernelSU-confirmed guarded `automatic-on/off` and `safe-mode-arm/disarm` UI with direct CLI readback; no direct Vector DB write commands in WebUI.
- [x] Bounded sampler failure-class and module-ID diagnostic with read-only retry; invalid/partial checkpoints remain rejected.
- [x] Host WebUI bridge, deliberate action, timeline, scope filtering and failure-mode tests; current backend fake-Vector regression.
- [ ] Confirm v0.12.0 active WebUI in KernelSU after normal module update/reboot and collect UI screenshots.
- [ ] Determine and fix exact historical sampler error on device from `history-health` output: v0.11 showed `last-result=error` but no cause. New diagnostics classify error; the cause must not be invented.
- [ ] Implement platform notification delivery (not offered by v0.12). Current in-WebUI action feedback works only while UI is open.
- [ ] Unattended DB restore remains permanently disabled pending offline redo safety; automatic early-boot behavior not qualified by UI tests.

## v0.12.1 audited WebUI correction (2026-10-30)

- [x] Verify v0.12.0 overlay source hashes against v0.11.0 snapshot and inspect live root-backed functions, not UI presence only.
- [x] Correct policy-health readback, partial-failure behavior, per-subsystem monitoring and manual/background sampler differentiation.
- [x] Add real root-backed cooldown/exclusion controls with immutable exclusions and host tests.
- [x] Show checksum-verified per-module scope observations, detailed process-review evidence, typed quarantine ledger, and a trustworthy 2-snapshot change summary.
- [x] Add optional, noncritical Android notification transport and user-invoked test; preserve receipts on transport failures.
- [ ] Verify v0.12.1 after KernelSU installation / reboot on real Android, then capture actual WebUI callback and notification-delivery evidence.
- [ ] Diagnose actual Vector-scope sampler failure using on-device `history-health`, `scope-structured`, and Vector JSON for the failing module.
- [ ] Test real unattended quarantine/rollback and early-boot watchdog on a disposable device with independent recovery, without qualifying unattended SQLite restore.
- [ ] Obtain actual recovery-trigger incident receipt, proof of rollback and on-device notification delivery before marking fully complete.

See `docs/WEBUI_V012_AUDIT.md` for a promise-by-promise status table. This correction is source-bound and does not arm automatic actions during an upgrade.


## v0.12.2 post-boot soft-lock protection (2026-10-30)

- [x] Retain previous root-based v0.12.1 WebUI, Vector, and quarantine changes; introduce post-boot softlock detection before clearing healthy-boot pending state.
- [x] Bound WindowManager read-only polling and require persistent explicit TYPE_BOOT_PROGRESS visibility; never infer from credential lock state.
- [x] Distinguish `clear`, `confirmed`, and `unverified` observations with current boot receipts.
- [x] Add an independently armed bounded Vector marker-and-reboot rescue with post-write verification and one-shot latch; preserve AshReXcue ownership.
- [x] Add emergency disarm, WebUI status, root-backed policy actions independent of crash/sampler health, and event receipts.
- [x] Add host-unit tests, syntax and Devtool-compatibility checks and source-hash-bound overlay.
- [ ] Run real-device ROM compatibility check (`softlock-probe`) and collect an actual stuck-screen event.
- [ ] Qualify unattended Vector disable / rescue reboot on a disposable test device and confirm recovery from the correct window class.
- [ ] Consider OEM-specific loading screens only with verified independent evidence; do not use locked-user state alone.

Details: [SOFTLOCK_V0122.md](SOFTLOCK_V0122.md).

## v0.12.3 packaging integrity hotfix (2026-10-30)

- [x] Confirm user-reported WebUI failure is an omitted runtime shell library, not a Vector policy or ROM issue.
- [x] Include `lib/softlock.sh` in the installable KernelSU archive and checksum manifest.
- [x] Enforce static `$MODDIR/lib/*.sh` dependency closure in source preflight, package creation and archive verification.
- [x] Extend installed/staged runtime parity and tests for missing `lib/softlock.sh`.
- [x] Replay exact source-bound v0.12.2 to v0.12.3 overlay, verify built ZIP and reject duplicate patching.
- [ ] Verify on-device staged archive after `devtoolw install`; reboot and verify active service + WebUI can refresh.
- [ ] Verify real post-boot soft-lock detection/recovery separately; host packaging success does not qualify rescue behavior.

See [PACKAGING_HOTFIX_V0123.md](DEVTOOL_INTEGRATION_IMPROVEMENTS.md).

## v0.12.4 — selective soft-lock and forward-compatible Vector adapter

- [x] Distinguish `TYPE_BOOT_PROGRESS` from FallbackHome plus independently corroborated keyguard/process-start failure.
- [x] Never classify a legitimate locked user / ambiguous FallbackHome as a failed conventional boot.
- [x] Require one explicitly preapproved Xposed module, Guardian's journaled quarantine, one latched framework restart, and independent post-restart receipts.
- [x] Make selective rescue opt-in and independent of full-reboot fallback.
- [x] Bound Vector daemon calls; fail closed on incompatible CLI JSON without blanket version ceilings.
- [x] Introduce an optional manual-only, verified SQLite snapshot vault with same-day uniqueness and retention.
- [x] Keep offline Vector database restoration version-pinned and unqualified on future builds.
- [ ] Qualify real-device Zygote restart, KeyguardService signals, RescueParty interactions, module rollback, and OEM variants.
- [ ] Qualify an offline manual restore path for the vault before adding any restore action.
- [x] Deliver source-bound native Devtool executable-overlay v2 PYZ on a clean feature branch; PR HEAD/CI qualification remains open.

[Detailed contract](ROADMAP.md).

### Audited v0.12.4 follow-up boundaries

The same consolidated v0.12.4 handoff corrects false successful-boot receipts,
logcat event freshness, guarded restart verification and manual snapshot
management. Host-only successes do not qualify live Vector database restore,
Android input readiness, Zygote/RescueParty behavior, or KernelSU module
installation. Those remain explicit device acceptance items rather than
version-specific mandatory gates.

---

## Appendix: v0.12.4 selective recovery, compatibility, and backup-vault detailed contract

# Guardian v0.12.4 — selective post-boot recovery, Vector compatibility, and manual vault

This milestone is **host-tested source only** until installed and qualified on
an Android device. It does not arm automatic recovery, trigger a Zygote restart,
install a KernelSU module, or modify any Vector database during packaging.

## Post-boot classification

Guardian retains the positive `TYPE_BOOT_PROGRESS` detector and additionally
inspects the *currently resumed* Android FallbackHome activity. FallbackHome by
itself is expected during some legitimate pre-unlock states. It is **never**
automatic recovery evidence. Guardian requires persistent FallbackHome plus
independent KeyguardService-death evidence or timeouts involving at least two
critical process names, observed across a full configurable grace period.

`softlock-session-probe` reports `boot_progress`, `fallback_keyguard_failure`,
`fallback_process_start_storm`, `fallback_unverified`, `clear`, or `unverified`.
`clear` means these specific signs were not seen, **not** that the UI was tested
with user input. The detector is a boot-window observer, not a continuous
interactive touch or lockscreen health test. ROM-specific layouts/log formats
can produce `unverified`; automatic actions fail closed.

An ambiguous FallbackHome leaves the UI receipt unverified, but clears the
conventional bootloop pending marker as a **process-stable** result. Otherwise,
legitimate first-unlock waits could accumulate failed-boot counts and trigger
an inappropriate future safe-mode marker. It neither promotes a known-good
snapshot nor claims a usable interface.

## Selective quarantine → one framework restart

This is a **separate opt-in**. Automatic attribution is intentionally not
implemented: a historical scope match cannot prove which hook caused a
soft lock. The operator explicitly preapproves one module package while the
phone is healthy. Only a later confirmed, sustained soft lock is eligible.

```sh
G=/data/adb/modules/lsposed_guardian/guardian.sh
su -c "$G vector-capabilities"
su -c "$G softlock-session-probe"
su -c "$G softlock-suspect org.example.module --apply"
su -c "$G softlock-selective-on --apply"
su -c "$G softlock-status"
# Disarm whenever desired:
su -c "$G softlock-selective-off"
```

Arming requires a known healthy kernel boot, a responsive Vector daemon, an
installed and enabled preapproved module, a parseable inventory, an available
primary Zygote service, no pending database restore, and no past selective
attempt latch. No module or process is changed during arming.

When triggered, Guardian journals an attempt *before* mutation, reuses the
existing journaled `quarantine PACKAGE --apply` operation, verifies an active
quarantine receipt, and issues at most one root `ctl.restart zygote` command.
This is a framework restart, **not** Android 15+'s deprecated userspace
reboot. It terminates apps and `system_server`; Android/KernelSU/ROM behavior
varies. The observer checks for a changed `system_server` PID and two separate
clear session observations. Even success means only
`ui_signals_clear_not_device_certified`, not a physically verified lockscreen.
The attempt latch survives interruption; no automatic retry, reverse toggle,
SQLite restore, or unapproved kernel reboot follows a failure.

Vector itself has a soft-reboot implementation using `ctl.restart zygote` and
special protection against Android RescueParty counting deliberate restarts.
Guardian deliberately does **not** alter RescueParty counters: that requires
separate device-specific approval. Test on a recoverable device before arming.

Guardian's preexisting full KernelSU Vector-disable fallback is independent.
The selective-on command does **not** silently arm that fallback or its reboot
watchdog. If the operator previously armed them, their normal policy remains
unchanged. Disarming selective rescue preserves all quarantine/incident
journals; it does not automatically reenable disabled modules.

## Future Vector versions

`vector-capabilities` performs a read-only per-device compatibility probe.
New `versionCode` values are not rejected merely for being newer. The gate
checks the exact `zygisk_vector` module identity, a reachable daemon, a
bounded CLI call, and the currently supported JSON inventory contract
(`success`, a `data` array, `PACKAGE`, `STATUS`). An unknown schema or
unreachable CLI permits diagnostics but blocks module toggles. The actual
toggle transaction must still verify that **only** the selected module changed.

Consistent backups are verified per snapshot with Vector's `db backup` and
SQLite integrity/schema checks. **Live/offline database replacement retains
its separately qualified exact 3112 version restriction.** No future version
can inherit permission for a raw DB swap simply because its CLI looks similar.
New CLI/schema variants must be explicitly implemented and tested.

## Optional manual backup vault

The vault is disabled until `backup-enable --apply`. It captures Vector's
consistent SQLite backup plus a verified enabled-module manifest and metadata,
with SHA-256 verification, a monotonic same-second sequence, and latest-five
verified-snapshot retention. It uses Guardian's private root state, not
`/data/local/tmp`, and does not install or remove schedulers.

```sh
su -c "$G backup-enable --apply"
su -c "$G backup create --apply"
su -c "$G backup list"
su -c "$G backup inspect snap-YYYYMMDD_HHMMSS_NNNNNN"
su -c "$G backup verify snap-YYYYMMDD_HHMMSS_NNNNNN"
su -c "$G backup-disable"
```

Snapshot creation requires a stable boot, a responsive compatible Vector CLI,
and a local SQLite integrity verifier. If these are unavailable, no raw WAL
copy is silently substituted. `backup restore ID` is a documented refusal:
restoring a live SQLite DB while Vector may hold it open is unsafe. The vault
currently backs up the **Vector SQLite configuration database**, not every
non-DB config file. A separately qualified offline restore is required before
adding actual restoration. No automatic restoration is implemented.

## Evidence and release boundaries

- Host: repository syntax/manifest, deterministic ZIP/hash validation, targeted
  boot/softlock/compatibility/vault/quarantine/one-shot/WebUI regressions.
- NOT tested: live `setprop ctl.restart zygote`, real Vector hooks, keyboard or
  lockscreen recovery, RescueParty behavior, real KernelSU module installs,
  device rollback or boot-health confirmation.
- Native Devtool launcher, native overlay application, committed HEAD/branch,
  PR and hosted CI require an exact-source runtime on the operator's Termux
  device. Host-only tests do **not** replace those requirements.

Sources studied:
- https://github.com/JingMatrix/Vector/blob/master/daemon/src/main/kotlin/org/matrix/vector/daemon/VectorDaemon.kt
- https://github.com/JingMatrix/Vector/blob/master/daemon/src/main/kotlin/org/matrix/vector/daemon/Cli.kt
- https://github.com/JingMatrix/Vector/blob/master/zygisk/README.md
- https://android.googlesource.com/platform/frameworks/base/

## v0.12.4 audited correction — current handoff

This corrected handoff supersedes the earlier v0.12.4 inputs **before any
native application**. It does not change the preimage: v0.12.3 source produced
by the supplied Oct 30 snapshot and the v0.12.1–v0.12.3 source overlays.

- `FallbackHome` fault corroboration uses **time-bounded epoch-formatted logcat**.
  Old events, missing timestamps and unavailable `dumpsys` remain unverified;
  none authorize automatic quarantine. The normal boot observation lasts the
  full grace window (rather than stopping after two early clear samples). A
  late-onset fault may be observed for up to twice that window so it still
  needs sustained evidence. A parseable resumed HOME activity is required for
  a clear result; an empty ActivityManager dump is not a healthy interface.
- A process-stable but UI-unverified boot receives a **separate process receipt**.
  It clears early bootloop accounting, withholds `last-success-id`, does not
  promote the pinned recovery baseline, and can start read-only collectors.
  This avoids treating a normal locked phone or unsupported OEM UI as an early
  boot failure without pretending the interface was verified.
- A successful `setprop ctl.restart zygote` merely records that a request was
  sent. Independent evidence must show a changed `system_server` PID and two
  clear activity/window observations; otherwise the result stays unverified.
  `softlock-verify` is strictly read-only and can never manufacture success.
- The snapshot vault stores a consistent Vector SQLite backup and a bounded
  tarball containing other *regular* configuration files (excluding the live
  database and WAL/SHM/journal). Additional configuration-file consistency is
  NOT certified. Symlinks, special files, unsafe names and unbounded extra
  files refuse capture. SHA-256 covers archive, DB, enabled list and metadata.
- Backup operations now include `backup menu`, `tools`, `modules ID`,
  `compare ID ID`, `limit N --apply` (1–20), and WebUI inspection/comparison.
  The terminal uses a numbered fallback. Recursive fzf/bat discovery is
  informational; root execution requires an operator-provided path and exact
  SHA-256 via `GUARDIAN_BACKUP_FZF`, `GUARDIAN_BACKUP_FZF_SHA256`, or the BAT
  counterparts, and a suitable static ARM64 ELF. There is no scheduler.
- `backup restore ID` remains a **verified, read-only refusal**. No live SQLite
  restore, offline swap, forced reboot or recovery-mode write is enabled by
  this handoff. A future separately qualified, device-specific offline
  restore transaction is required for actual activation; it cannot be
  validated by host fixtures alone.

Host tests can prove refusal and simulated behavior only. They cannot prove
that actual Keyguard/UI input became available, that a Zygote restart is safe
on this ROM, or that a root manager handles the process lifecycle correctly.

---

## v0.12.4 native job-metadata qualification

Devtool v3.2 rejects a job marked `read_only=true` while declaring outputs. Guardian has two receipt-generating jobs: `host-qualification` and `early-boot-model`; these write files under `dist/` and therefore must declare `read_only=false`, while retaining their host-only and device-unqualified metadata. All genuinely read-only jobs remain read-only. The job output paths and the original safety/CI checks are preserved.

Resolved on the source-bound feature branch: commit `7efd46b756862c97be078960db9774ddcdd79287` changes only `.devtool.toml` to mark both receipt-producing jobs as writable. The v0.12.4 delivery overlay excludes this already committed file and targets the new HEAD/tree. Native Devtool still validates the committed configuration and all scoped outputs; no gate is bypassed. The separate v0.12.4 implementation has not been applied by this handoff and requires native check and atomic apply.

### Full GUARD-DT-022 packaging incident record

## GUARD-DT-022 — v0.12.2 installer silently omitted required `lib/softlock.sh` (v0.12.3)

- **Evidence:** Android KernelSU WebUI displayed `guardian.sh[16]: .: /data/adb/modules/lsposed_guardian/lib/softlock.sh: No such file or directory`; user-visible automatic protection reported unavailable. Audit of `tools/build.py` found `lib/softlock.sh` present in source but absent from the installable ZIP whitelist; `tools/runtime_parity.py` and root probe also omitted it.
- **Affected:** Guardian CLI and boot monitor initialization, install ZIP builder/validator, runtime parity, tests, module version.
- **Fix:** v0.12.3 adds the missing runtime library to the install ZIP; fails preflight, build and ZIP verification if a statically sourced `$MODDIR/lib/*.sh` dependency is absent; includes the library in active/staged parity checks; adds negative install and parity fixtures. Source overlay is exact v0.12.2 hash-bound.
- **Status:** HOST VERIFIED (source tests, actual archive contents, replay and duplicate refusal); **OPEN** device installation, post-reboot active parity, boot monitor acceptance and real unattended soft-lock recovery. A directly copied library can restore CLI availability temporarily but does not repair the builder, earlier boot-service exit or the staged package.
- **Devtool improvement:** maintain a repo-agnostic deployable runtime-dependency closure check in Devtool's packaging/installation abstractions rather than relying only on target-specific tests. Consider detecting sourced shell libraries missing from root module release archives.

---

## Appendix: v0.12.3 packaging incident and verification record

# Guardian v0.12.3 — packaging hotfix (2026-10-30)

## Incident

The v0.12.2 repository added `lib/softlock.sh` and sourced it unconditionally from
`guardian.sh` and `service.sh`. `tools/build.py` maintained a separate manual
`INSTALL` list that omitted `lib/softlock.sh`. KernelSU therefore successfully
installed an archive missing the required runtime file. Guardian commands failed
and the boot service exited before protection checks. `runtime_parity.py` and its
root probe omitted the same file and could miss the discrepancy.

## Repair

- Include `lib/softlock.sh` in the installable archive and hashes manifest.
- Fail the source preflight, builder and ZIP verification if any static
  `$MODDIR/lib/*.sh` source dependency is missing from the installable files.
- Include `lib/softlock.sh` in both staged and active runtime parity inventories.
- Test missing active and staged softlock files, and assert all runtime imports
  are present in the actual install archive.
- Bump module version to v0.12.3; no user policies or database files changed.

## Acceptance criteria

Before device install, inspect `dist/LSPosed-Guardian-v0.12.3.zip` and verify
both `lib/softlock.sh` and `FILE_SHA256SUMS.txt` list the library. A successful
`./devtoolw install` should then stage the corrected package. If KernelSU
stages the update, the active version may remain broken until reboot. Confirm
staged parity before reboot and active parity after reboot.

The old historical sampler issue and full real-device softlock recovery
acceptance are not closed by this packaging fix.

### v0.12.4 host WAL model — CI regression follow-up (2026-11-18)

- Hosted PR #1 initially failed `test_early_boot_lab_is_hermetic_and_device_gates_remain_open`
  at the `retired-journal` checkpoint. SQLite opening even a `SELECT` on a
  WAL-backed fixture can rewrite its SHM sidecar, invalidating a later raw
  file-hash comparison performed by that same test.
- The isolated lab now queries only a detached disposable copy of the DB, WAL
  and SHM family. It verifies the restored *original* bytes against source
  hashes **before** the copy-only read and tests exact byte preservation,
  repeatable rollback, and refusal of tampered WAL/SHM backups.
- The production code, CI gates, and device qualification policy are unchanged.
  Host-only regression success does **not** qualify on-device WAL restore,
  actual early-boot interruption, SELinux context, or a production release.
- Required acceptance: native Devtool exact-tree validate/check/apply/commit
  against the current PR branch, then verify the new PR HEAD and complete
  hosted checks. Do not rerun an already committed overlay.
