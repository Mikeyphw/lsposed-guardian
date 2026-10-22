"""Opt-in real-boot copy-only WAL rehearsal never writes to the live Vector DB family."""
import hashlib, os, pathlib, sqlite3, subprocess, tempfile, unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
class BootTrialTests(unittest.TestCase):
    def setUp(self):
        d=tempfile.TemporaryDirectory(prefix='guardian-trial-fixture-')
        self.addCleanup(d.cleanup)
        self.base=pathlib.Path(d.name)
        self.state=self.base/'state';self.state.mkdir()
        self.db=self.base/'vector_config/modules_config.db';self.db.parent.mkdir()
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE modules (module_pkg_name TEXT, enabled INTEGER, apk_path TEXT)')
            c.execute('CREATE TABLE scope (mid INTEGER, app_pkg_name TEXT)')
            c.execute('CREATE TABLE configs (module_pkg_name TEXT, data BLOB)')
        self.db.with_name(self.db.name+'-wal').write_bytes(b'original WAL test sidecar')
        self.db.with_name(self.db.name+'-shm').write_bytes(b'original SHM test sidecar')
        self.boot=self.base/'boot-id';self.boot.write_text('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.bin=self.base/'bin';self.bin.mkdir()
        def fake(n,s):
            p=self.bin/n;p.write_text(s);p.chmod(0o755)
        fake('getprop','#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo "${FIXTURE_BOOTED:-1}"\n')
        fake('pidof','#!/bin/sh\nif [ "$1" = vectord ] && [ "${FIXTURE_VECTOR_RUNNING:-0}" = 1 ]; then echo 441; exit 0; fi\n[ "$1" = com.android.systemui ] && { echo 333; exit 0; }; exit 1\n')
        fake('getensforce','#!/bin/sh\necho Enforcing\n')
        fake('vectorcli','#!/bin/sh\nif [ "$1" = status ]; then echo "Vector available"; exit 0; fi\nif [ "$1" = db ] && [ "$2" = backup ]; then cp "$GUARDIAN_VECTOR_DB" "$3"; exit 0; fi\nexit 1\n')
        fake('sleep','#!/bin/sh\nexit 0\n')
        self.prop=self.base/'vector.prop';self.prop.write_text('id=zygisk_vector\nversionCode=3112\n')
        self.rescue=self.base/'rescue.sh';self.rescue.write_text('#!/bin/sh\necho "backup_integrity=${FIXTURE_RESCUE:-PASS}"\n')
        self.env={**os.environ,'GUARDIAN_STATE_DIR':str(self.state),'GUARDIAN_VECTOR_DB':str(self.db),
             'GUARDIAN_VECTOR_CLI':str(self.bin/'vectorcli'),'GUARDIAN_VECTOR_MODULE_PROP':str(self.prop),
             'GUARDIAN_BOOT_ID_PATH':str(self.boot),'GUARDIAN_RESCUE_SCRIPT':str(self.rescue),
             'GUARDIAN_LOCK_DIR':str(self.base/'service-lock'),'PATH':str(self.bin)+':'+os.environ['PATH']}
        (self.state/'config.conf').write_text((ROOT/'config.defaults').read_text().replace('PASSIVE_CRASH_MONITOR=1','PASSIVE_CRASH_MONITOR=0').replace('HISTORY_MONITOR=1','HISTORY_MONITOR=0'))
        (self.state/'boot').mkdir()
        (self.state/'boot/last-success-id').write_text(self.boot.read_text())
        bp=self.state/'boot-probe';bp.mkdir()
        bid=self.boot.read_text().strip()
        (bp/'early.txt').write_text(f'observed_boot_id={bid}\nassessment=EARLY_CANDIDATE\n')
        (bp/'stable.txt').write_text(f'observed_boot_id={bid}\nvector=VECTOR_RESPONDING\n')
        snap=self.state/'snapshots';snap.mkdir()
        (snap/'observed.db').write_bytes(self.db.read_bytes())
        src=snap/'observed.db';h=hashlib.sha256(src.read_bytes()).hexdigest()
        (snap/'observed.sha256').write_text(h+'\n')
        (snap/'observed.bytes').write_text(str(src.stat().st_size)+'\n')
        (snap/'observed.validation').write_text('sqlite_integrity_verified\n')
        (snap/'observed.vector-version').write_text('3112\n')
        (snap/'observed.complete').write_text(bid+'\n')
        (snap/'observed.boot-id').write_text(bid+'\n')
        self.original=self.family()
    def family(self):
        return {suffix:pathlib.Path(str(self.db)+suffix).read_bytes() for suffix in ('','-wal','-shm')}
    def run_script(self,script,*args,env=None,rc=0):
        p=subprocess.run(['sh',str(ROOT/script),*args],env=env or self.env,text=True,capture_output=True,timeout=25)
        self.assertEqual(p.returncode,rc,f'{script}: rc={p.returncode} {p.stdout} {p.stderr}')
        return p.stdout+p.stderr
    def stage(self):
        self.assertIn('PASS_GUARDIAN_BOOT_TRIAL_STAGED',self.run_script('guardian.sh','boot-trial-stage','--apply'))
    def new_boot(self,*,pid='0',booted='0'):
        self.boot.write_text('11111111-2222-3333-4444-555555555555\n')
        return self.run_script('post-fs-data.sh',env={**self.env,'FIXTURE_VECTOR_RUNNING':pid,'FIXTURE_BOOTED':booted})
    def test_success_copy_only_with_wal_and_shm(self):
        self.stage(); self.new_boot()
        report=(self.state/'boot-trial/early.txt').read_text()
        self.assertIn('assessment=PASS_COPY_ONLY',report)
        self.assertIn('wal_present=yes',report);self.assertIn('shm_present=yes',report)
        self.assertEqual(self.family(),self.original)
        self.run_script('service.sh')
        self.assertIn('PASS_GUARDIAN_REAL_BOOT_COPY_ONLY_TRIAL',self.run_script('guardian.sh','boot-trial-status'))
        self.assertEqual(self.family(),self.original)
    def test_stage_denied_without_verified_rescue(self):
        self.run_script('guardian.sh','boot-trial-stage','--apply',env={**self.env,'FIXTURE_RESCUE':'FAIL'},rc=1)
        self.assertFalse((self.state/'boot-trial/request').exists())
        self.assertEqual(self.family(),self.original)
    def test_stage_denied_without_matching_real_boot_receipt(self):
        (self.state/'boot-probe/stable.txt').write_text('observed_boot_id=bad\nvector=VECTOR_RESPONDING\n')
        self.run_script('guardian.sh','boot-trial-stage','--apply',rc=1)
        self.assertEqual(self.family(),self.original)
    def test_refuse_when_daemon_running(self):
        self.stage();self.new_boot(pid='1')
        self.assertIn('reason=unsafe_boot_state',(self.state/'boot-trial/early.txt').read_text())
        self.assertEqual(self.family(),self.original)
        self.assertNotIn('PASS_GUARDIAN_REAL_BOOT_COPY_ONLY_TRIAL',self.run_script('guardian.sh','boot-trial-status'))
    def test_refuse_when_hook_too_late(self):
        self.stage();self.new_boot(booted='1')
        self.assertIn('assessment=REFUSED',(self.state/'boot-trial/early.txt').read_text())
        self.assertEqual(self.family(),self.original)
    def test_cancel_stage(self):
        self.stage();self.run_script('guardian.sh','boot-trial-cancel')
        self.assertFalse((self.state/'boot-trial/request').exists())
        self.new_boot();self.assertFalse((self.state/'boot-trial/early.txt').exists())
        self.assertEqual(self.family(),self.original)
    def test_reject_changed_snapshot_after_stage(self):
        self.stage()
        (self.state/'snapshots/observed.db').write_bytes(b'tampered')
        self.new_boot()
        self.assertIn('reason=snapshot_digest_mismatch',(self.state/'boot-trial/early.txt').read_text())
        self.assertEqual(self.family(),self.original)
    def test_stage_once_only_and_no_auto_retry(self):
        self.stage();self.run_script('guardian.sh','boot-trial-stage','--apply',rc=1)
        self.new_boot();self.run_script('post-fs-data.sh',env={**self.env,'FIXTURE_BOOTED':'0'})
        self.assertFalse((self.state/'boot-trial/request').exists())
        self.assertEqual(self.family(),self.original)
    def test_refuse_when_automatic_recovery_armed(self):
        f=self.state/'config.conf';f.write_text(f.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self.run_script('guardian.sh','boot-trial-stage','--apply',rc=1)
        self.assertFalse((self.state/'boot-trial/request').exists())
        self.assertEqual(self.family(),self.original)
if __name__=='__main__':unittest.main()
