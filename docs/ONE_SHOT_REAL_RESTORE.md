# v0.9.3 — manually gated ONE-SHOT real Vector restoration

**Status:** implementation and hermetic fixtures have passed. **No live Android restoration has yet been attempted or qualified.** User's custom recovery rescue v4 is verified and the nine-enabled-module backup refresh completed, but a working backup is not proof that a multi-file database swap is safe in every interruption state.

## Last observed real-device qualifications (operator reports, not reproduced in host CI)

- Real manually requested `eu.hxreborn.remembermysort` disable/re-enable through authenticated Vector CLI: PASS; full twenty-module inventory restored; no pending Guardian quarantine transaction.
- v0.9.2 post-fs-data boot-order probe: PASS (no `vectord` PID at observation, later `VECTOR_RESPONDING`). No universal exclusive-DB-lock proof.
- v0.9.2 copy-only post-fs-data WAL rehearsal: PASS, original database main-file hash unchanged, Vector responsive afterward. `boot_completed=unknown` and `context=Oct` were **not** SELinux or boot-state proof.
- Rescue v4 verification in custom recovery: reported PASS. Nine-module refresh: checksum `af9e1b6650c58de220e0ce7e43041ec40dad270a0aab25a1f032ad9256f4cf38` and older verified backup retained.

## Implementation

- New `lib/one-shot.sh` has explicit read-only `one-shot-preflight`, explicit `one-shot-stage --apply`, read-only `one-shot-status`, and pre-execution `one-shot-cancel`.
- The stage operation runs while Android is healthy, requires a matching current-boot copy-only rehearsal and matching enabled Vector module manifest, verifies rescue v4 and SQLite integrity, then copies the prepared consistent backup to Guardian's root-only state. **Staging does not touch the live Vector DB family.**
- Only a new kernel boot consumes the request. At `post-fs-data`, `AUTO_RECOVERY=0` and `RECOVERY_DEVICE_QUALIFIED=0` are required, alongside no Vector PID, incomplete Android boot, version 3112, expected root ownership/0660 permissions and `u:object_r:system_file:s0` SELinux context. Uncertain metadata and unreadable hashes fail closed.
- Original live DB, WAL, SHM and rollback journal are copied and checksum-verified *before* live mutation. The original family is retained in `/data/adb/lsposed-guardian/one-shot/transaction/` and stays there after success.
- Replacement DB is prepared in the same configuration directory with matching ownership/label, checked for content checksum before sidecars are moved, and the one-shot request is never automatically retried. The active journal explicitly tracks `ORIGINAL_VERIFIED`, `SWAP_STARTED`, `COMMITTED_PENDING_HEALTH`, and aborted states, with `sync` at transition boundaries.
- Interrupted `SWAP_STARTED` attempts a single journaled transaction-local undo on the next early boot; if a safe undo cannot be confirmed, it reports `NEEDS_CUSTOM_RECOVERY` and **never retries the replacement**. This local undo is *not* unattended bootloop recovery and does not arm Guardian.
- The healthy-boot service must observe Vector responding and the exact expected enabled manifest before `one-shot-status` prints `PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE`. This is a *specific tested restore round trip*, not proof of race-free filesystem access or every possible power-cut state.
- Emergency command **only from custom recovery** (after mounting `/data`): `sh /data/adb/modules/lsposed_guardian/one-shot-offline-undo.sh restore --offline`. It checks retained original family SHA-256 checksums, makes a copy of the current family, restores original DB/WAL/SHM and disables Guardian. **This offline undo has host-fixture validation, but has not yet been exercised in custom recovery**; rescue v4 is the independently prepared fallback.

## Device workflow

1. Install v0.9.3 from the full Devtool `check`/`install` gate and perform a normal reboot **without staging**. Confirm the installed version, `mode=OBSERVE`, Vector version 3112, rescue integrity PASS, and `one-shot-status` not staged.
2. Run **read-only** `./devtoolw one-shot-preflight`. It should print `PASS_GUARDIAN_ONE_SHOT_PREFLIGHT`. If it refuses, preserve its detailed failure; do not bypass the gate.
3. After independently verifying custom-recovery access and preflight output, intentionally stage via `./devtoolw one-shot-stage`; then inspect `./devtoolw one-shot-status` before considering the one reboot that **will replace the live Vector database**. `one-shot-cancel` aborts before the next boot.
4. If explicitly authorized, reboot once. After reaching stable Android, run `./devtoolw one-shot-status`, `./devtoolw device-check` and rescue `status`. Keep the original transaction directory and sidecars; do not promote the legacy pinned baseline and do not set qualification flag 1.
5. If Android or Vector fails, use custom recovery to diagnose; **do not manually delete journals or continuously reboot**. Use the independent rescue procedure or the new offline undo after confirming its requirements.

## Known remaining limitations

- Vector startup racing with Guardian between PID probes and the filesystem rename cannot be disproved by the currently available evidence; a PID check is **not an exclusive lock**. Real proof of race-free access requires a Vector/KernelSU ordering contract or coordination.
- Several SQLite database-family path changes are not atomically grouped. `sync` plus retained journal copies improve recoverability but cannot guarantee survival of every hardware power-loss point without disposable power-interruption testing.
- `one-shot-status` cannot assert the old crash history or all dynamic hooks have identical runtime behavior after restore; it only checks Vector health and enabled manifest, supplemented by separate lab results.
- The existing `qualification` command continues to report overall `UNQUALIFIED`. Do not modify `RECOVERY_DEVICE_QUALIFIED`, use unattended `restore --apply`, or arm automatic recovery based only on a one-shot receipt.

## v0.9.4 historical acceptance addendum (2026-10-27)

The owner's actual device reported successful v0.9.3 restore and post-boot Vector health on boot `dc83413b-5588-4dff-9c34-905f83767399`, with 12/12 enabled modules matching a SHA-256 verified backup. This supersedes the earlier *device acceptance pending* status for **that one manual round-trip only**. Original DB family was reported retained; it has not yet been independently restored from custom recovery.

v0.9.4 `one-shot-finalize` verifies the historical receipts and retained originals, rechecks current Vector enabled manifest, and atomically seals only the transaction status file. Source tests include idempotency, older-boot migration, damaged original rejection, and forged/failed-health rejection. The source and installed runtime must both be v0.9.4 before invoking this command. No fresh destructive test is needed. Automatic restore, exclusive DB access and power-loss reliability remain UNQUALIFIED.
