"""Real boot order probe is opt-in and never mutates the Vector SQLite database."""
from pathlib import Path
import os
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BootProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='guardian-boot-probe-')
        self.addCleanup(self.tmp.cleanup)
        t=Path(self.tmp.name)
        self.state=t/'state';self.state.mkdir()
        self.service_lock=t/'service-lock'  # Fixture must never attempt writes under /dev.
        self.db=t/'vector.db'
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE TABLE modules (module_pkg_name TEXT PRIMARY KEY, enabled INTEGER, apk_path TEXT)')
            db.execute('CREATE TABLE scope (mid INTEGER, app_pkg_name TEXT, user_id INTEGER)')
            db.execute('CREATE TABLE configs (module_pkg_name TEXT, data BLOB)')
        self.before=self.db.read_bytes()
        self.boot=t/'boot-id';self.boot.write_text('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.fake=t/'bin';self.fake.mkdir()
        (self.fake/'getprop').write_text('#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo "${TEST_BOOT_COMPLETED:-1}"\n')
        (self.fake/'pidof').write_text('#!/bin/sh\n[ "$1" = vectord ] && [ "${TEST_VECTOR_RUNNING:-0}" = 1 ] && { echo 99; exit 0; }; [ "$1" = com.android.systemui ] && { echo 333; exit 0; }; exit 1\n')
        (self.fake/'vectorcli').write_text('#!/bin/sh\n[ "$1" = status ] && { echo "Framework Version: 2.2"; exit 0; }; [ "$1" = com.android.systemui ] && { echo 333; exit 0; }; exit 1\n')
        (self.fake/'sleep').write_text('#!/bin/sh\nexit 0\n')
        (self.fake/'getenforce').write_text('#!/bin/sh\necho Enforcing\n')
        for item in self.fake.iterdir():item.chmod(0o755)
        self.env=dict(os.environ,PATH=f'{self.fake}:{os.environ["PATH"]}',GUARDIAN_STATE_DIR=str(self.state),GUARDIAN_LOCK_DIR=str(self.service_lock),GUARDIAN_BOOT_ID_PATH=str(self.boot),GUARDIAN_VECTOR_DB=str(self.db),GUARDIAN_VECTOR_CLI=str(self.fake/'vectorcli'),GUARDIAN_VECTOR_MODULE_PROP=str(t/'prop'))
        (t/'prop').write_text('id=zygisk_vector\nversionCode=3112\n')
        self.state.joinpath('config.conf').write_text((ROOT/'config.defaults').read_text())
        self.state.joinpath('boot').mkdir()
        self.state.joinpath('boot/last-success-id').write_text(self.boot.read_text())
    def call(self,path,*args,env=None,rc=0):
        p=subprocess.run(['sh',str(ROOT/path),*args],env=env or self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode,rc,f'{path}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
        return p.stdout
    def stage(self):
        self.assertIn('PASS_GUARDIAN_BOOT_PROBE_STAGED',self.call('guardian.sh','boot-probe-stage','--apply'))
    def new_boot(self, *, daemon='0',completed='0'):
        self.boot.write_text('11111111-2222-3333-4444-555555555555\n')
        env={**self.env,'TEST_BOOT_COMPLETED':completed,'TEST_VECTOR_RUNNING':daemon}
        self.call('post-fs-data.sh',env=env)
    def test_read_only_real_boot_probe(self):
        self.stage()
        out=self.call('guardian.sh','boot-probe-status')
        self.assertIn('state=AWAITING_NEXT_HARDWARE_BOOT',out)
        self.call('post-fs-data.sh',env={**self.env,'TEST_BOOT_COMPLETED':'0'})
        self.assertTrue((self.state/'boot-probe/request').exists())
        self.new_boot()
        self.assertFalse((self.state/'boot-probe/request').exists())
        out=self.call('guardian.sh','boot-probe-status')
        self.assertIn('assessment=EARLY_CANDIDATE',out)
        self.assertNotIn('PASS_GUARDIAN_BOOT_ORDER_OBSERVED',out)
        self.assertEqual(self.db.read_bytes(),self.before)
        # This needs the service to reach the real healthy boot path.
        self.call('service.sh',env={**self.env,'CHECK_SYSTEMUI':'0'})
        self.assertFalse(self.service_lock.exists(), 'Service lock must be removed after a successful fixture boot')
        stable_receipt=self.state/'boot-probe/stable.txt'
        self.assertTrue(stable_receipt.is_file(), 'Simulated service failed to write stable receipt')
        self.assertIn('vector=VECTOR_RESPONDING',stable_receipt.read_text())
        out=self.call('guardian.sh','boot-probe-status')
        self.assertIn('PASS_GUARDIAN_BOOT_ORDER_OBSERVED',out)
        self.assertIn('device_restore_qualification=UNQUALIFIED',out)
        self.assertEqual(self.db.read_bytes(),self.before)
    def test_fixture_service_lock_failure_never_accepts_boot(self):
        self.stage();self.new_boot()
        bad_lock=self.state/'nonexistent-lock-parent'/'service-lock'
        self.assertFalse(bad_lock.parent.exists())
        self.call('service.sh',env={**self.env,'GUARDIAN_LOCK_DIR':str(bad_lock),'CHECK_SYSTEMUI':'0'})
        self.assertFalse((self.state/'boot-probe/stable.txt').exists())
        out=self.call('guardian.sh','boot-probe-status')
        self.assertIn('assessment=EARLY_CANDIDATE',out)
        self.assertIn('BOOT_ORDER_NOT_YET_ACCEPTED',out)
        self.assertNotIn('PASS_GUARDIAN_BOOT_ORDER_OBSERVED',out)

    def test_detect_daemon_started_early(self):
        self.stage();self.new_boot(daemon='1')
        receipt=(self.state/'boot-probe/early.txt').read_text()
        self.assertIn('assessment=TOO_LATE_VECTOR_RUNNING',receipt)
        self.assertEqual(self.db.read_bytes(),self.before)
    def test_reject_late_hook(self):
        self.stage();self.new_boot(completed='1')
        receipt=(self.state/'boot-probe/early.txt').read_text()
        self.assertIn('assessment=TOO_LATE_BOOT_COMPLETED',receipt)
        self.assertEqual(self.db.read_bytes(),self.before)
    def test_refuse_to_stage_when_not_observing(self):
        cfg=self.state/'config.conf'
        cfg.write_text(cfg.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self.call('guardian.sh','boot-probe-stage','--apply',rc=1)
        self.assertFalse((self.state/'boot-probe/request').exists())
    def test_refuse_to_stage_if_device_flag_set(self):
        cfg=self.state/'config.conf'
        cfg.write_text(cfg.read_text().replace('RECOVERY_DEVICE_QUALIFIED=0','RECOVERY_DEVICE_QUALIFIED=1'))
        self.call('guardian.sh','boot-probe-stage','--apply',rc=1)
    def test_no_unqualified_result_when_daemon_started(self):
        self.stage();self.new_boot(daemon='1')
        self.call('service.sh')
        out=self.call('guardian.sh','boot-probe-status')
        self.assertIn('BOOT_ORDER_NOT_YET_ACCEPTED',out)
        self.assertNotIn('PASS_GUARDIAN_BOOT_ORDER_OBSERVED',out)

if __name__=='__main__':unittest.main()
