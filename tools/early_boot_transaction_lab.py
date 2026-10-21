#!/usr/bin/env python3
"""Isolated, fault-injected SQLite WAL restore transaction *model*.

The code in this file is NOT used by Guardian's real post-fs-data service.
All paths are owned by a fresh TemporaryDirectory. Its purpose is to find
interruption/sidecar mistakes before a separate, disposable-Android device gate.
Never feed the production Vector DB to this harness.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile

SIDECARS = ("-wal", "-shm", "-journal")
CHECKPOINTS = ("prepared", "retired-wal", "retired-shm", "retired-journal", "swapped-db", "verified", "committed-unverified")


class InjectedInterruption(Exception):
    pass


class Refusal(Exception):
    pass


def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def syncdir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_copy(src: Path, dest: Path) -> None:
    shutil.copy2(src, dest)
    with dest.open('rb') as f:
        os.fsync(f.fileno())
    syncdir(dest.parent)


def durable_marker(path: Path, obj: dict) -> None:
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w', encoding='utf-8') as f:
        json.dump(obj, f, sort_keys=True)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    syncdir(path.parent)


def make_fixture(work: Path):
    """Use a real live SQLite WAL with unapplied committed rows."""
    origin = work / 'origin'
    origin.mkdir()
    db = origin / 'modules_config.db'
    conn = sqlite3.connect(db)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA wal_autocheckpoint=0')
    conn.execute('CREATE TABLE settings (value TEXT)')
    conn.commit()
    conn.execute("INSERT INTO settings VALUES ('old-wal-value')")
    conn.commit()
    live = work / 'live'
    live.mkdir()
    for suffix in ('', '-wal', '-shm'):
        src = Path(str(db) + suffix)
        if not src.exists():
            raise AssertionError('WAL test fixture has no ' + suffix)
        durable_copy(src, Path(str(live / db.name) + suffix))
    # The fixture must contain a committed row not yet in the main database.
    conn.close()
    restore = work / 'verified_snapshot.db'
    c = sqlite3.connect(restore)
    c.execute('CREATE TABLE settings (value TEXT)')
    c.execute("INSERT INTO settings VALUES ('restored-value')")
    c.commit()
    c.close()
    return live / db.name, restore


def query(db: Path) -> str:
    with sqlite3.connect(db) as c:
        row = c.execute('SELECT value FROM settings').fetchone()
        assert row
        return str(row[0])


class CandidateProtocol:
    """Prototype of an on-boot transaction; not installed or device-qualified."""
    def __init__(self, db: Path, snapshot: Path):
        self.db, self.snapshot = db, snapshot
        self.txn = db.parent / '.guardian-prototype-txn'
        self.marker = self.txn / 'phase.json'

    def interrupt(self, at: str | None, point: str) -> None:
        if at == point:
            raise InjectedInterruption(point)

    def prepare(self) -> None:
        if self.txn.exists():
            raise Refusal('Existing unfinished transaction; reconcile first')
        if query(self.snapshot) != 'restored-value':
            raise Refusal('Snapshot validation failed')
        self.txn.mkdir(mode=0o700)
        durable_copy(self.db, self.txn / 'old.db')
        durable_copy(self.snapshot, self.txn / 'stage.db')
        found = []
        for suffix in SIDECARS:
            side = Path(str(self.db) + suffix)
            if side.exists():
                durable_copy(side, self.txn / ('old' + suffix))
                found.append(suffix)
        durable_marker(self.marker, {'phase': 'PREPARED', 'db_hash': digest(self.txn / 'old.db'),
                                    'stage_hash': digest(self.txn / 'stage.db'), 'sidecars': found})

    def apply(self, at: str | None = None) -> None:
        self.prepare()
        self.interrupt(at, 'prepared')
        # Journal and backup are durable *before* any destructive mutation.
        for suffix, name in zip(SIDECARS, ('retired-wal', 'retired-shm', 'retired-journal')):
            src = Path(str(self.db) + suffix)
            if src.exists():
                os.replace(src, self.txn / ('retired' + suffix))
                syncdir(self.db.parent)
                syncdir(self.txn)
            self.interrupt(at, name)
        os.replace(self.txn / 'stage.db', self.db)
        syncdir(self.db.parent)
        self.interrupt(at, 'swapped-db')
        manifest = json.loads(self.marker.read_text())
        if digest(self.db) != manifest['stage_hash'] or query(self.db) != 'restored-value':
            raise Refusal('Committed candidate failed integrity')
        self.interrupt(at, 'verified')
        durable_marker(self.marker, {**manifest, 'phase': 'COMMITTED_UNVERIFIED'})
        self.interrupt(at, 'committed-unverified')

    def recover_before_daemon(self, daemon_running: bool = False) -> None:
        if daemon_running:
            raise Refusal('Cannot reconcile while daemon is active')
        if not self.marker.is_file():
            raise Refusal('No recovery journal exists')
        metadata = json.loads(self.marker.read_text())
        old = self.txn / 'old.db'
        if digest(old) != metadata['db_hash']:
            raise Refusal('Old database backup digest mismatched')
        # Persistent old backups are NOT consumed. Recovery itself can be
        # retried safely after a second interruption.
        tmp = self.txn / 'rollback.db'
        durable_copy(old, tmp)
        for suffix in SIDECARS:
            live_side = Path(str(self.db) + suffix)
            if live_side.exists():
                live_side.unlink()
        os.replace(tmp, self.db)
        for suffix in metadata['sidecars']:
            durable_copy(self.txn / ('old' + suffix), Path(str(self.db) + suffix))
        syncdir(self.db.parent)
        if query(self.db) != 'old-wal-value':
            raise Refusal('Restored WAL-backed old state not verified')
        durable_marker(self.marker, {**metadata, 'phase': 'ROLLED_BACK_VERIFIED'})

    def mark_stable(self) -> None:
        if json.loads(self.marker.read_text()).get('phase') != 'COMMITTED_UNVERIFIED':
            raise Refusal('Cannot finalize before confirmed post-boot stability')
        if query(self.db) != 'restored-value':
            raise Refusal('Restored database not readable')
        # The lab cleans transaction evidence only *after* a stable marker.
        shutil.rmtree(self.txn)
        syncdir(self.db.parent)


def run_cases() -> dict:
    results = []
    for checkpoint in CHECKPOINTS:
        with tempfile.TemporaryDirectory(prefix='guardian-earlyboot-wal-') as tmp:
            db, source = make_fixture(Path(tmp))
            assert query(db) == 'old-wal-value'
            before = {suffix: digest(Path(str(db) + suffix)) for suffix in ('', '-wal', '-shm')}
            p = CandidateProtocol(db, source)
            try:
                p.apply(at=checkpoint)
                raise AssertionError('Missing interruption at ' + checkpoint)
            except InjectedInterruption as e:
                assert str(e) == checkpoint
            try:
                p.apply()
                raise AssertionError('Concurrent transaction not refused')
            except Refusal:
                pass
            try:
                p.recover_before_daemon(daemon_running=True)
                raise AssertionError('Reconcile permitted with active daemon')
            except Refusal:
                pass
            p.recover_before_daemon()
            assert query(db) == 'old-wal-value', checkpoint
            assert all(digest(Path(str(db) + suf)) == data for suf, data in before.items()), checkpoint
            assert json.loads(p.marker.read_text())['phase'] == 'ROLLED_BACK_VERIFIED'
            results.append({'checkpoint': checkpoint, 'result': 'PASS', 'db_and_wal_preserved': True})
    with tempfile.TemporaryDirectory(prefix='guardian-earlyboot-wal-') as tmp:
        db, source = make_fixture(Path(tmp))
        p = CandidateProtocol(db, source)
        p.apply()
        assert query(db) == 'restored-value'
        assert p.marker.is_file(), 'Committed but unverified must retain rollback journal'
        p.mark_stable()
        assert not p.txn.exists()
        results.append({'checkpoint': 'confirmed-stable-finalize', 'result': 'PASS'})
    with tempfile.TemporaryDirectory(prefix='guardian-earlyboot-wal-') as tmp:
        db, source = make_fixture(Path(tmp))
        source.write_bytes(b'not sqlite')
        p = CandidateProtocol(db, source)
        try:
            p.apply()
            raise AssertionError('Invalid source not rejected')
        except (Refusal, sqlite3.DatabaseError):
            pass
        assert query(db) == 'old-wal-value'
        assert not p.txn.exists()
        results.append({'checkpoint': 'reject-corrupt-snapshot', 'result': 'PASS'})
    return {'schema': 'guardian-early-boot-prototype-lab-v1', 'result': 'PASS', 'cases': results,
            'cases_passed': len(results), 'real_vector_db_modified': False,
            'device_qualified': False, 'post_fs_data_code_modified': False,
            'note': 'Host filesystem simulator only; not a real powercut, SELinux or daemon ordering test'}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', help='Evidence JSON path; defaults to dist/early-boot-prototype-lab.json')
    args = ap.parse_args()
    outcome = run_cases()
    root = Path(__file__).resolve().parents[1]
    out = Path(args.output) if args.output else root / 'dist/early-boot-prototype-lab.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(outcome, indent=2, sort_keys=True) + '\n')
    for item in outcome['cases']:
        print('PASS_GUARDIAN_EARLY_BOOT_MODEL_' + item['checkpoint'].upper().replace('-', '_'))
    print(f'PASS_GUARDIAN_EARLY_BOOT_PROTOTYPE_LAB cases={outcome["cases_passed"]}')
    print('real_vector_db_modified=false device_qualified=false')
    print('evidence=' + str(out))


if __name__ == '__main__':
    main()
