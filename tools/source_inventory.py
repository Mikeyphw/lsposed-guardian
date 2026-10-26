#!/usr/bin/env python3
"""Canonical runtime/test source fingerprint for host qualification evidence."""
from __future__ import annotations
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]

def inventory():
    paths = set(ROOT.glob('*.sh')) | set((ROOT/'lib').glob('*.sh'))
    paths.update({ROOT/p for p in ('config.defaults','module.prop','tests/test_guardian.py','tests/test_boot_probe.py','tests/test_boot_trial.py','tests/test_one_shot.py','tests/test_devtool_contract.py','tools/run_host_tests.py')})
    rows = {}
    for path in sorted(paths):
        if not path.is_file():
            raise FileNotFoundError(path)
        rows[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return rows

def fingerprint(data=None):
    data = inventory() if data is None else data
    lines = '\n'.join(f'{key} {value}' for key, value in sorted(data.items())) + '\n'
    return hashlib.sha256(lines.encode()).hexdigest()
