# Development, validation and release gates

Repository root: `~/Code/lsposed-guardian` on the owner's Termux device. Current release source: Guardian v0.9.0 **including** the Android-tested quarantine-lab repair; no device-qualification state was imported.

## Commands

```sh
./devtoolw --help
./devtoolw preflight
./devtoolw doctor
./devtoolw syntax
./devtoolw webui
./devtoolw test
./devtoolw check
./devtoolw build
./devtoolw install           # ROOT MODULE MUTATION; attached Termux TTY
./devtoolw device-check      # read-only with clipboard
```

Devtool is the sole workflow DAG and execution authority. The repository exposes target `guardian`, typed jobs, DAG dependencies, a stable wrapper schema 2, and first-class `[[test]]` declarations. `./devtoolw check` is the combined gate. `./devtoolw install` now **requires the complete host regression, WebUI and Devtool contract suite**, exact-test-inventory qualification, package build and SHA-256 verification before offering the verified archive to interactive `ksud`. This can take several minutes. A failed/timeout test prevents installation; there is no implicit test-skipping shortcut. Hosted GitHub Actions mirror the same commands with a `ci-parity` check, but do not claim the local Devtool CLI ran on Ubuntu.

## Safety gates

- `mode=OBSERVE` unless explicitly changed on-device; never enable automatic quarantine or restoration in CI.
- ChatGPT (`com.openai.chatgpt`) is excluded by user request; crash counts are not LSPosed evidence.
- Isolated quarantine and recovery labs are **not** live device qualification.
- The pinned legacy recovery snapshot remains `legacy_header_only`, origin unknown.
- Never automatically promote snapshots or change Vector configuration for host tests.
- `ksud module install` is **not** CI compatible and may prompt for volume-key input; the install job uses an explicit Python child PTY, and refuses noninteractive stdin. Never suppress or pipe installer input.
- Release workflows publish *candidate artifacts* only, not verified production releases or an automatic GitHub Release.

## Read-only device reporting

`./devtoolw device-check` runs the existing device selftests, qualifications, and JSON report; its complete stdout/stderr is sent to `termux-clipboard-set`. If Termux API clipboard is unavailable, a persistent diagnostic log path is reported instead.

## CI

Ubuntu GitHub Actions runs pure host tests and creates artifacts. No root, Android instrumented test, live Vector, or real offline restore is implied by green CI. A separate real-device/disposable-device acceptance campaign is required to close release gates.

## Cumulative status

| Obligation | Evidence / status |
| --- | --- |
| Host fake-Vector and rollback | Passed historically; rerun through Devtool and CI |
| Full KernelSU WebUI output | Real device fixed and verified in v0.8 repair |
| Isolated quarantine on Android | PASS in v0.9 after journal-reader repair |
| Isolated SQLite restore on Android | PASS; not equivalent to live restore |
| Snapshot integrity of observed config | PASS |
| Pinned legacy baseline | UNQUALIFIED, deliberately preserved |
| Live disposable-module quarantine | NOT VERIFIED |
| Genuine early-boot offline restore | NOT VERIFIED |
| Automatic quarantine / recovery | DISABLED |

Devtool integration findings are tracked cumulatively in [DEVTOOL_INTEGRATION_IMPROVEMENTS.md](DEVTOOL_INTEGRATION_IMPROVEMENTS.md); forward open upstream issues to the canonical Devtool improvement ledger when that checkout is available.
