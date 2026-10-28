"""Host-only v0.9.5 tests: no su, no /data/adb access, no Vector mutation."""
from importlib.util import spec_from_file_location,module_from_spec
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import os
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
def load(name,filename):
    spec=spec_from_file_location(name,ROOT/'tools'/filename)
    module=module_from_spec(spec);spec.loader.exec_module(module)
    return module
RP=load('guardian_runtime_parity','runtime_parity.py')
AC=load('guardian_acceptance_export','acceptance_export.py')

class ParityContinuityTests(unittest.TestCase):
 def setUp(self):
    self.tmp=TemporaryDirectory(prefix='guardian-parity-')
    self.addCleanup(self.tmp.cleanup)
    self.base=Path(self.tmp.name)
    self.expected=RP.local_expected(ROOT)
 def stage(self,directory,changes=None):
    d=self.base/directory
    for name in RP.FILES:
        file=d/name;file.parent.mkdir(parents=True,exist_ok=True)
        file.write_bytes((ROOT/name).read_bytes())
    for name,content in (changes or {}).items():
        if content is None:(d/name).unlink()
        else:(d/name).write_bytes(content)
 def check(self,classification,passed):
    report=RP.compare(self.expected,RP.probe_fixture(self.base))
    self.assertEqual(report['classification'],classification)
    self.assertIs(report['pass'],passed)
    return report
 def test_fresh_module_not_installed(self):self.check('NOT_INSTALLED',False)
 def test_active_matches(self):
    self.stage('modules/lsposed_guardian');self.check('ACTIVE_MATCH',True)
 def test_expected_kernel_su_staged_update(self):
    self.stage('modules/lsposed_guardian',{'guardian.sh':b'old code'})
    self.stage('modules_update/lsposed_guardian')
    self.check('STAGED_PENDING_REBOOT',True)
 def test_after_reboot_active_matches_and_stage_absent(self):
    self.stage('modules/lsposed_guardian');self.check('ACTIVE_MATCH',True)
 def test_bad_staged_version_refuses(self):
    self.stage('modules/lsposed_guardian',{'guardian.sh':b'old'})
    self.stage('modules_update/lsposed_guardian',{'lib/one-shot.sh':b'bad'})
    self.check('UNEXPECTED_RUNTIME_DRIFT',False)
 def test_missing_critical_cli_detected(self):
    self.stage('modules/lsposed_guardian',{'lib/crash.sh':None})
    r=self.check('UNEXPECTED_RUNTIME_DRIFT',False)
    self.assertIn('lib/crash.sh',r['active_drift'])
 def test_active_and_staged_same_source(self):
    self.stage('modules/lsposed_guardian');self.stage('modules_update/lsposed_guardian')
    self.check('ACTIVE_MATCH_UPDATE_PENDING',True)
 def test_read_only_fixture_mode(self):
    self.stage('modules/lsposed_guardian')
    before={p:p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
    result=subprocess.run([sys.executable,'-S',str(ROOT/'tools/runtime_parity.py'),
      '--fixture-root',str(self.base),'--json'],capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr)
    self.assertEqual(json.loads(result.stdout)['classification'],'ACTIVE_MATCH')
    self.assertEqual(before,{p:p.read_bytes() for p in self.base.rglob('*') if p.is_file()})
 def test_manual_acceptance_is_not_auto_qualification(self):
    q='version=0.9.4\nactual_early_boot_restore_test=PASS_MANUAL_ONE_SHOT_RECEIPT\nactual_restore_boot_id=abc\nlive_quarantine_roundtrip=PASS_HISTORICAL_LEDGER_PAIR\n'
    r='transaction_phase=HEALTH_CONFIRMED\nPASS_GUARDIAN_REAL_ONE_SHOT_RESTORE\n'
    c='retained_events=9\nhistory_sha256=abcd\n'
    receipt=AC.safe_receipt(q,r,c,'fake-boot')
    self.assertEqual(receipt['manual_restore_receipt'],'PASS')
    self.assertFalse(receipt['overall_automatic_recovery_qualified'])
    self.assertFalse(receipt['offline_undo_verified'])
    self.assertEqual(AC.safe_receipt(q,r.replace('HEALTH_CONFIRMED','PENDING'),c,'x')['manual_restore_receipt'],'UNVERIFIED')
 def test_no_unsafe_recovery_actions_introduced(self):
    src=(ROOT/'tools/runtime_parity_root.sh').read_text()
    for needle in ('ksud module install','rm -f','$DB-wal','one-shot-stage','chcon ','restore --offline'):
      self.assertNotIn(needle,src)
    scripts=((ROOT/'tools/runtime_parity.py').read_text()+(ROOT/'tools/acceptance_export.py').read_text())
    self.assertNotIn('RECOVERY_DEVICE_QUALIFIED=1',scripts)
    self.assertNotIn('AUTO_RECOVERY=1',scripts)
 def test_merge_receipt_in_disposable_directory(self):
    # Isolated shell runs the actual crash_merge_file and continuity helper.
    d=self.base/'crashes';d.mkdir()
    old=d/'events.tsv';old.write_text('a\t1000000000\tapp.one\t1\n')
    new=d/'new.tsv';new.write_text('b\t1000000010\tapp.two\t2\n')
    shell='''STATE_DIR="$1"
. "$2/lib/crash.sh"
boot_id() { echo aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; }
db_sha() { sha256sum "$1" | awk '{print $1}'; }
log() { :; }
crash_merge_file "$3"
crash_audit
'''
    p=subprocess.run(['sh','-c',shell,'sh',str(self.base),str(ROOT),str(new)],capture_output=True,text=True)
    self.assertEqual(p.returncode,0,p.stderr)
    self.assertIn('continuity_current_digest=ATTESTED',p.stdout)
    self.assertEqual(len((d/'continuity.tsv').read_text().splitlines()),1)
    self.assertIn('MERGE',(d/'continuity.tsv').read_text())
 def test_boot_detects_untracked_history_replacement(self):
    d=self.base/'crashes';d.mkdir()
    f=d/'events.tsv';f.write_text('a\t123\tgood.app\t4\n')
    shell="""STATE_DIR="$1"
. "$2/lib/crash.sh"
boot_id() { echo aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; }
db_sha() { sha256sum "$1" | awk '{print $1}'; }
crash_continuity_boot
"""
    for _ in range(2):
      p=subprocess.run(['sh','-c',shell,'sh',str(self.base),str(ROOT)],capture_output=True,text=True)
      self.assertEqual(p.returncode,0,p.stderr)
    f.write_text('b\t150\tother.app\t2\n')
    p=subprocess.run(['sh','-c',shell,'sh',str(self.base),str(ROOT)],capture_output=True,text=True)
    self.assertEqual(p.returncode,0,p.stderr)
    lines=(d/'continuity.tsv').read_text().splitlines()
    self.assertEqual(len(lines),3)
    self.assertIn('UNTRACKED_AT_BOOT',lines[-1])

 def test_history_decline_is_not_backfilled_as_proven_cause(self):
    text=(ROOT/'lib/crash.sh').read_text()
    self.assertIn('UNKNOWN_WITHOUT_PRIOR_FILE_OR_TRIM_RECEIPT',text)
    self.assertIn('TRACKED_FROM_FIRST_V095_RECEIPT_ONLY',text)
    self.assertIn('TRIM_OR_DEDUP',text)
 def test_install_and_device_check_integrate_parity(self):
    install=(ROOT/'tools/install.sh').read_text()
    check=(ROOT/'tools/device_check.sh').read_text()
    self.assertIn('upgrade_receipt.sh" pre-install',install)
    self.assertIn('upgrade_receipt.sh" post-install',install)
    self.assertIn('tools/runtime_parity.py',install)
    self.assertIn('acceptance_export.py',check)
    self.assertIn('runtime_parity.py',check)

if __name__=='__main__':unittest.main()
