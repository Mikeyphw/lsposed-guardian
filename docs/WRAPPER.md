# Guardian's Devtool wrapper contract

This repo uses the **Devtool-generated** `devtoolw` and `devtoolw.cmd` launchers. They delegate to canonical `devtool --repo REPO wrapper exec`; they are not an independent runner.

| Command | Canonical operation | Effect |
| --- | --- | --- |
| `./devtoolw check` | `invoke check` | Source syntax, hermetic Python tests, Devtool contract tests, WebUI, package+hash verification |
| `./devtoolw test` | `invoke test` | Source checks and isolation tests (no live device access) |
| `./devtoolw syntax` | `invoke syntax` | Static source and TOML contract checks |
| `./devtoolw webui` | `invoke webui` | Node WebUI test suite |
| `./devtoolw build` | `invoke build` | Deterministic ZIPs in `dist/`, with checksum manifest and build evidence |
| `./devtoolw install` | `invoke install` | Build+verify then `ksud module install` in attached Termux terminal; **changes root module** |
| `./devtoolw device-check` | `invoke device-check` | Read-only device acceptance, copies complete output using `termux-clipboard-set` |
| `./devtoolw preflight` | `invoke preflight` | Canonical Devtool `preflight` through job |
| `./devtoolw doctor` | `invoke doctor` | Canonical Devtool `doctor` through job |
| `./devtoolw validate` | `validate` | Native Devtool validation path |

Inspect without executing: `devtool wrapper describe --json`, `devtool wrapper resolve install --json`, `devtool plan invoke --target guardian`, `devtool wrapper seal --json`. The exact Devtool installation's CLI options govern these invocations.

`install` is intentionally excluded from CI, the default `check`, and read-only plans. Use the explicit command only when you intend to flash on KernelSU. Installer volume-key prompts get an explicit child PTY (via `tools/pty_install.py`), because Devtool captures stdout and starts a child session. The installer refuses noninteractive stdin; no stdout/stderr tee around `ksud`. No automatic reboot.

Regenerate launchers when upgrading Devtool: `devtool -r . wrapper update` and `devtool -r . wrapper seal --json`.
