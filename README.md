# LSPosed Guardian v0.9.0 — consolidated isolated fault-lab and full-output WebUI

Independent KernelSU/Vector safety monitor. Upgrading from v0.8 retains `/data/adb/lsposed-guardian` recovery history, the pinned legacy baseline, and the `com.openai.chatgpt` crash exclusion. **Automatic recovery is disabled and unqualified; this release never promotes legacy snapshots or silently enables module toggles.**

## Consolidated v0.9 features

- Incorporates the user-confirmed v0.8 full-output KernelSU WebUI fix into the installed module ZIP. The callback form of `ksu.exec` preserves stdout/stderr/exit code instead of reporting only one module.
- Full Vector module inventory with enabled/disabled filtering and search, discrepancy warning against the daemon's enabled count, and **per-module read-only explicit scope inspection**.
- `qualification`: reports recovery gates separately from lab successes. A sandbox pass **cannot** certify live quarantine or actual early-boot restoration.
- `quarantine-lab`: executes Guardian's actual journal/disable/rollback/reconcile functions against a synthetic in-process Vector backend and private sandbox directory, injecting no-op success, lost acknowledgement, ledger write failure, and unrelated inventory mutation. No call to the installed Vector CLI.
- `recovery-lab`: retains its copied-DB staging/corruption/interruption tests, adding post-commit fault rollback with WAL/SHM preservation **within a simulation**. This does **not** mean actual `offline_restore` is qualified.
- Keeps all v0.7/v0.8 crash exclusion, historical scope tracking, pinned snapshot, manual transaction and recovery safety gates.

## Upgrade

Install `LSPosed-Guardian-v0.9.0.zip` via KernelSU or:

```sh
su -c 'ksud module install /sdcard/Download/LSPosed-Guardian-v0.9.0.zip'
```

Reboot. Open the Guardian WebUI and verify **Modules** lists the entire Vector inventory; tap **Scopes** to inspect a module. The UI never enables/disables modules, sets scopes, queues restoration or runs arbitrary commands. The WebUI has no network requests or external dependencies.

## Real-device acceptance (automatically copies output to Termux clipboard)

```sh
G=/data/adb/modules/lsposed_guardian/guardian.sh
OUT=$(mktemp)
{
  for task in 'selftest' 'doctor' 'quarantine-lab' 'recovery-lab' 'qualification' 'quarantine-status' 'integrity' 'report'; do
    printf '\n=== %s ===\n' "$task"
    su -c "$G $task"
    printf 'exit_code=%s\n' "$?"
  done
} 2>&1 | tee "$OUT"
if command -v termux-clipboard-set >/dev/null 2>&1 && termux-clipboard-set < "$OUT"; then
  echo 'Copied complete diagnostics to Termux clipboard'
  rm -f "$OUT"
else
  echo "Clipboard unavailable. Copy from: $OUT"
fi
```

Expected isolated-lab markers: `PASS_GUARDIAN_ISOLATED_QUARANTINE_LAB`, `PASS_GUARDIAN_ISOLATED_RECOVERY_LAB`; `qualification=UNQUALIFIED` and `actual_early_boot_restore_test=NOT_VERIFIED` MUST remain. A successful lab does not change `device_restore_qualified=0`.

## Explicit limits and next gate

No real device was used by host regressions. No writable WebUI, no automatic quarantine, and no actual early-boot restore was qualified. Real-device qualification requires a disposable Android setup with a test Vector config, controlled failed-boot injection, verified SELinux/context and WAL/journal behavior, and independently recoverable rollback. Do not manually set `RECOVERY_DEVICE_QUALIFIED=1`, run `arm`, or queue `restore --apply` on your daily-use device.

## Public source and Devtool development

This repository contains the consolidated repaired **Guardian 0.9.0** source (including the Android-tested quarantine-lab journal fix). It is intended to live at `~/Code/lsposed-guardian` on Termux. The generated `devtoolw` launcher delegates every workflow to Devtool's canonical runner, not to a second scheduler.

```sh
./devtoolw check         # source + all host regressions + WebUI + deterministic packaging
./devtoolw build         # creates verified ZIPs in dist/
./devtoolw install       # explicit root-module install via ksud, preserves installer TTY
./devtoolw device-check # read-only diagnostics copied to Termux clipboard
./devtoolw doctor
./devtoolw preflight
```

**Safety:** `install` modifies a KernelSU module and requires explicit invocation. It does not reboot. The real early-boot restore gate is not qualified; leave Guardian in OBSERVE mode. CI artifacts are release candidates, not device-certified releases. Read [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [docs/WRAPPER.md](docs/WRAPPER.md).
