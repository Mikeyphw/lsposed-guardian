# Genuine Vector early-boot restore — gate 2 (NOT VERIFIED)

This page describes **what must be proven on a disposable/rooted Android environment**; it is not an instruction to experiment with the user's working device. Guardian v0.9.0 and its installed `post-fs-data.sh` have **not** been changed by this repository-only prototype update. The prototype is `tools/early_boot_transaction_lab.py` and cannot access the live Vector DB.

## Grounded real-device preflight (2026-10-21)

- Reported fingerprint: `POCO/rosemary_p_global/rosemary:13/TP1A.220624.014/V14.0.17.0.TFFMIXM:user/release-keys`.
- SELinux: **Enforcing**; root context `u:r:ksu:s0`.
- Vector DB: `/data/adb/lspd/config/modules_config.db`, root:root, `u:object_r:system_file:s0`, 69,632 bytes, mode 0660.
- Concurrent sidecars: `modules_config.db-wal` 214,272 bytes, `modules_config.db-shm` 32,768 bytes. These are a real risk, not disposable cache while Vector is active.
- `sandbox_restore_lab=PASS`, `sandbox_quarantine_lab=PASS`, actual restore **NOT_VERIFIED**.
- Pinned baseline `legacy_header_only` with unknown provenance; `baseline_ready=0`, `RECOVERY_DEVICE_QUALIFIED=0`, `AUTO_RECOVERY=0`. Do not promote the baseline to justify an experiment.
- The separately authorized real module disable/rollback has passed; this does not qualify database recovery.

## Why the current production restore must not be armed

The v0.9 `offline_restore` removes live sidecar paths **before** `mv` replaces the main DB, without a persistent recoverable transaction marker covering the entire database family. Any interruption may leave the old main file without its matching WAL; interrupted restoration may allow Vector to load an inconsistent state. `pidof vectord` alone does not prove no other service or early boot script can open it, and a restorecon attempt without verified ownership/mode/context is not sufficient device acceptance.

The Python WAL transaction prototype tests: durable backup of the original database and its existing WAL/SHM/journal, persistent PREPARED journal before mutation, checkpointed sidecar retirement, main-file swap, integrity verification, COMMITTED_UNVERIFIED until healthy boot, recovery of the byte-identical original database family, and refusal to reconcile while a daemon is active. It is a **model only**. It does not implement or replace the Android boot-stage shell code, and its simulated `fsync`/interruption model does not prove physical power-loss durability.

## Non-negotiable prerequisites for an actual spare-device campaign

1. Independent rescue path **outside Guardian and Vector** demonstrated to restore `/data/adb/lspd/config` with correct contexts, even if Android fails to boot. Confirmed expendable device or emulator with a matching supported root stack; **not** the primary phone.
2. Reproducible Android + KernelSU + Vector version pair, signed capture of Vector version, Android fingerprint and SELinux policy. Installable Guardian from a specific commit with known source checksums.
3. A verified *consistent* `vector db backup` snapshot; verify SQLite integrity, schema, digest, file size, enabled/scope manifest and its creation provenance. Explicitly version-pin and promote **only in disposable environment**.
4. Demonstrate `post-fs-data.sh` executes before any Vector DB open, including another root module starting the daemon. Capture kernel/daemon timestamps; fail if startup order is ambiguous. Do not simply infer ordering from filenames or a one-time `pidof` check.
5. Independent full-family backup (DB, WAL, SHM, journal as present) and test restore of that backup from the external rescue channel *before* inducing failure.
6. Verify UID/GID, 0660 mode, actual SELinux context and `restorecon` behavior for staged and committed files. Refuse mismatches; never disable SELinux.

## Device acceptance matrix (all needed)

- Healthy boot: no mutation, normal daemon startup, no false failure count.
- Corrupt snapshot, missing SQLite verifier, unsupported Vector version, invalid scope manifest: restore refused with original database family unchanged.
- WAL present with committed uncheckpointed writes: restore either completes as a verified coherent snapshot or is rolled back as a complete old database family. No mixed main DB/WAL replay.
- Forced terminate at **every** transaction checkpoint (before marker, after marker, each sidecar move, after DB swap, after digest check, before healthy-boot confirmation). Reboot from disposable environment, reconcile before Vector starts, prove original full-family integrity.
- SELinux-denied stage or rename, disk-full staging, read-only filesystem, checksum fault, partial/broken journal, duplicate boot hook: fail closed with independent recovery still possible.
- Post-restore successful Vector startup, exact module inventory and scopes expected, no daemon errors, healthy boot confirmation and atomic evidence receipt.
- Unexpected power-off after stage/commit: independent rescue path remains tested; record honest observations. A simulated process-kill is **not** power-loss evidence.
- Explicit disarm/uninstall path returns to original state; no automatic quarantine re-enabled.

Required machine receipt fields: source commit, build hashes, installed module hashes, device fingerprint, Vector/KernelSU versions, SELinux context, process/boot order, database/sidecar SHA-256 before/after, stage marker checkpoints, test action timestamps, stdout+stderr, independent rescue qualification, and unambiguous result PASS/FAIL/NOT_VERIFIED. No transition to `RECOVERY_DEVICE_QUALIFIED=1` without *all* genuine gates.

## Devtool workflows

`./devtoolw early-boot-preflight` is read-only and must continue to report `NOT_VERIFIED` on a primary device. `./devtoolw early-boot-lab` is host-only and only writes under disposable temporary directories and `dist/`; the test is part of `./devtoolw check`, `install` host qualification and GitHub CI, but **does not** count as a device restore.


## Phase 1: hardware ordering probe (Guardian v0.9.1)

The verified manual rescue script v4 at `/data/local/tmp/guardian-recover.sh` was confirmed by the device owner to read `backup_integrity=PASS` in custom recovery. This is **rescue readiness**, not live early-boot restore qualification.

After installing the validated Guardian v0.9.1 module through Devtool (KernelSU install, reboot as requested), wait for stability, then opt in to a **separate** read-only reboot probe:

```
./devtoolw boot-order-stage
# Manually reboot the phone after staging, without additional device changes
./devtoolw boot-order-status
```

`boot-order-status` reports an `EARLY_CANDIDATE` when the actual KernelSU `post-fs-data` hook saw `sys.boot_completed=0` and `pidof vectord` was empty. It also requires a matching healthy service-phase receipt where Vector responded. The marker is one-shot; no daemon is killed, no live SQLite files are read or modified beyond file-existence metadata, and no restore is queued. `PASS_GUARDIAN_BOOT_ORDER_OBSERVED` is not exclusive DB ownership proof, nor an authorization to turn on recovery.

Missing/late Vector ordering, missing receipts, mismatching kernel boot IDs or failed Vector post-boot response remain pending/negative evidence. Next step is a fail-closed staged restore with independent rescue and explicit user authorization, not a reboot loop or automatic recovery.
