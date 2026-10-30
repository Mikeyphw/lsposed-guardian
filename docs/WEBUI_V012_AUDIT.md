# Guardian WebUI v0.12.1 — requirement-by-requirement audit

**Sources reviewed:** original v0.11.0 repository archive and Guardian v0.12.0 consolidated release overlay, including installable and source deliverables. **Result:** original v0.12.0 was incomplete; this v0.12.1 repair supplies a new source-bound installer and host-only regression evidence. No live Android device was available for this audit.

| User promise | Original 0.12.0 | 0.12.1 audit repair and actual evidence | Status |
|---|---|---|---|
| Protection-first dashboard | Present | `webroot/index.html`, `renderProtection()` | HOST PASS |
| Independent crash, bootloop and manual DB restore states | Partial | Root policy readback, stable boot, vector/collector/sampler readiness and AshReXcue deferral displayed; manual DB only | HOST PASS; DEVICE OPEN |
| Large raw logs replaced by labels and expandable receipts | Partial | Labeled diagnostics, technical expansion and clipboard, structured activity/quarantine lists | HOST PASS |
| Independent collector / sampler health, actionable failures | Partial | Background success/failure timestamps, failure stage/module; collector/sampler one-time diagnostics do not overwrite background state | HOST PASS; ROOT CAUSE OPEN |
| Health boot qualification | Present | Overview plus qualification in Settings, explicitly current boot | HOST PASS |
| Search and enabled/disabled module filtering | Present | Compact rows; tests exercise 20 module inventory and filtering | HOST PASS |
| Module descriptions | Missing | Vector does not expose reliable descriptions; UI explicitly says unavailable | PROVIDER LIMITATION |
| Module scope counts, per-module sampling, quarantine status | Partial | `scope-structured`, `history-module` verified against SHA snapshots, quarantine badges/details | HOST PASS |
| Dedicated quarantine history | Raw only | Typed ledger entries with timestamp, attribution, before/after state digests; raw fallback | HOST PASS |
| Configuration changes vs sampling separated | Partial | SHA-verified last-two change receipts separated from last-12 sampling list; unverified history no longer shown as unchanged | HOST PASS; OLD CHANGES UNKNOWN |
| True 512 / 512 sample retention display | Present | Retained `historical_checkpoints` count / capacity, no claim all are recent | HOST PASS |
| Guided process review with crash count and reason | Partial | Recent events, distinct PIDs, last matched scope count when available, reason mapping and no-causality note | HOST PASS |
| Real root-backed arm/disarm and fallback | Present | Effective status readback after confirmed callback; on failure buttons disabled / state unavailable | HOST PASS; DEVICE OPEN |
| Safeguards and cooldown | Read-only | Current safeguards, guarded enumerated 1h–7d cooldown setter with authenticated root command | HOST PASS |
| Crash exclusions | Not exposed | Root-backed safe add/remove, mandatory ChatGPT exclusion cannot be removed | HOST PASS |
| Emergency disarm | Present | `automatic-off` stops new actions, does not silently reverse prior ones | HOST PASS; DEVICE OPEN |
| Action notifications | Not implemented | Optional best-effort `cmd notification post`, explicit toggle/status/test and failure timestamps | HOST PASS FOR PATHS; DELIVERY UNVERIFIED |
| Recovery event trigger/evidence/result/rollback path | Partial | Guardian quarantine journal contains timestamp, Vector state digests and attribution, guarded action records; not a full causal proof or one-click UI rollback | PARTIAL |
| Readable typography, consistent responsive module rows | Present | Additional mobile reflow, error/scope wrapping and UI spacing | HOST STATIC CHECK; DEVICE OPEN |
| Persistent bottom navigation | Present | Five screen persistent bottom nav | HOST PASS |
| Last refreshed / partial failures | Partial | Failed/partial refresh and unknown policy states made explicit; no claim of total success | HOST PASS |
| Historical sampler actually healthy on user device | No evidence | Preserve independent background error, affected module, read-only retry; no fabricated fix for unknown Vector-side failure | OPEN / DEVICE DIAGNOSTIC |
| Device acceptance and unassisted recovery | Not qualified | No device, auto crash incident, hardware bootloop or SQLite interruption test executed | OPEN |

## Reproduction commands

From the patched repository on a host: `python3 tools/check_repo.py`, `node tests/test_webui.js`, `PYTHONPATH=tests python3 -m unittest discover -s tests -p 'test_*.py'`, `python3 tools/build.py`, `python3 tools/verify_build.py`. The two update installers independently verify source hashes before changing source files; both refuse a second apply. No shell test enables automatic response by default in a device install.

## Important remaining limitations

- Android notification **delivery**, not merely shell transport acceptance, requires a real-device test. The command may be unavailable or rejected on the target ROM. Logs and Guardian's journal are primary evidence.
- The last two verified configuration snapshots provide only *observed intervals*, not an exact module change instant. There is no reliable reconstruction of actions before Guardian installed its journal.
- Vector does not provide module description metadata in the CLI adapter. No descriptions are invented.
- Historical sampler failure seen in screenshots may originate in Vector scope CLI or its JSON format. Tests with fake Vector cannot identify the actual on-device failure without `history-health` and failing module scope evidence.
- Boot rescue / unattended quarantining and eventual rollback remain device safety acceptance work, not proven by screenshots or host tests. No unattended SQLite restore is enabled.
