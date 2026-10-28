# Devtool integration — cumulative improvements ledger

This is an append-only, evidence-oriented list of Devtool enhancements identified while adapting Guardian. The recommendations are **not** claims of defects until reproduced independently in the Devtool repo. Keep them tracked until the owning Devtool backlog incorporates them.

| ID | Status | Affected layer | Concrete evidence | Improvement / acceptance criterion |
| --- | --- | --- | --- | --- |
| GUARD-DT-001 | OPEN / WORKAROUND ACTIVE | Canonical command runner, Termux install UX | The 2026-10-21 snapshot's `devtool/runners.py::_run_process_live()` launches `subprocess.Popen(..., stdout=PIPE, stderr=STDOUT, start_new_session=True)`; Guardian's KernelSU module installer may require a controlling terminal. | Add a first-class job `terminal="pty"`/`interactive=true` capability that allocates a child PTY while preserving progress events, cancellation, output filtering and terminal input. Guardian currently wraps only the explicit `install` job in `tools/pty_install.py`. Qualify volume-key and terminal-driven installers on physical Termux/KSU. |
| GUARD-DT-002 | OPEN / DESIGN ENHANCEMENT | Wrapper schema 2 canonical binding choices | Devtool wrapper rejected `wrapper.commands.preflight.devtool="preflight"` during real parser validation; allowed native wrapper commands are build, clean, lint, package, restore, run, test, validate, wine-validate. | Consider adding read-only `preflight` and `doctor` native wrapper bindings; currently represented as workflow jobs invoking canonical Devtool, adding unnecessary nested workflow entry. |
| GUARD-DT-003 | OPEN / DOCUMENTATION | Preflight environment provenance | Preflight against a Linux desktop correctly marks target `execution_environment="native-termux"` incompatible. Typed jobs and wrapper final seal nevertheless validate. | Provide an explicit `preflight --contract-only` or `--destination-future` contract-check mode for an off-device maintainer that reports tool availability as deferred without representing a desktop host as a Termux device. |
| GUARD-DT-004 | PROVISIONALLY CLOSED / VERIFY ON DEVICE | Native shell/Termux workflows | Guardian uses target-local command jobs with explicit DAG dependencies, read/write inputs/outputs, and first-class tests. Devtool snapshot passed wrapper `describe`, `init`, `resolve install`, and `seal` on the host. | On actual Termux, run `./devtoolw preflight`, `./devtoolw doctor`, `./devtoolw check`, and an explicitly requested `./devtoolw install` to validate evidence records, including PTY foreground interaction, before closing fully. |

**Maintainer policy:** When a new Devtool limitation/architecture issue is discovered, append concrete evidence, affected code/project, recommended change, and qualification status here. Do not silently count test assertions or a file's mere presence as implementation proof.
| GUARD-DT-005 | OPEN / HOSTED FALLBACK VERIFIED BY CONTRACT | GitHub Actions versus Devtool DAG | Guardian's initial GitHub Actions ran each host command independently while the on-device wrapper used a typed Devtool workflow. Host CI cannot assume the user's local Devtool snapshot is available as an installable public package. | Retain the canonical local Devtool DAG, add `ci-parity` job checking source commands and order in both hosted workflows, and publish PASS_HOST_ONLY evidence. Switch hosted runners to direct Devtool orchestration when a reproducible, pinned runtime artifact with trustworthy provenance is available. |
| GUARD-DT-006 | REMEDIATED IN GUARDIAN; DEVTOOL ENHANCEMENT OPEN | Root module install chain | Original Guardian `install` workflow had `source-check -> package -> verify -> flash`, omitting unit/contract/WebUI regressions even though `check` contained them. | Revised `install` graph requires source, all test jobs, CI parity and evidence qualification before packaging, digest verification and interactive `ksud` handoff. Suggest Devtool support for named reusable workflow subgraphs to avoid duplicated checks in build/install/check. |
| GUARD-DT-007 | OPEN / EVIDENCE GATE ADDED | Test evidence identity and qualification | A PASS marker and positive count alone can mask renamed, skipped, stale or duplicated test results. | Added `tools/qualify_host.py` enforcing exact GuardianTests discovery equality, all statuses PASS, and non-stale test file; root-device qualification remains explicitly false. Native Devtool could expose a reusable exact-test-inventory evidence policy. |
| GUARD-DT-008 | OPEN / WORKAROUND IN GUARDIAN | Native device qualification evidence and intentional mutating test jobs | Host-only DAG gates can be green while actual live Vector quarantine and early-boot restoration remain unqualified. A live gate must not inherit hosted CI's `PASS` as device safety. | Introduce typed, opt-in device-evidence gates with clearly separated proof subjects (live Vector toggle vs hooks in spawned processes vs early-boot restore), freshness/source/boot identity and fail-closed promotion semantics. Guardian adds opt-in `live-quarantine-preview`, `live-quarantine-gate`, and read-only `early-boot-preflight` jobs; none are in default/CI DAGs. |


## LIVE-GATE-ROOT-01 — Unprivileged stat rejects root-installed Guardian (fixed)

- **Evidence:** 2026-10-21 on-device `./devtoolw live-quarantine-preview` returned `FAIL_GUARDIAN_LIVE_GATE: Installed Guardian executable is missing` despite prior successful `su -c /data/adb/modules/lsposed_guardian/guardian.sh doctor` and Guardian v0.9 running. No Vector mutation occurred.
- **Root cause:** `tools/live_quarantine_gate.py` used `Path(GUARDIAN).exists()` in Termux user context before `su`; permissions on `/data/adb/modules` make that a false-negative check.
- **Affected:** Guardian Devtool live gate's preview/apply preflight; not Guardian runtime or its already-passing isolated tests.
- **Remediation:** Replace unprivileged `stat()` with root-executed Guardian CLI `help` probe; validate CLI identity and fail closed if unavailable. Add deterministic host regression prohibiting `Path.exists` and checking root-probe failure path.
- **Status:** Fixed in source-bound live-gate repair; **Android verification pending**. Actual live quarantine and rollback remain NOT_VERIFIED.

## EARLY-BOOT-01 — WAL-family restoration interruption gap (2026-10-21)
- **Evidence:** real-device preflight, POCO rosemary, SELinux Enforcing, `/data/adb/lspd/config/modules_config.db-wal` 214272 bytes and `-shm` 32768 bytes. Guardian v0.9 `lib/common.sh:offline_restore` deletes sidecars before DB replacement; no on-disk transaction journal/reconciliation for that action.
- **Impact:** power interruption, startup race or denied rename could lose committed WAL data or leave a mismatched database family. Prior isolated `recovery-lab` is insufficient for this device claim.
- **Change:** add an explicit `early-boot-lab` Devtool workflow, nine WAL/interruption simulator checkpoints with disposable SQLite WAL fixtures; mirror the host-only job in CI and test contracts. New `docs/EARLY_BOOT_REAL_DEVICE_GATE.md` records safety dependencies.
- **Status:** `MODEL_PASS / LIVE_RESTORE_NOT_VERIFIED`. Production post-fs-data not changed. Pending real power-loss/startup-order/SELinux testing on disposable Android and independent rescue proof.


## BOOT-PROBE-01 — device boot ordering evidence and opt-in workflow (2026-10-22)
Finding: `early-boot-preflight` ran only after Android startup and cannot establish when KernelSU's `post-fs-data` occurs relative to Vector. Recommendation implemented: next-hardware-boot, read-only before-daemon probe with durable observed/stable receipts, plus separate opt-in Devtool jobs omitted from check/install/CI. A daemon PID or completed boot at hook time is a fail-closed `TOO_LATE` observation. No Vector DB modification, automatic recovery or device qualification implied. Status: IMPLEMENTED; real-hardware reboot observation PENDING.

## BOOT-PROBE-02 — Unprivileged fixture falsely fails stable receipt (fixed in replacement overlay)

- **Evidence:** 2026-10-22 Termux source-overlay validation had 1/6 failure: early receipt `assessment=EARLY_CANDIDATE` existed but `service.sh` never wrote the stable receipt, producing `BOOT_ORDER_NOT_YET_ACCEPTED`. The updater properly rolled back. Reproduced in Linux as the unprivileged `nobody` user; the exact same test passes as root.
- **Root cause:** The hermetic `tests/test_boot_probe.py` subprocess environment omitted `GUARDIAN_LOCK_DIR`; production `service.sh` defaults to `/dev/lsposed_guardian_service_lock`. An unprivileged user cannot create that global directory, so the service exits 0 before the stability-acceptance function executes.
- **Affected:** Guardian's opt-in boot-probe test fixture and source-overlay acceptance; not the real `post-fs-data` ordering. **Do not weaken `bp_status()` acceptance checks.**
- **Fix:** Give the fixture a writable temporary `GUARDIAN_LOCK_DIR`, assert the expected stable receipt is actually written and the lock cleaned up, and add a negative fixture for an impossible lock path. Confirm test success running as an unprivileged user and as root.
- **Status:** Host regression PASS; Termux device regression PENDING. No installed module or Vector files affected by failed original overlay.


## GUARD-DT-009 — Slow hermetic Python CLI fixture startup (2026-10-22)

- **Evidence:** The original 69-test fake-Vector host evidence records 1,457.77 seconds of summed test duration at two workers; a representative test took 20.23 seconds on this host. The 15-invocation sqlite3 Python startup benchmark was 11.21 seconds with site initialization versus 0.26 seconds with `-S`.
- **Root cause:** Every isolated per-test Python process and its numerous fake-Vector/SQLite Python subprocesses initialized all site packages even though they only need Python's standard library.
- **Remediation:** Dynamically generate mock CLI shebangs using the current interpreter plus `-S`; execute each test in its own fresh `python -S -m unittest ...` child process. Preserve all 69 tests, per-test timeouts, temporary Vector fixtures, stdout/stderr, source hash inventory and exact-name PASS gate. Keep original two-worker limit to avoid CPU contention on Termux.
- **Validation:** 69/69 tests PASS in 13.67 seconds with the same two workers on this host; the earlier evidence is from a different environment and is **not** a controlled before/after on the user's Termux device. Native Devtool `check` timing pending.
- **Suggested Devtool enhancement:** Report per-node critical path and startup overhead separately and surface performance bottleneck recommendations. Status: Guardian-side fix tested; Devtool ergonomics improvement open.

## v0.9.3 one-shot real-restore preparation (2026-10-25)
- **DELIVERED host-only:** explicit opt-in Devtool workflows for real boot restoration preflight, stage, status and cancel; none are called by `check`, `test`, `install` or GitHub Actions. The host fixture test is included in both full host qualification DAGs and CI mirror.
- **DELIVERED source:** manual one-shot transaction copies and verifies original SQLite family before modification, retains a root-only journal and offline undo, rechecks daemon state immediately before swap, validates recorded device-specific SELinux context and owner/mode, verifies post-boot Vector and enabled manifest, consumes the request once, never arms automatic recovery.
- **OPEN Android qualification:** actual source-bound installation, `one-shot-preflight` and device-specific SELinux/ownership compatibility; genuine live DB one-shot restore and crash/power-loss boundaries. No claim of safe exclusive access; `pidof` cannot eliminate all races.
- **OPEN device recovery:** custom-recovery invocation of the new offline undo (the existing rescue v4 backup was verified separately).
- **PERFORMANCE:** Guardian fake Vector regression remains 69 cases with `python3 -S` on hermetic mocks, no gate removal; new one-shot tests are isolated and fast.

## GUARD-DT-010 — One-shot fixture accidentally depends on host root (2026-10-26)

- **Evidence:** Termux `APPLY-TERMUX.py` v0.9.3 validation failed 4/15 `test_one_shot` cases after the Android user UID could not `chown 0:0` a disposable database and the fixture's `one-shot-offline-undo.sh` invoked real `id -u`. The source-bound updater automatically rolled the candidate back; installed v0.9.2 and live Vector were unchanged. Reproduced with exactly four failures when running the original suite as Linux `nobody`; running as root masked the problem.
- **Cause:** Unit-test mocks supplied fake `ls -Z`, `stat`, `chcon` and SQLite/Vector but did not simulate `chown` or the privileged UID check. This was **not** evidence that the actual early-boot root context had failed; production restore still unverified.
- **Remedy:** Fixture-private `id -u` and `chown` mocks provide root capability **only for isolated temporary paths**, while actual production `chown 0:0` and `id -u` guards remain intact. New negative tests assert the offline undo rejects non-root identity and a failed ownership operation refuses the swap without modifying the original DB family. Tests must pass both root and an unprivileged user.
- **Status:** FIXED in v0.9.3 replacement candidate; device/source verification pending. Devtool improvement proposed: optional per-job `run_as=unprivileged` or a target execution-identity contract for host tests to expose implicit privilege assumptions before Termux installation.

## GUARD-DT-011 — Boot-probe fixture cleanup races detached monitors (2026-10-26)

- **Evidence:** Running v0.9.3 `test_devtool_contract.py` while testing the unprivileged fix intermittently failed its nested `test_boot_probe.py` suite with `OSError: Directory not empty` during temporary fixture cleanup. The mock `service.sh` successful-boot path launched production-default crash/history collectors in the background, racing cleanup of their disposable state directory.
- **Remedy:** Set `PASSIVE_CRASH_MONITOR=0` and `HISTORY_MONITOR=0` in the **test fixture config only** (same isolation pattern already used by the one-shot tests). Preserve real `service.sh` monitor behavior. Run the nested tests repeatedly and with a non-root UID to catch regressions.
- **Status:** Fixture fix included in replacement v0.9.3 overlay; on-device source verification pending. Consider Devtool diagnostics of leaked daemon children or background processes in hermetic jobs (not yet verified as a Devtool bug).

## GUARD-DT-009 — Persist device acceptance separately from host qualification (v0.9.4)

- **Evidence:** Real one-shot boot restoration on 2026-10-27 returned post-boot `health=PASS`, yet v0.9.3 kept `transaction_phase=COMMITTED_PENDING_HEALTH`; `qualification` still printed `actual_early_boot_restore_test=NOT_VERIFIED`. This is receipt/reporting drift, **not** proof that the DB swap failed.
- **Affected:** Guardian `lib/one-shot.sh`, `lib/qualification.sh`, Devtool device acceptance/reporting model; not the full hosted-CI qualification graph.
- **Remediation:** v0.9.4 adds explicit idempotent, read-only-to-Vector receipt reconciliation `one-shot-finalize`, checks retained original DB-family SHA-256 evidence, and records `HEALTH_CONFIRMED` only on verified receipt + currently healthy enabled inventory. `qualification` shows granular historical passes but keeps full device recovery UNQUALIFIED.
- **Upstream improvement:** Devtool typed acceptance receipts with boot identity, independent health observation, artifact checksums, evidence source/freshness, historical vs current state, and nonpromotable host-only gates.
- **Status:** implemented in Guardian source and hermetic tests; live-device v0.9.4 reconciliation needs confirmation.

## GUARD-DT-010 — Crash-history count regression needs provenance telemetry

- **Evidence:** Device `doctor` showed 73 events before 2026-10-27 one-shot restoration and 8 afterward; Guardian's bounded `CRASH_MAX_EVENTS=400` does not itself account for a shrink from 73 to 8. Existing successful `crash_merge_file` tests preserve sub-limit evidence, but old file bytes weren't supplied to differentiate state loss, manual cleanup, provenance gap, or filesystem migration.
- **Affected:** Guardian `lib/crash.sh`, monitoring evidence, Devtool acceptance/debug reports.
- **Remediation:** add nonmutating `crash-audit` with current byte count, checksum, permissions, and retained count; label historical delta `UNKNOWN` until old-file evidence is provided. Suggested future enhancement: source-bound monotonic file generation/versioned snapshots, retention trim event receipts, and cross-boot digest tracking to distinguish deletion/recreation from intended truncation.
- **Status:** audit tool implemented, root-device cause still open. Do not attribute the count drop to Vector restoration without evidence.

## GUARD-DT-013 — KernelSU staged module update misdiagnosed as runtime mismatch (v0.9.5)
- **Evidence:** Operator observed `module.prop` reporting v0.9.4 while `one-shot-finalize`/`crash-audit` were unavailable. Without applying the proposed CLI hotfix, a subsequent hardware reboot activated those commands and finalized the historic restore. The previous stale-runtime conclusion was premature.
- **Root cause/status:** KernelSU ordinarily stages updates under `/data/adb/modules_update` until reboot. Stage-vs-active evidence was not collected at the time; this is the leading explanation, not a proven specific state for that older boot.
- **Fix:** read-only eight-file SHA-256 parity, explicit pending-reboot classification, fail-closed drift, Devtool `runtime-parity` and install/device-check integration, 100% fixture isolation. **Delivered in source, pending Android acceptance.** No file rewriting or hot activation.

## GUARD-DT-014 — Crash-event count declined without continuity receipts
- **Evidence:** Historical user-provided diagnostic counts 73 then 8/9, while retention cap is 400. No old file or earlier merge/rotation receipts were available to attribute cause.
- **Fix:** root-only per-change `continuity.tsv`, boot-to-boot digest comparison, upgrade pre/post count+digest snapshots. Report detected unexplained changes rather than asserting deletion or intended trimming. The existing crash sample pipeline stays observational; no auto decisions. **Delivered in source, does not recover old records or prove power-loss durability.**

## GUARD-DT-015 — Qualification reports scattered across operator logs
- **Evidence:** Real manual quarantine, boot-order, copy-only rehearsal and one-shot restoration all achieved operator-reported acceptance; overall automatic recovery remains unqualified. Prior outputs risked overstating host-device correspondence.
- **Fix:** local, source-bound machine JSON export of present on-device qualification and transaction receipt hash, root origin, no chat-crash attribution, explicit unverified power-loss/offline undo/exclusivity; integrated with `device-check` and recorded separately from hosted CI. **Delivered in source, pending on-device receipt.**

## GUARD-DT-016 — PTY negative test Python startup timeout
- **Evidence:** On the host, `test_pty_handoff_refuses_noninteractive_install` used ordinary Python startup with a 5-second subprocess deadline; the child could spend almost the whole budget importing `site` and failed under load although the installer itself rejected non-TTY input correctly.
- **Fix:** Use `sys.executable -S` for isolated Python subprocess fixtures (PTY denial, CI parity checker, archive build) and ensure realistic 15–60 second timeouts even under competing host workloads. The installer itself uses `python3 -S` for its two stdlib-only Python helpers. Does not modify the interactive production installer, root policy, or the non-TTY denial.
- **Status:** Delivered in v0.9.5; full native-Termux check still required.


## Guardian v0.10.0 personal automation consolidation (2026-10-28)
Source-bound v0.9.4 -> v0.10.0 integrates v0.9.5 staged/active KernelSU parity and crash-continuity receipts, explicit allowlist auto quarantine with reversible journal, and optional non-SQLite bootloop safe mode. Old unjournaled `offline_restore()` is permanently retired; automatic SQLite restoration is not qualified or enabled. See `docs/PERSONAL_AUTOMATION.md`. Open evidence: real Android opt-in behavior, offline undo in custom recovery, startup-race/power-loss interruption. Status: host implementation; native device acceptance pending.
