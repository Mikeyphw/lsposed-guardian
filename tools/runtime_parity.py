#!/usr/bin/env python3
"""Read-only KernelSU active-vs-staged parity. Fixture mode never contacts root.

A staged update is NOT a broken active installation. Source bytes are checked
against both locations. Root probing is delegated to a fixed, audited shell.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = ('module.prop', 'guardian.sh', 'lib/crash.sh', 'lib/qualification.sh',
         'lib/one-shot.sh', 'post-fs-data.sh', 'service.sh', 'lib/common.sh',
         'lib/auto-quarantine.sh', 'lib/safe-mode.sh', 'crash-monitor.sh', 'lib/quarantine.sh')
KEYS = ('ACTIVE', 'STAGED')


def digest(file: Path) -> str:
    return hashlib.sha256(file.read_bytes()).hexdigest()


def local_expected(root: Path) -> dict[str, str]:
    return {item: digest(root / item) for item in FILES}


def probe_fixture(root: Path) -> dict:
    data = {}
    for key, dirname in (('ACTIVE', 'modules/lsposed_guardian'),
                         ('STAGED', 'modules_update/lsposed_guardian')):
        directory = root / dirname
        data[key] = None if not directory.is_dir() else {
            name: digest(directory / name) if (directory / name).is_file() else None
            for name in FILES
        }
    return data


def probe_root() -> dict:
    # su executes a fixed source-bundled POSIX script, never user-generated code.
    script = ROOT / 'tools/runtime_parity_root.sh'
    command = "'/system/bin/sh' '" + str(script).replace("'", "'\\''") + "'"
    proc = subprocess.run(['su', '-c', command], text=True, capture_output=True, timeout=25)
    if proc.returncode:
        raise RuntimeError('root_parity_probe_failed (check su permissions)')
    data = {k: None for k in KEYS}
    for line in proc.stdout.splitlines():
        parts = line.split('|')
        if len(parts) == 2 and parts[0] in KEYS and parts[1] == 'ABSENT':
            continue
        if len(parts) != 3 or parts[0] not in KEYS or parts[1] not in FILES:
            raise RuntimeError('unexpected_root_probe_output')
        if data[parts[0]] is None:
            data[parts[0]] = {}
        value = parts[2]
        if value != 'MISSING' and (len(value) != 64 or any(c not in '0123456789abcdef' for c in value)):
            raise RuntimeError('invalid_root_probe_digest')
        if parts[1] in data[parts[0]]:
            raise RuntimeError('duplicate_root_probe_key')
        data[parts[0]][parts[1]] = None if value == 'MISSING' else value
    for key in KEYS:
        if data[key] is not None and set(data[key]) != set(FILES):
            raise RuntimeError('incomplete_root_probe')
    return data


def compare(expected: dict, observed: dict) -> dict:
    result = {}
    for key in KEYS:
        entry = observed[key]
        if entry is None:
            result[key.lower()] = 'ABSENT'
            result[key.lower() + '_drift'] = []
        else:
            drift = [name for name in FILES if entry.get(name) != expected[name]]
            result[key.lower()] = 'MATCH' if not drift else 'DIFFERENT'
            result[key.lower() + '_drift'] = drift
    if result['active'] == 'MATCH' and result['staged'] == 'ABSENT':
        result['classification'] = 'ACTIVE_MATCH'
        result['pass'] = True
    elif result['staged'] == 'MATCH' and result['active'] != 'MATCH':
        result['classification'] = 'STAGED_PENDING_REBOOT'
        result['pass'] = True
    elif result['active'] == 'MATCH' and result['staged'] == 'MATCH':
        result['classification'] = 'ACTIVE_MATCH_UPDATE_PENDING'
        result['pass'] = True
    elif result['active'] == 'ABSENT' and result['staged'] == 'ABSENT':
        result['classification'] = 'NOT_INSTALLED'
        result['pass'] = False
    else:
        result['classification'] = 'UNEXPECTED_RUNTIME_DRIFT'
        result['pass'] = False
    result['automatic_recovery'] = 'DISABLED'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture-root', type=Path, help='tests only; substitute fixture tree')
    parser.add_argument('--json', action='store_true')
    a = parser.parse_args(argv)
    try:
        result = compare(local_expected(ROOT), probe_fixture(a.fixture_root) if a.fixture_root else probe_root())
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        result = {'classification': 'UNVERIFIED', 'pass': False, 'reason': str(exc)}
    if a.json:
        print(json.dumps({'schema_version': 1, **result}, sort_keys=True))
    else:
        print('GUARDIAN INSTALLED RUNTIME PARITY (read-only)')
        for k in ('active', 'staged', 'classification'):
            if k in result: print(f'{k}={result[k]}')
        for k in ('active_drift', 'staged_drift'):
            if result.get(k): print(k + '=' + ','.join(result[k]))
        if 'reason' in result: print('reason=' + result['reason'])
        if result.get('pass'): print('PASS_GUARDIAN_RUNTIME_PARITY')
        else: print('FAIL_GUARDIAN_RUNTIME_PARITY')
    return 0 if result['pass'] else 1

if __name__ == '__main__':
    sys.exit(main())
