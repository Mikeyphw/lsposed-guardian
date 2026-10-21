#!/usr/bin/env python3
"""Live Guardian quarantine / rollback qualification, fixed to one authorized module.

This is deliberately NOT a fake-Vector test. It exercises the installed
Guardian CLI and the live Vector daemon, while refusing unrelated mutations.
It never uses a direct Vector enable/disable and never touches the Vector DB.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

PACKAGE = "eu.hxreborn.remembermysort"
GUARDIAN = "/data/adb/modules/lsposed_guardian/guardian.sh"
STATE = Path.home() / ".local" / "state" / "lsposed-guardian" / "real-gates"
ROW = re.compile(r"^([A-Za-z][A-Za-z0-9_.]+)\s+(\d+)\s+(enabled|disabled)\s*$")


class GateFailure(Exception):
    pass


def inventory(text):
    """Parse full human CLI output; refuse partial, duplicate or unknown entries."""
    if not re.search(r"(?m)^PACKAGE\s+UID\s+STATUS\s*$", text):
        raise GateFailure("Missing Vector inventory header (may be truncated)")
    rows = {}
    unknown = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("PACKAGE") or re.fullmatch(r"-+", stripped):
            continue
        m = ROW.fullmatch(stripped)
        if not m:
            unknown.append(stripped)
            continue
        pkg, uid, state = m.groups()
        if pkg in rows:
            raise GateFailure("Duplicate package in Vector inventory")
        rows[pkg] = {"uid": int(uid), "state": state}
    if unknown:
        raise GateFailure("Unknown Vector inventory rows: " + repr(unknown[:3]))
    if not rows:
        raise GateFailure("Empty Vector inventory")
    return rows


def only_target_disabled(before, during):
    expected = {key: dict(value) for key, value in before.items()}
    if PACKAGE not in expected or expected[PACKAGE]["state"] != "enabled":
        raise GateFailure("Target was not enabled in original inventory")
    expected[PACKAGE]["state"] = "disabled"
    return during == expected


def same_full_inventory(before, after):
    return before == after


def entries(text):
    return [line.strip() for line in text.splitlines() if line.strip().startswith(("active:", "NEEDS_RECONCILIATION:", "ROLLBACK_NEEDS_RECONCILIATION:"))]


class LiveGate:
    def __init__(self, apply):
        self.apply = apply
        self.log_lines = []
        self.results = {}
        self.before = None
        self.disabled_seen = False
        self.rollback_attempted = False
        self.started = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-%d" % os.getpid()
        self.out_dir = STATE / self.started
        self.out_dir.mkdir(parents=True, exist_ok=False)
        os.chmod(self.out_dir, 0o700)

    def log(self, msg):
        line = str(msg)
        self.log_lines.append(line)
        print(line, flush=True)

    def cmd(self, label, args, *, require=True, timeout=90):
        self.log("\n=== " + label + " ===")
        cmd = ["su", "-c", " ".join([GUARDIAN, *args])]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, errors="replace")
            if p.stdout:
                self.log(p.stdout.rstrip())
            if p.stderr:
                self.log("STDERR: " + p.stderr.rstrip())
            self.log("exit_code=" + str(p.returncode))
            if require and p.returncode != 0:
                raise GateFailure(label + ": Guardian exited " + str(p.returncode))
            return p.returncode, p.stdout
        except subprocess.TimeoutExpired as exc:
            self.log("TIMEOUT: " + label)
            raise GateFailure(label + " timed out") from exc

    def save_json(self):
        result = {
            "schema": "guardian-live-vector-roundtrip-v1",
            "target": PACKAGE,
            "mode": "APPLY" if self.apply else "PREFLIGHT_ONLY",
            "outcome": self.results.get("outcome", "INCOMPLETE"),
            "automatic_recovery_qualified": False,
            "early_boot_restore_qualified": False,
            "steps": self.results,
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        (self.out_dir / "receipt.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        self.log("Evidence: " + str(self.out_dir / "receipt.json"))
        self.log("Full log: " + str(self.out_dir / "full-output.txt"))
        self.log("Clipboard capture requested; if unavailable, evidence remains on disk")
        log_text = "\n".join(self.log_lines) + "\n"
        (self.out_dir / "full-output.txt").write_text(log_text)
        try:
            p = subprocess.run(["termux-clipboard-set"], input=log_text, text=True,
                               capture_output=True, timeout=15)
            if p.returncode == 0:
                self.log("PASS_GUARDIAN_OUTPUT_COPIED_TO_TERMUX_CLIPBOARD")
            else:
                self.log("Clipboard failed; evidence remains on disk")
        except (OSError, subprocess.TimeoutExpired):
            self.log("Clipboard unavailable; evidence remains on disk")

    def get_inventory(self, label):
        _, raw = self.cmd(label, ["modules"])
        parsed = inventory(raw)
        encoded = json.dumps(parsed, sort_keys=True, separators=(",", ":")).encode()
        self.log("modules_count=" + str(len(parsed)))
        self.log("inventory_sha256=" + hashlib.sha256(encoded).hexdigest())
        (self.out_dir / (label.replace(" ", "-") + ".json")).write_text(json.dumps(parsed, indent=2, sort_keys=True) + "\n")
        return parsed

    def q_status(self):
        _, result = self.cmd("quarantine-status", ["quarantine-status"])
        return result

    def preflight(self):
        # Do not stat /data/adb/modules from an unprivileged Termux process.
        # Android's /data/adb is typically inaccessible without root, so
        # Path.exists() can report False even when Guardian is installed.
        # The only authoritative probe is executing Guardian via `su -c`.
        _, h = self.cmd("installed Guardian CLI (root probe)", ["help"])
        if "LSPosed Guardian (Vector adapter)" not in h or "quarantine PKG" not in h:
            raise GateFailure("Unexpected Guardian CLI help; refusing live test")
        self.results["installed_guardian_root_probe"] = "PASS"
        _, d = self.cmd("doctor", ["doctor"])
        for requirement in ("LSPosed Guardian 0.9.0", "mode=OBSERVE", "vector_cli=available", "quarantine_active=0", "quarantine_pending=0", "manual_restore_queued=no", "device_restore_qualified=0"):
            if requirement not in d:
                raise GateFailure("Preflight requirement missing: " + requirement)
        q = self.q_status()
        if "(none)" not in q or entries(q):
            raise GateFailure("Existing Guardian quarantine state; refusing live test")
        self.before = self.get_inventory("before")
        if PACKAGE not in self.before or self.before[PACKAGE]["state"] != "enabled":
            raise GateFailure("Authorized module must be enabled before test")
        self.cmd("target scope (read-only)", ["scope", PACKAGE])
        self.cmd("quarantine preview (read-only)", ["quarantine", PACKAGE])
        self.results["preflight"] = "PASS"
        self.log("PASS_GUARDIAN_LIVE_QUARANTINE_PREFLIGHT")

    def finish_rollback(self):
        """Only Guardian journal-backed recovery; never direct Vector enabling."""
        try:
            status = self.q_status()
            if f"NEEDS_RECONCILIATION: {PACKAGE}" in status:
                self.cmd("reconcile interrupted quarantine", ["quarantine-reconcile", PACKAGE, "--apply"], require=False)
                status = self.q_status()
            if f"ROLLBACK_NEEDS_RECONCILIATION: {PACKAGE}" in status:
                self.cmd("reconcile interrupted rollback", ["rollback-reconcile", PACKAGE, "--apply"], require=False)
                status = self.q_status()
            if f"active: {PACKAGE}" in status:
                self.rollback_attempted = True
                self.cmd("rollback Guardian-quarantined target", ["rollback", PACKAGE, "--apply"], require=False)
                status = self.q_status()
                if f"ROLLBACK_NEEDS_RECONCILIATION: {PACKAGE}" in status:
                    self.cmd("reconcile interrupted rollback", ["rollback-reconcile", PACKAGE, "--apply"], require=False)
            actual = self.get_inventory("final")
            if not same_full_inventory(self.before, actual):
                raise GateFailure("Final inventory does not match original; manual review required")
            st = self.q_status()
            if entries(st):
                raise GateFailure("Guardian quarantine records remain; manual review required")
            self.results["full_inventory_restored"] = True
            return True
        except Exception as e:
            self.log("RECOVERY WARNING: " + str(e))
            self.log("Do not directly use Vector 'enable' or manually remove journals.")
            self.log("Inspect: su -c '" + GUARDIAN + " quarantine-status'")
            self.log("Recovery (only with journal evidence): su -c '" + GUARDIAN + " rollback " + PACKAGE + " --apply'")
            self.log("If pending, first use the appropriate quarantine-reconcile / rollback-reconcile command.")
            self.results["full_inventory_restored"] = False
            return False

    def execute(self):
        error = None
        try:
            self.preflight()
            if not self.apply:
                self.results["outcome"] = "PASS_PREFLIGHT_ONLY"
                return True
            if os.environ.get("GUARDIAN_GATE_TARGET", "") != PACKAGE:
                raise GateFailure("Explicit authorization environment GUARDIAN_GATE_TARGET=" + PACKAGE + " required")
            try:
                rc, _ = self.cmd("apply live quarantine", ["quarantine", PACKAGE, "--apply"], require=False)
                mid = self.get_inventory("during-disable")
                self.disabled_seen = mid.get(PACKAGE, {}).get("state") == "disabled"
                if rc != 0:
                    raise GateFailure("Guardian quarantine apply failed; attempting journal-backed recovery")
                if not only_target_disabled(self.before, mid):
                    raise GateFailure("Unexpected module delta after quarantine; attempting journal-backed recovery")
                self.results["only_target_disabled"] = True
                self.log("PASS_GUARDIAN_LIVE_TARGET_ONLY_DISABLED")
            except Exception as e:
                error = str(e)
            finally:
                restored = self.finish_rollback()
            if not restored:
                raise GateFailure("Failed to restore verified initial state; " + (error or "unknown cause"))
            if error:
                raise GateFailure(error)
            if not self.disabled_seen or not self.rollback_attempted:
                raise GateFailure("Quarantine/rollback sequence was not fully exercised")
            _, ledger = self.cmd("quarantine ledger", ["quarantine-ledger"])
            if not any(line.startswith("QUARANTINED\t" + PACKAGE + "\t") for line in ledger.splitlines()):
                raise GateFailure("Missing QUARANTINED ledger event")
            if not any(line.startswith("ROLLED_BACK\t" + PACKAGE + "\t") for line in ledger.splitlines()):
                raise GateFailure("Missing ROLLED_BACK ledger event")
            self.results["journal_ledgers"] = "PASS"
            self.results["outcome"] = "PASS_LIVE_VECTOR_QUARANTINE_ROUNDTRIP"
            self.log("PASS_GUARDIAN_LIVE_VECTOR_QUARANTINE_ROUNDTRIP")
            return True
        except BaseException as e:
            self.log("FAIL_GUARDIAN_LIVE_GATE: " + str(e))
            if self.apply and self.before is not None and not self.results.get("full_inventory_restored", False):
                self.finish_rollback()
            self.results["outcome"] = "FAILED_OR_UNVERIFIED"
            return False
        finally:
            self.save_json()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preflight", action="store_true", help="Read-only checks, no Vector mutations")
    group.add_argument("--apply", action="store_true", help="Explicitly exercise single module toggle and rollback")
    args = parser.parse_args()
    gate = LiveGate(args.apply)
    return 0 if gate.execute() else 1


if __name__ == "__main__":
    def stop_requested(signum, _frame):
        raise GateFailure("signal %s received; attempting journal-backed rollback" % signum)
    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    sys.exit(main())
