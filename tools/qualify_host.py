#!/usr/bin/env python3
"""Fail-closed evidence gate for Devtool and its CI fallback.

Checks a completed *current* isolated Guardian test inventory, not previous
human-readable PASS messages. The host qualification never asserts device
restore or live Vector safety.
"""
from __future__ import annotations
import ast
import hashlib
import json
from pathlib import Path
import time
from source_inventory import inventory, fingerprint
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/test_guardian.py'
RESULTS = ROOT / 'dist/host-test-results.json'
OUT = ROOT / 'dist/host-qualification.json'


def expected_names():
    tree = ast.parse(SOURCE.read_text())
    classes = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'GuardianTests']
    assert len(classes) == 1, 'Expected exactly one GuardianTests class'
    return sorted(n.name for n in classes[0].body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name.startswith('test_'))


def verify(data, expected):
    assert isinstance(data, dict), 'Invalid test evidence'
    actual = data.get('results')
    assert isinstance(actual, list), 'Missing detailed test results'
    names = [r.get('name') for r in actual if isinstance(r, dict)]
    assert len(names) == len(actual), 'Malformed test result rows'
    assert len(set(names)) == len(names), 'Duplicate test result names'
    assert sorted(names) == expected, 'Missing, extra or renamed Guardian tests'
    assert all(r.get('status') == 'PASS' for r in actual), 'Host test failure or timeout'
    assert data.get('schema_version') == 2, 'Legacy test evidence lacks source provenance'
    current = inventory()
    assert data.get('source_inventory') == current, 'Tested source differs from current Guardian runtime'
    assert data.get('source_fingerprint') == fingerprint(current), 'Tested source fingerprint mismatch'
    assert not data.get('source_changed_during_run'), 'Source changed during test run'
    assert data.get('total') == len(expected), 'Test total mismatch'
    assert data.get('passed') == len(expected) and data.get('failed') == 0, 'Pass counts incorrect'
    return len(expected)


def main():
    OUT.parent.mkdir(exist_ok=True)
    assert RESULTS.is_file(), 'Missing host regression evidence; run Devtool tests first'
    # Exact per-file hash inventory is stronger than wall-clock timestamps.
    data = json.loads(RESULTS.read_text())
    count = verify(data, expected_names())
    payload = {
        'schema_version': 1,
        'producer': 'lsposed-guardian-host-qualification',
        'result': 'PASS_HOST_ONLY',
        'guardian_tests_passed': count,
        'guardian_test_file_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        'source_fingerprint': fingerprint(),
        'device_restore_qualified': False,
        'live_quarantine_qualified': False,
        'automatic_quarantine_enabled': False,
        'timestamp_epoch': int(time.time()),
    }
    OUT.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
    print('PASS_GUARDIAN_HOST_EVIDENCE_QUALIFIED', count, 'tests (DEVICE UNQUALIFIED)')


if __name__ == '__main__':
    main()
