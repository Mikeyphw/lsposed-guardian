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
