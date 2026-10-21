# Public repository bootstrap — delivery contract and evidence

| Commitment | Verification method (behavior, not file existence) | Current status |
| --- | --- | --- |
| Recover the **device-tested** v0.9 quarantine fix | `quarantine-lab` behavior on user's phone; canonical fixed journal reader and FAIL/NOT_RUN states tested | PASS on the user's device prior to repository bootstrap |
| Save under **`~/Code/lsposed-guardian`** | `SETUP-TERMUX.sh` checks archive digests, rejects an existing destination, stages/copies and renames into `$HOME/Code`; initial commit | Implemented; awaits user's Termux execution |
| Create a **public** GitHub repository through configured `gh` | `tools/publish.sh` checks clean committed tree and explicit `gh repo create --public --source=. --remote=origin --push`; never auto-publishes | Implemented; awaits user's explicit execution/auth |
| Proper Devtool TOML and schema-2 wrapper | Actual Devtool 2026-10-21 snapshot `wrapper describe`, `wrapper resolve install`, `wrapper init`, `wrapper seal` | PASS on host, re-check with installed Termux Devtool |
| Use canonical Devtool workflow DAG | Explicit typed target, ten jobs, nine workflows, dependencies and typed `[[test]]` catalog | PASS parser/contract, device execution pending |
| Install via **wrapper workflow** | `install` DAG orders source-check → build → archive verify → `flash-ksu`; `tools/install.sh` checks archive and launches KernelSU through PTY | Contract/dry-run PASS; real installation not executed (explicit operator action required) |
| Keep real installer interactive | PTY adapter refuses non-interactive stdin and passes through terminal input/output | Host rejection test PASS; physical volume-key interaction requires device verification |
| Test fake Vector, rollback and recovery safety | 69 distinct fake-Vector tests run against disposable state | PASS 69/69 on host |
| WebUI complete multiline output and scopes | Eight Node regression cases | PASS 8/8 on host, historically verified on Android |
| GitHub CI release candidate | Two GitHub Actions workflows run host checks and build+hash verification, uploading artifact candidates; no root install, no auto-release | Source verified; GitHub run required |
| Clipboard diagnostics | `device-check` sends complete stdout and stderr to `termux-clipboard-set`, retains file on failure | Source verified; Termux runtime required |
| Preserve recovery safety | Excluded ChatGPT crash; pinned legacy baseline not promoted; automatic recovery disabled | PASS in device report and source contract |
| Full device recovery qualification | Actual offline restore + live disposable-module quarantine | OPEN / **UNQUALIFIED**; never represent sandbox labs as device proof |

Known Devtool integration recommendations and their evidence are recorded cumulatively in `docs/DEVTOOL_INTEGRATION_IMPROVEMENTS.md`.
