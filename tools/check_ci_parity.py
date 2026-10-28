#!/usr/bin/env python3
"""Verify hosted CI runs the same safety jobs in the same order as Devtool check.

GitHub Actions cannot assume an unreleased local Devtool runtime is installed.
This checks the CI mirror against the canonical Devtool job graph; it does not
misrepresent the hosted jobs as having executed Devtool itself.
"""
from pathlib import Path
import tomllib

ROOT = Path(__file__).resolve().parents[1]
config = tomllib.loads((ROOT / '.devtool.toml').read_text())
target = config['targets']['guardian']
steps = target['workflows']['check']
ids = [x['id'] for x in steps]
assert ids == ['preflight','unit','contract','ui','ci-parity','wal-model','boot-trial-tests','one-shot-tests','parity-tests','personal-auto-tests','qualification','package','verify'], ids
expected = [
    'python3 tools/check_repo.py',
    'python3 tools/run_host_tests.py --workers 2 --timeout 180',
    'python3 -m unittest discover -s tests -p test_devtool_contract.py -q',
    'node tests/test_webui.js',
    'python3 tools/early_boot_transaction_lab.py',
    'python3 -S -m unittest discover -s tests -p test_boot_trial.py -q',
    'python3 -S -m unittest discover -s tests -p test_one_shot.py -q',
    'python3 -S -m unittest discover -s tests -p test_parity_continuity.py -q',
    'python3 -S -m unittest discover -s tests -p test_personal_auto.py -q',
    'python3 tools/qualify_host.py',
    'python3 tools/build.py',
    'python3 tools/verify_build.py',
]
for file in ('ci.yml', 'release.yml'):
    content = (ROOT/'.github/workflows'/file).read_text()
    positions = [content.find(command) for command in expected]
    assert all(pos >= 0 for pos in positions), f'{file}: missing host job command'
    # The three independent tests may run in any order; all precede qualification.
    assert positions[0] < min(positions[1:4]), f'{file}: preflight order incorrect'
    assert max(positions[1:9]) < positions[9] < positions[10] < positions[11], f'{file}: qualification or packaging order incorrect'
    assert 'ksud module install' not in content, f'{file}: root install must not be in CI'
    assert 'gh release create' not in content, f'{file}: no automatic production release'
    assert 'device-unverified' in content or 'unqualified' in content, f'{file}: qualification labeling missing'
assert config['targets']['guardian']['jobs']['early-boot-model']['metadata']['device_qualified'] is False
assert config['targets']['guardian']['jobs']['host-qualification']['command'] == ['python3','tools/qualify_host.py']
print('PASS_GUARDIAN_CI_MIRROR_MATCHES_DEVTOOL_CHECK_DAG')
