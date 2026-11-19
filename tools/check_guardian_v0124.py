#!/usr/bin/env python3
"""Source-bound Guardian v0.12.4 host qualification through existing test gates.

The 71 core tests use Guardian's existing hermetic, source-fingerprinted
``run_host_tests.py`` and ``qualify_host.py``—the same gates as hosted CI.
All remaining Python suites run with real unittest, dynamically verified
inventory, and bounded subdivisions for slow Termux cases. Two independent
lanes run concurrently to meet the native hook budget without skipping tests.
Any missing test, child failure, unsupported runtime or deadline is fatal.
No overlay, Git, recovery, device or CI implementation exists here.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
SUPPORTED = (
    'test_vector_compat.py', 'test_softlock.py',
    'test_softlock_extended.py', 'test_backup_vault.py',
    'test_guardian.py', 'test_one_shot.py',
    'test_personal_auto.py', 'test_parity_continuity.py',
    'test_devtool_contract.py', 'test_boot_probe.py',
    'test_boot_trial.py',
)
# Hook max is 1500s. Reserve ≥150s for JSON receipt/Devtool cleanup.
HOST_BUDGET_SECONDS = 1320
CASE_TIMEOUT_SECONDS = 150
SPLIT_SIZES = {'test_backup_vault.py': 3, 'test_one_shot.py': 7}


def suite_cases(filename):
    """Discover actual current test IDs: zero tests or duplicate IDs is fatal."""
    loader = unittest.TestLoader()
    suite = loader.discover(str(TESTS), pattern=filename, top_level_dir=str(TESTS))
    def flatten(node):
        for item in node:
            if isinstance(item, unittest.TestSuite):
                yield from flatten(item)
            else:
                yield item
    cases = list(flatten(suite))
    ids = [case.id() for case in cases]
    if not ids or len(ids) != len(set(ids)):
        raise RuntimeError('Empty or duplicated suite: ' + filename)
    if not all(i.startswith(Path(filename).stem + '.') for i in ids):
        raise RuntimeError('Unexpected unittest discovery result: ' + filename)
    return tuple(sorted(ids))


def batches(filename):
    ids = suite_cases(filename)
    cap = SPLIT_SIZES.get(filename)
    if not cap:
        return [(sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
                 'tests', '-p', filename, '-q')], len(ids)
    result=[]
    for start in range(0,len(ids),cap):
        result.append((sys.executable,'-B','-m','unittest','-q',*ids[start:start+cap]))
    if sum(len(argv)-5 for argv in result) != len(ids):
        raise RuntimeError('Unittest batch coverage differs: ' + filename)
    return result,len(ids)


def execute(argv, *, deadline, limit=CASE_TIMEOUT_SECONDS, cwd=ROOT):
    remain = deadline - time.monotonic()
    if remain <= 2:
        raise RuntimeError('Guardian validation budget exhausted before: ' + str(argv))
    print('GUARDIAN_V0124_CHECK ' + ' '.join(map(str, argv)),flush=True)
    try:
        proc=subprocess.run(argv,cwd=cwd,check=False,timeout=min(limit,remain))
    except (OSError,subprocess.TimeoutExpired) as exc:
        raise RuntimeError('GUARDIAN_V0124_FAIL ' + type(exc).__name__ + ': ' + str(exc)) from exc
    if proc.returncode:
        raise RuntimeError('GUARDIAN_V0124_FAIL rc=' + str(proc.returncode) +
                           ' cmd=' + ' '.join(map(str,argv)))


def core_lane(deadline):
    execute((sys.executable, '-B', 'tools/run_host_tests.py', '--workers', '2',
             '--timeout', '180'),deadline=deadline,limit=1000)
    execute((sys.executable, '-B', 'tools/qualify_host.py'),deadline=deadline,limit=90)
    return len(suite_cases('test_guardian.py'))  # independently verified by qualify_host.py


def remaining_lane(deadline):
    covered=0
    for name in SUPPORTED:
        if name == 'test_guardian.py':continue
        jobs,count=batches(name)
        for command in jobs:
            cwd=TESTS if name in SPLIT_SIZES else ROOT
            execute(command,deadline=deadline,cwd=cwd)
        print('GUARDIAN_V0124_SUITE_PASS',name,'discovered_tests='+str(count),flush=True)
        covered+=count
    return covered


def main():
    actual={p.name for p in TESTS.glob('test_*.py') if p.is_file()}
    if actual!=set(SUPPORTED):
        raise RuntimeError('Unreviewed or missing tests: '+str(sorted(actual^set(SUPPORTED))))
    total_expected=sum(len(suite_cases(name)) for name in SUPPORTED)
    print('GUARDIAN_V0124_INVENTORY',total_expected,'test cases across',len(SUPPORTED),'files',flush=True)
    deadline=time.monotonic()+HOST_BUDGET_SECONDS
    execute((sys.executable,'-B','tools/check_repo.py'),deadline=deadline,limit=90)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=(pool.submit(core_lane,deadline),pool.submit(remaining_lane,deadline))
        outcomes=[]
        failures=[]
        for future in futures:
            try:outcomes.append(future.result())
            except Exception as exc:failures.append(str(exc))
    if failures:
        raise RuntimeError('GUARDIAN_V0124_REQUIRED_TEST_FAILURE '+'; '.join(failures))
    if sum(outcomes)!=total_expected:
        raise RuntimeError('Test case inventory mismatch; expected='+str(total_expected)+
                           ' completed='+str(sum(outcomes)))
    print('GUARDIAN_V0124_ALL_PYTHON_TESTS_PASS',total_expected,flush=True)
    for argv,timeout in (
        (('node','tests/test_webui.js'),180),
        ((sys.executable,'-B','tools/build.py'),180),
        ((sys.executable,'-B','tools/verify_build.py'),120),
        ((sys.executable,'-B','tools/early_boot_transaction_lab.py'),180),
    ):
        execute(argv,deadline=deadline,limit=timeout)
    print('PASS_GUARDIAN_V0124_TARGETED_HOST_ONLY',
          'device_qualified=false',
          'required_native_validation=true',flush=True)


if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('GUARDIAN_V0124_FAIL '+str(exc),file=sys.stderr,flush=True)
        raise SystemExit(1)
