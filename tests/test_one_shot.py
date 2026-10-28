"""Disposable real SQLite fixture for once-only live-file swap; NEVER the host's real Vector DB."""
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BID1='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
BID2='11111111-2222-3333-4444-555555555555'

class OnceOnlyTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='guardian-onceonly-')
        self.addCleanup(self.tmp.cleanup)
        self.d=Path(self.tmp.name)
        self.state=self.d/'state';self.state.mkdir()
        self.dir=self.d/'vector';self.dir.mkdir()
        self.db=self.dir/'modules_config.db'
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE modules (module_pkg_name TEXT, enabled INTEGER, apk_path TEXT)')
            c.execute("INSERT INTO modules VALUES ('eu.hxreborn.remembermysort',1,'test.apk')")
            c.execute('CREATE TABLE scope (module_id INTEGER, app_pkg_name TEXT)')
            c.execute('CREATE TABLE configs (module_id INTEGER, name TEXT)')
        self.wal=Path(str(self.db)+'-wal');self.wal.write_bytes(b'original wal')
        self.shm=Path(str(self.db)+'-shm');self.shm.write_bytes(b'original shm')
        self.jrnl=Path(str(self.db)+'-journal')
        self.orig=self.family()
        self.rdb=self.d/'rescue.db';self.rdb.write_bytes(self.db.read_bytes())
        self.bin=self.d/'bin';self.bin.mkdir()
        def mk(name, body):
            p=self.bin/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
        mk('getprop','if [ "$1" = sys.boot_completed ]; then echo "${MOCK_BOOTED:-1}"; fi')
        mk('pidof','if [ "$1" = vectord ]; then [ "${MOCK_DAEMON:-0}" = 1 ] && echo 1001; exit 0; fi; if [ "$1" = com.android.systemui ]; then echo 333; fi')
        mk('ls','if [ "$1" = -Z ]; then echo "-rw-rw---- 1 root root u:object_r:system_file:s0 sample"; exit 0; fi; exec /bin/ls "$@"')
        mk('stat','if [ "$1" = -c ]; then case "$2" in %u:%g) echo 0:0;; %a) echo 660;; *) exit 1;; esac; exit 0; fi; exec /usr/bin/stat "$@"')
        mk('chcon','exit "${MOCK_CHCON_FAIL:-0}"')
        # A Termux test runner is not uid 0. Simulate the kernel-level
        # privileges only inside this disposable fixture; production still
        # requires *real* root and still calls chown/chcon unmodified.
        mk('id', '''if [ "$1" = -u ]; then echo "${MOCK_EUID:-0}"; exit 0; fi
exec /usr/bin/id "$@"''')
        mk('chown', '''[ "$1" = 0:0 ] || exit 2
case "$2" in
  "$GUARDIAN_VECTOR_DB"*|"$GUARDIAN_OFFLINE_SAVE_ROOT"/*)
    exit "${MOCK_CHOWN_FAIL:-0}" ;;
  *) exit 2 ;;
esac''')
        mk('mv','if [ "${MOCK_FAIL_STAGE_MOVE:-0}" = 1 ] && [ "$1" = "$GUARDIAN_VECTOR_DB.guardian-oneshot-stage" ]; then exit 1; fi; exec /bin/mv "$@"')
        mk('sleep','exit 0')
        sql=self.bin/'sqlite3'
        sql.write_text("""#!/usr/bin/env -S python3 -S
import sqlite3,sys
args=sys.argv[1:]
if args[0]=='-readonly':args=args[1:]
filename,statement=args
try:
    with sqlite3.connect('file:'+filename+'?mode=ro',uri=True) as conn:
        for row in conn.execute(statement):print('|'.join(map(str,row)))
except Exception as exc:
    print(str(exc),file=sys.stderr)
    raise SystemExit(1)
""")
        sql.chmod(0o755)
        mk('vectorcli', '''if [ "$1" = status ]; then echo 'Vector ready'; exit 0; fi
if [ "$1" = --json ] && [ "$2" = modules ] && [ "$3" = ls ]; then echo '{"success": true, "data": [{"PACKAGE": "eu.hxreborn.remembermysort"}]}'; exit 0; fi
if [ "$1" = db ] && [ "$2" = backup ]; then cp "$GUARDIAN_VECTOR_DB" "$3"; exit 0; fi
exit 1''')
        self.prop=self.d/'module.prop';self.prop.write_text('id=zygisk_vector\nversionCode=3112\n')
        self.boot=self.d/'boot-id';self.boot.write_text(BID1+'\n')
        self.rescue=self.d/'rescue.sh';self.rescue.write_text('#!/bin/sh\necho "backup_integrity=${MOCK_RESCUE:-PASS}"\n')
        self.env={**os.environ,'GUARDIAN_STATE_DIR':str(self.state),'GUARDIAN_VECTOR_DB':str(self.db),
                'GUARDIAN_VECTOR_CLI':str(self.bin/'vectorcli'),'GUARDIAN_VECTOR_MODULE_PROP':str(self.prop),
                'GUARDIAN_BOOT_ID_PATH':str(self.boot),'GUARDIAN_RESCUE_SCRIPT':str(self.rescue),
                'GUARDIAN_RESCUE_DB':str(self.rdb),'GUARDIAN_SQLITE_CLI':str(self.bin/'sqlite3'),'GUARDIAN_LOCK_DIR':str(self.d/'lock'),'GUARDIAN_OFFLINE_SAVE_ROOT':str(self.d/'emergency'),
                'GUARDIAN_MODULE_DIR':str(self.d/'installed_module'),
                'PATH':str(self.bin)+':'+os.environ['PATH']}
        cfg=(ROOT/'config.defaults').read_text().replace('PASSIVE_CRASH_MONITOR=1','PASSIVE_CRASH_MONITOR=0').replace('HISTORY_MONITOR=1','HISTORY_MONITOR=0').replace('STABILITY_SECONDS=60','STABILITY_SECONDS=15')
        (self.state/'config.conf').write_text(cfg)
        (self.state/'boot').mkdir();(self.state/'boot/last-success-id').write_text(BID1+'\n')
        trial=self.state/'boot-trial';trial.mkdir()
        (trial/'early.txt').write_text(f'observed_boot_id={BID1}\nassessment=PASS_COPY_ONLY\n')
        (trial/'stable.txt').write_text(f'observed_boot_id={BID1}\nvector=VECTOR_RESPONDING\n')
    def family(self):
        return {str(p):p.read_bytes() for p in (self.db,self.wal,self.shm) if p.exists()}
    def call(self,*args, env=None, expected=0):
        p=subprocess.run(['sh',str(ROOT/args[0]),*args[1:]],cwd=self.d,env=env or self.env,text=True,capture_output=True,timeout=30)
        self.assertEqual(p.returncode,expected,f'{args}: code {p.returncode}: {p.stdout}\n{p.stderr}')
        return p.stdout+p.stderr
    def stage(self):
        self.assertIn('PASS_GUARDIAN_ONE_SHOT_STAGED',self.call('guardian.sh','one-shot-stage','--apply'))
    def boot_again(self, **extra):
        self.boot.write_text(BID2+'\n')
        return self.call('post-fs-data.sh',env={**self.env,'MOCK_BOOTED':'0',**extra})
    def test_complete_real_file_swap_and_health(self):
        self.stage();self.boot_again()
        result=(self.state/'one-shot/early.txt').read_text()
        self.assertIn('assessment=COMMITTED_PENDING_HEALTH',result)
        self.assertEqual(self.db.read_bytes(),self.rdb.read_bytes())
        self.assertFalse(self.wal.exists());self.assertFalse(self.shm.exists())
        self.assertEqual((self.state/'one-shot/transaction/original.db-wal').read_bytes(),self.orig[str(self.wal)])
        self.call('service.sh')
        self.assertIn('PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE',self.call('guardian.sh','one-shot-status'))
        self.assertTrue((self.state/'one-shot/transaction/original.db').exists())
    def test_v094_stable_boot_auto_finalizes_receipt(self):
        self.stage();self.boot_again();self.call('service.sh')
        phase=self.state/'one-shot/transaction/phase'
        self.assertEqual(phase.read_text().strip(),'HEALTH_CONFIRMED')
        receipt=self.call('guardian.sh','one-shot-status')
        self.assertIn('finalization=HEALTH_CONFIRMED',receipt)
        self.assertIn('PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE',receipt)
        qual=self.call('guardian.sh','qualification')
        self.assertIn('actual_early_boot_restore_test=PASS_MANUAL_ONE_SHOT_RECEIPT',qual)
        self.assertIn('device_restore_qualification=UNQUALIFIED',qual)
        self.assertEqual(self.db.read_bytes(),self.rdb.read_bytes())

    def test_v094_finalize_legacy_healthy_receipt_later_boot(self):
        self.stage();self.boot_again();self.call('service.sh')
        phase=self.state/'one-shot/transaction/phase'
        phase.write_text('COMMITTED_PENDING_HEALTH\n')
        # This migrates the real v0.9.3 receipt without changing live data.
        self.boot.write_text(BID1+'\n')
        self.assertIn('PASS_GUARDIAN_ONE_SHOT_HEALTH_FINALIZED',
                      self.call('guardian.sh','one-shot-finalize'))
        self.assertEqual(phase.read_text().strip(),'HEALTH_CONFIRMED')
        self.assertIn('PASS_GUARDIAN_ONE_SHOT_HEALTH_FINALIZED',
                      self.call('guardian.sh','one-shot-finalize'))

    def test_v094_finalize_rejects_damaged_original_and_never_changes_db(self):
        self.stage();self.boot_again();self.call('service.sh')
        phase=self.state/'one-shot/transaction/phase';phase.write_text('COMMITTED_PENDING_HEALTH\n')
        original=self.state/'one-shot/transaction/original.db'
        original.write_bytes(b'DAMAGED')
        before=self.family()
        self.call('guardian.sh','one-shot-finalize',expected=1)
        self.assertEqual(self.family(),before)
        self.assertEqual(phase.read_text().strip(),'COMMITTED_PENDING_HEALTH')
        self.assertNotIn('PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE',
                         self.call('guardian.sh','one-shot-status'))

    def test_v094_finalize_rejects_failed_health_receipt(self):
        self.stage();self.boot_again();self.call('service.sh')
        phase=self.state/'one-shot/transaction/phase';phase.write_text('COMMITTED_PENDING_HEALTH\n')
        health=self.state/'one-shot/stable.txt'
        health.write_text(health.read_text().replace('health=PASS','health=FAILED'))
        self.call('guardian.sh','one-shot-finalize',expected=1)
        self.assertEqual(phase.read_text().strip(),'COMMITTED_PENDING_HEALTH')

    def test_v094_historical_quarantine_ledger_pair_is_reported_without_arming(self):
        qdir=self.state/'quarantine';qdir.mkdir(exist_ok=True)
        a='a'*64;b='b'*64
        (qdir/'events.tsv').write_text(
            f'QUARANTINED\teu.hxreborn.remembermysort\t123\t{BID1}\t3112\tMANUAL_UNATTRIBUTED\t{a}\t{b}\n'
            f'ROLLED_BACK\teu.hxreborn.remembermysort\t124\t{BID1}\t3112\tMANUAL_UNATTRIBUTED\t{b}\t{a}\n')
        qual=self.call('guardian.sh','qualification')
        self.assertIn('live_quarantine_roundtrip=PASS_HISTORICAL_LEDGER_PAIR',qual)
        self.assertIn('device_restore_qualification=UNQUALIFIED',qual)
        self.assertIn('automatic_quarantine=DISABLED',qual)
        (qdir/'events.tsv').write_text(f'QUARANTINED\teu.hxreborn.remembermysort\t123\t{BID1}\t3112\tMANUAL_UNATTRIBUTED\t{a}\t{b}\n')
        self.assertIn('live_quarantine_roundtrip=NOT_VERIFIED',self.call('guardian.sh','qualification'))

    def test_v094_crash_audit_is_read_only(self):
        f=self.state/'crashes/events.tsv'; f.parent.mkdir(exist_ok=True)
        f.write_text('abc\t1793130000\tcom.example\t123\n')
        before=f.read_bytes()
        audit=self.call('guardian.sh','crash-audit')
        self.assertIn('retained_events=1',audit)
        self.assertIn('retention_delta=UNKNOWN_WITHOUT_PRIOR_FILE_OR_TRIM_RECEIPT',audit)
        self.assertEqual(f.read_bytes(),before)

    def test_custom_recovery_offline_undo_restores_original_family(self):
        self.stage();self.boot_again()
        self.assertEqual(self.db.read_bytes(),self.rdb.read_bytes())
        self.call('one-shot-offline-undo.sh','restore','--offline',env={**self.env,'MOCK_BOOTED':'0'})
        self.assertEqual(self.family(),self.orig)
        self.assertTrue((self.d/'installed_module/disable').exists())
        self.assertTrue(list((self.d/'emergency').glob('one-shot-emergency-*/RESTORE_CONFIRMED')))

    def test_custom_recovery_undo_rejects_booted_android(self):
        self.stage();self.boot_again()
        self.call('one-shot-offline-undo.sh','restore','--offline',expected=1)
        self.assertEqual(self.db.read_bytes(),self.rdb.read_bytes())
        self.assertFalse((self.d/'installed_module/disable').exists())

    def test_refuses_unverified_rescue(self):
        self.call('guardian.sh','one-shot-preflight',env={**self.env,'MOCK_RESCUE':'FAIL'},expected=1)
        self.assertEqual(self.family(),self.orig)
    def test_refuses_changed_enabled_modules(self):
        with sqlite3.connect(self.rdb) as c:c.execute('UPDATE modules SET enabled=0')
        self.call('guardian.sh','one-shot-stage','--apply',expected=1)
        self.assertEqual(self.family(),self.orig)
    def test_refuses_bad_selinux_metadata(self):
        (self.bin/'ls').write_text('#!/bin/sh\necho wrong_context\n')
        self.call('guardian.sh','one-shot-preflight',expected=1)
        self.assertEqual(self.family(),self.orig)
    def test_refuses_running_vector(self):
        self.stage();self.boot_again(MOCK_DAEMON='1')
        self.assertIn('assessment=REFUSED',(self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)
    def test_refuses_late_boot(self):
        self.stage();self.boot_again(MOCK_BOOTED='1')
        self.assertIn('assessment=REFUSED',(self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)
    def test_refuses_tampered_payload(self):
        self.stage();(self.state/'one-shot/payload.db').write_bytes(b'tamper')
        self.boot_again()
        self.assertIn('snapshot_changed_or_invalid',(self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)
    def test_stage_cancel_is_non_mutating(self):
        self.stage();self.call('guardian.sh','one-shot-cancel')
        self.boot_again();self.assertEqual(self.family(),self.orig)
    def test_staging_is_one_time(self):
        self.stage();self.call('guardian.sh','one-shot-stage','--apply',expected=1)
        self.boot_again();self.call('post-fs-data.sh',env={**self.env,'MOCK_BOOTED':'0'})
        self.assertEqual((self.state/'one-shot/transaction/phase').read_text().strip(),'COMMITTED_PENDING_HEALTH')
    def test_refuse_mutation_if_chcon_fails(self):
        self.stage();self.boot_again(MOCK_CHCON_FAIL='1')
        self.assertIn('assessment=REFUSED',(self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)
    def test_restore_rejects_unprivileged_identity(self):
        # The root requirement is NOT removed from production: this verifies
        # the actual recovery script rejects the non-root fixture identity.
        self.stage();self.boot_again()
        out=self.call('one-shot-offline-undo.sh','restore','--offline',
                      env={**self.env,'MOCK_BOOTED':'0','MOCK_EUID':'2000'}, expected=1)
        self.assertIn('root required',out)
        self.assertEqual(self.db.read_bytes(),self.rdb.read_bytes())
        self.assertFalse((self.d/'installed_module/disable').exists())

    def test_stage_refuses_failed_ownership_repair(self):
        # Fail-closed even when Vector is absent and backup checks pass.
        self.stage();self.boot_again(MOCK_CHOWN_FAIL='1')
        self.assertIn('assessment=REFUSED',(self.state/'one-shot/early.txt').read_text())
        self.assertIn('reason=staged_file_cannot_be_verified',
                      (self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)

    def test_swap_failure_replays_original_family_in_same_boot(self):
        self.stage();self.boot_again(MOCK_FAIL_STAGE_MOVE='1')
        report=(self.state/'one-shot/early.txt').read_text()
        self.assertIn('assessment=ABORTED',report)
        self.assertEqual(self.family(),self.orig)
        phase=(self.state/'one-shot/transaction/phase').read_text().strip()
        self.assertEqual(phase,'ABORTED_ORIGINAL_RESTORED')
        self.assertNotIn('PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE',self.call('guardian.sh','one-shot-status'))

    def test_incomplete_transaction_not_retried_or_qualified(self):
        self.stage()
        tx=self.state/'one-shot/transaction';tx.mkdir()
        (tx/'phase').write_text('SWAP_STARTED\n')
        # Deliberately incomplete preserved copy forces CUSTOM RECOVERY without mutation.
        self.boot_again()
        self.assertIn('assessment=NEEDS_CUSTOM_RECOVERY',(self.state/'one-shot/early.txt').read_text())
        self.assertEqual(self.family(),self.orig)
        self.assertNotIn('PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE',self.call('guardian.sh','one-shot-status'))

    def test_refuse_when_armed(self):
        f=self.state/'config.conf';f.write_text(f.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self.call('guardian.sh','one-shot-stage','--apply',expected=1)
        self.assertEqual(self.family(),self.orig)
if __name__=='__main__':unittest.main()
