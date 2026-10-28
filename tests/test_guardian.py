"""Hermetic fake-Vector tests: no Android device, root, or real sqlite DB modified."""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guardian-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.state = self.base / "guardian-state"
        self.db = self.base / "lspd" / "config" / "modules_config.db"
        self.db.parent.mkdir(parents=True)
        self._make_db(version=1)
        self.boot = self.base / "bootid"
        self.boot.write_text("boot-one\n")
        self.fakebin = self.base / "bin"
        self.fakebin.mkdir()
        # Host-only shim; production uses an installed sqlite3 CLI when available.
        sqlite_cli=self.fakebin/'sqlite3'
        sqlite_cli.write_text(f"#!{sys.executable} -S\n" + """import sqlite3,sys
args=sys.argv[1:]
if args[0]=='-readonly':args=args[1:]
con=sqlite3.connect(f'file:{args[0]}?mode=ro',uri=True)
try:
    for row in con.execute(args[1]):
        print('|'.join(str(v) for v in row))
finally: con.close()
""")
        sqlite_cli.chmod(0o755)
        self.vector = self.fakebin / "vectorcli"
        self.vector.write_text(f"#!{sys.executable} -S\n" + '''import json, os, sqlite3, sys
args=sys.argv[1:]
if args[0]=='--json': args=args[1:]
modules_path=os.environ['FAKE_MODULES_FILE']
with open(modules_path) as fp: mods=json.load(fp)
db=os.environ['GUARDIAN_VECTOR_DB']
if args[:2]==['db','backup']:
  src=sqlite3.connect(db); dst=sqlite3.connect(args[2]); src.backup(dst); dst.close(); src.close()
  print('Database backed up'); sys.exit(0)
if args[:2]==['modules','ls']:
  enabled='-e' in args
  data=[{'PACKAGE':k,'STATUS': 'enabled' if v else 'disabled'} for k,v in mods.items() if not enabled or v]
  print(json.dumps({'success':True,'data':data},indent=2)); sys.exit(0)
if args[:2] in (['modules','disable'],['modules','enable']):
  mode=os.environ.get('FAKE_TOGGLE_MODE','')
  if mode=='reject':print(json.dumps({'success':False,'error':'injected rejection'}));sys.exit(1)
  if mode=='pretend':print(json.dumps({'success':True,'data':{'Accepted':[args[2]]}}));sys.exit(0)
  if args[2] not in mods: print(json.dumps({'success':True,'data':{'Failed':[args[2]]}})); sys.exit(0)
  mods[args[2]]= args[1]=='enable'
  if mode=='mutate-other':mods['mod.beta']=True
  with open(modules_path,'w') as fp: json.dump(mods,fp)
  if mode=='mutate-then-error':print('injected lost response');sys.exit(42)
  print(json.dumps({'success':True})); sys.exit(0)
if args[:2]==['scope','ls']:
  if os.environ.get('FAKE_SCOPE_FAIL')==args[2]: print('unavailable'); sys.exit(4)
  scope=json.loads(os.environ.get('FAKE_SCOPES_JSON','{"mod.alpha":[{"APP_PACKAGE":"com.android.systemui","USER_ID":0}]}'))
  print(json.dumps({'success':True,'data':scope.get(args[2],[])},indent=2)); sys.exit(0)
if args==['status']:
  print('Framework: ready'); sys.exit(0)
print('unknown command',args,file=sys.stderr); sys.exit(1)
''')
        self.vector.chmod(0o755)
        self.vector_prop=self.base/'vector-module.prop'
        self.vector_prop.write_text('id=zygisk_vector\nversionCode=100\n')
        (self.fakebin / "getprop").write_text('#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo 1\n')
        (self.fakebin / "pidof").write_text('''#!/bin/sh
if [ "$1" = vectord ] && [ "${FAKE_VECTOR_RUNNING:-0}" = 1 ]; then echo 999; exit 0; fi
if [ "$1" = com.android.systemui ]; then echo 333; exit 0; fi
exit 1
''')
        (self.fakebin / "sleep").write_text('#!/bin/sh\nexit 0\n')
        for n in ("getprop", "pidof", "sleep"):
            (self.fakebin / n).chmod(0o755)
        self.mods = self.base / "modules.json"
        self.mods.write_text(json.dumps({'mod.alpha': True,'mod.beta':False}))
        self.env = os.environ.copy()
        self.env.update({
            'GUARDIAN_STATE_DIR':str(self.state),
            'GUARDIAN_BOOT_ID_PATH':str(self.boot),
            'GUARDIAN_VECTOR_DB':str(self.db),
            'GUARDIAN_VECTOR_CLI':str(self.vector),
            'GUARDIAN_VECTOR_MODULE_PROP':str(self.vector_prop),
            'GUARDIAN_LOCK_DIR':str(self.base / 'service-lock'),
            'GUARDIAN_CRASH_TMPDIR':str(self.base),
            'FAKE_MODULES_FILE':str(self.mods),
            'PATH': str(self.fakebin) + os.pathsep + os.environ['PATH'],
        })

        # Unit tests deliberately avoid persistent background collectors.
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state/'config.conf').write_text((ROOT/'config.defaults').read_text().replace('PASSIVE_CRASH_MONITOR=1', 'PASSIVE_CRASH_MONITOR=0').replace('RECOVERY_DEVICE_QUALIFIED=0','RECOVERY_DEVICE_QUALIFIED=1').replace('HISTORY_MONITOR=1','HISTORY_MONITOR=0'))
        self.log_fixture = self.base/'logcat.txt'
        self.log_fixture.write_text('')
        (self.fakebin/'logcat').write_text('#!/bin/sh\n[ "${FAKE_LOGCAT_FAIL:-0}" = 1 ] && exit 42\ncat "$FAKE_LOGCAT_FILE"\n')
        (self.fakebin/'logcat').chmod(0o755)
        self.env['FAKE_LOGCAT_FILE'] = str(self.log_fixture)

    def _make_db(self, version):
        with sqlite3.connect(self.db) as conn:
            conn.execute('CREATE TABLE IF NOT EXISTS modules (module_pkg_name TEXT PRIMARY KEY, enabled INTEGER, apk_path TEXT DEFAULT "")')
            conn.execute('CREATE TABLE IF NOT EXISTS scope (mid INTEGER, app_pkg_name TEXT, user_id INTEGER)')
            conn.execute('CREATE TABLE IF NOT EXISTS configs (module_pkg_name TEXT, user_id INTEGER, data BLOB)')
            conn.execute('INSERT OR REPLACE INTO modules (module_pkg_name,enabled) VALUES (?,?)', ('mod.alpha',version))

    def run_shell(self, script, *args, env=None, expect=0):
        p=subprocess.run(['/bin/sh',str(ROOT / script),*args],env=env or self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=45)
        self.assertEqual(p.returncode,expect,f'Command {script} {args}: {p.stdout} {p.stderr}')
        return p.stdout

    def next_boot(self,name):
        self.boot.write_text(name+'\n')
        self.run_shell('post-fs-data.sh')

    def good_boot(self):
        self.run_shell('post-fs-data.sh')
        self.run_shell('service.sh')
        self.assertTrue((self.state/'snapshots/last-good.db').is_file())

    def get_version(self):
        with sqlite3.connect(self.db) as conn:
            return conn.execute("SELECT enabled FROM modules WHERE module_pkg_name='mod.alpha'").fetchone()[0]


    def test_triage_counts_stored_events_without_sampling(self):
        self.good_boot()
        path = self.state / 'crashes/events.tsv'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('deadbeef-aaaa\t1792451234\tcom.android.systemui\t111\n'
                        'deadbeef-bbbb\t1792451235\tcom.android.systemui\t112\n'
                        'deadbeef-bbbb\t1792451236\torg.other.app:worker\t222\n')
        out = self.run_shell('guardian.sh','triage')
        self.assertIn('count=2 process=com.android.systemui', out)
        self.assertIn('count=1 process=org.other.app:worker', out)
        self.assertEqual(len(path.read_text().splitlines()), 3)

    def test_logcat_failure_keeps_history_and_explains_reason(self):
        self.good_boot()
        self.log_fixture.write_text('1792451234.003 E AndroidRuntime: Process: org.good.app, PID: 99\n')
        self.run_shell('guardian.sh','collect')
        saved = (self.state/'crashes/events.tsv').read_bytes()
        env = self.env.copy();env['FAKE_LOGCAT_FAIL']='1'
        p=subprocess.run(['/bin/sh',str(ROOT/'guardian.sh'),'collect'],env=env,capture_output=True,text=True,timeout=45)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('logcat-failed',p.stderr)
        self.assertEqual((self.state/'crashes/events.tsv').read_bytes(),saved)

    def test_collector_health_distinguishes_old_poll_and_failure(self):
        self.good_boot()
        d = self.state/'monitor'
        d.mkdir(parents=True, exist_ok=True)
        (d/'last-boot').write_text('boot-one\n')
        (d/'last-epoch').write_text('1\n')
        (d/'last-result').write_text('error\n')
        (d/'last-reason').write_text('logcat-failed\n')
        (d/'last-failure-reason').write_text('logcat-failed\n')
        out=self.run_shell('guardian.sh','collector-health')
        self.assertIn('collector_recent_poll=no',out)
        self.assertIn('collector_last_failure_reason=logcat-failed',out)
        obj=json.loads(self.run_shell('guardian.sh','report'))
        self.assertEqual(obj['collector_last_poll_result'],'error')
        self.assertEqual(obj['collector_last_failure_reason'],'logcat-failed')
        self.assertFalse(obj['collector_recent_poll'])

    def test_normal_boot_saves_consistent_snapshot_and_clears_pending(self):
        self.good_boot()
        self.assertFalse((self.state/'boot/pending-id').exists())
        self.assertEqual((self.state/'boot/failures').read_text().strip(),'0')
        self.assertIn('mod.alpha',(self.state/'snapshots/last-good.enabled').read_text())
        self.assertIn('mode=OBSERVE',self.run_shell('guardian.sh','status'))

    def test_no_restore_when_unarmed_even_after_several_bad_boots(self):
        self.good_boot()
        self._make_db(version=0)
        for i in range(2,6): self.next_boot('boot-'+str(i))
        self.assertEqual(self.get_version(),0)

    def test_legacy_automatic_restore_retired_even_after_failed_boots(self):
        self.good_boot()
        self.run_shell('guardian.sh','arm',expect=1)
        self._make_db(version=0)
        for boot in ('boot-two','boot-three','boot-four'):
            self.next_boot(boot)
        self.assertEqual(self.get_version(),0)
        self.assertFalse((self.state/'boot/recovery-performed').exists())

    def test_same_kernel_boot_is_not_counted_twice(self):
        self.run_shell('post-fs-data.sh')
        self.run_shell('post-fs-data.sh')
        self.assertEqual((self.state/'boot/failures').read_text().strip(),'0')
        self.next_boot('boot-two')
        self.assertEqual((self.state/'boot/failures').read_text().strip(),'1')

    def test_legacy_manual_restore_refused_and_never_edits_db(self):
        self.good_boot()
        self._make_db(version=0)
        self.run_shell('guardian.sh','restore','--apply',expect=1)
        self.next_boot('boot-two')
        self.assertEqual(self.get_version(),0)
        self.assertFalse((self.state/'boot/manual-restore').exists())

    def test_legacy_auto_config_never_mutates_live_db(self):
        self.good_boot()
        config=self.state/'config.conf'
        config.write_text(config.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self._make_db(version=0)
        for boot in ('boot-two','boot-three','boot-four'):
            self.next_boot(boot)
        self.assertEqual(self.get_version(),0)

    def test_vector_disabling_is_verified_by_readback(self):
        self.good_boot()
        self.run_shell('guardian.sh','disable','mod.alpha')
        self.assertFalse(json.loads(self.mods.read_text())['mod.alpha'])
        self.run_shell('guardian.sh','enable','mod.alpha')
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_json_report_valid_and_explicitly_unqualified(self):
        self.good_boot()
        obj=json.loads(self.run_shell('guardian.sh','report'))
        self.assertEqual(obj['qualification'],'UNQUALIFIED')
        self.assertTrue(obj['snapshot_valid'])
        self.assertFalse(obj['recovery_armed'])
        self.assertEqual(obj['consecutive_failed_boots'],0)

    def test_scope_suspects_read_only(self):
        self.good_boot()
        output=self.run_shell('guardian.sh','suspects','com.android.systemui')
        self.assertIn('mod.alpha',output)
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_refuses_invalid_module_names_and_missing_snapshot_arm(self):
        self.run_shell('guardian.sh','arm',expect=1)
        self.run_shell('guardian.sh','disable','lspd',expect=2)
        self.run_shell('guardian.sh','disable','bad;id',expect=2)

    def test_vector_version_change_blocks_restore(self):
        self.good_boot()
        self.run_shell('guardian.sh','arm',expect=1)
        self._make_db(version=0)
        self.vector_prop.write_text('id=zygisk_vector\nversionCode=101\n')
        self.next_boot('boot-two');self.next_boot('boot-three');self.next_boot('boot-four')
        self.assertEqual(self.get_version(),0)

    def test_crash_history_deduplicates_across_scans(self):
        self.good_boot()
        self.log_fixture.write_text('1792451234.000 200 300 E AndroidRuntime: Process: com.android.systemui, PID: 111\n'
                                    '1792451235.000 200 300 E AndroidRuntime: Process: org.example.app:worker, PID: 112\n')
        self.assertIn('Stored crash events: 2',self.run_shell('guardian.sh','collect'))
        self.assertIn('Stored crash events: 2',self.run_shell('guardian.sh','collect'))
        self.assertEqual(len((self.state/'crashes/events.tsv').read_text().splitlines()),2)
        self.assertIn('org.example.app:worker',self.run_shell('guardian.sh','events'))

    def test_crash_history_rejects_malformed_lines_and_truncates(self):
        self.good_boot()
        self.log_fixture.write_text('''not a crash line\n
1792451234.100 AndroidRuntime: Process: evil;rm, PID: 99\n
1792451234.100 AndroidRuntime: Process: org.test.valid, PID: 12\n
1792451234.200 AndroidRuntime: Process: org.test.valid, PID: xxx\n''')
        self.assertIn('Stored crash events: 1',self.run_shell('guardian.sh','collect'))

    def test_crash_correlation_is_read_only(self):
        self.good_boot()
        now=__import__('time').time()
        entries=''.join(f'{int(now)+i}.010 E AndroidRuntime: Process: com.android.systemui, PID: {900+i}\n' for i in range(3))
        self.log_fixture.write_text(entries)
        output=self.run_shell('guardian.sh','correlate','com.android.systemui')
        self.assertIn('Recent crashes for com.android.systemui: 3',output)
        self.assertIn('mod.alpha',output)
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_event_retention_is_bounded_and_across_boots(self):
        self.good_boot()
        start=1792451000
        self.log_fixture.write_text(''.join(
            f'{start+i}.001 E AndroidRuntime: Process: org.example.app, PID: {1000+i}\n' for i in range(450)))
        self.run_shell('guardian.sh','collect')
        self.assertEqual(400,len((self.state/'crashes/events.tsv').read_text().splitlines()))
        # New boot appends newer events while preserving the newest entries.
        self.boot.write_text('deadbeef-0000\n')
        self.log_fixture.write_text('1792452000.011 E AndroidRuntime: Process: org.example.app, PID: 5000\n')
        self.run_shell('guardian.sh','collect')
        events=(self.state/'crashes/events.tsv').read_text().splitlines()
        self.assertEqual(len(events),400)
        self.assertIn('deadbeef-0000\t1792452000\torg.example.app\t5000',events[-1])
        self.assertNotIn('\t1792451000\t', '\n'.join(events))

    def test_no_crash_buffer_records_not_equal_no_crashes(self):
        self.good_boot()
        self.assertIn('No captured crash records', self.run_shell('guardian.sh','events'))
        self.assertEqual(0, json.loads(self.run_shell('guardian.sh','report'))['stored_crash_events'])

    def test_invalid_snapshot_fails_closed(self):
        self.good_boot();self.run_shell('guardian.sh','arm',expect=1)
        (self.state/'snapshots/last-good.db').write_bytes(b'not sql')
        self._make_db(version=0)
        self.next_boot('boot-two');self.next_boot('boot-three');self.next_boot('boot-four')
        self.assertEqual(self.get_version(),0)


    def test_isolated_selftest_does_not_change_real_event_history(self):
        self.good_boot()
        self.log_fixture.write_text('1792451234.001 E AndroidRuntime: Process: org.real.app, PID: 77\n')
        self.run_shell('guardian.sh', 'collect')
        original = (self.state/'crashes/events.tsv').read_bytes()
        self.assertIn('PASS_GUARDIAN_ISOLATED_CRASH_PIPELINE', self.run_shell('guardian.sh', 'selftest'))
        self.assertEqual((self.state/'crashes/events.tsv').read_bytes(), original)
        self.assertEqual(list((self.state/'selftests').iterdir()), [])

    def test_monitor_recent_poll_requires_success_current_boot_and_freshness(self):
        self.good_boot()
        folder = self.state/'monitor'; folder.mkdir()
        now = int(__import__('time').time())
        (folder/'last-boot').write_text('boot-one\n')
        (folder/'last-result').write_text('ok\n')
        (folder/'last-epoch').write_text(f'{now}\n')
        self.assertTrue(json.loads(self.run_shell('guardian.sh', 'report'))['collector_recent_poll'])
        self.assertIn('collector_recent_poll=yes', self.run_shell('guardian.sh', 'doctor'))
        (folder/'last-result').write_text('error\n')
        self.assertFalse(json.loads(self.run_shell('guardian.sh', 'report'))['collector_recent_poll'])
        (folder/'last-result').write_text('ok\n')
        (folder/'last-epoch').write_text(f'{now - 1000}\n')
        self.assertFalse(json.loads(self.run_shell('guardian.sh', 'report'))['collector_recent_poll'])
        (folder/'last-epoch').write_text(f'{now}\n')
        self.boot.write_text('boot-two\n')
        self.assertFalse(json.loads(self.run_shell('guardian.sh', 'report'))['collector_recent_poll'])

    def test_report_does_not_infer_monitor_health_from_enabled_config(self):
        self.good_boot()
        report=json.loads(self.run_shell('guardian.sh', 'report'))
        self.assertFalse(report['collector_recent_poll'])
        self.assertEqual(report['collector_last_poll_epoch'],0)


    def test_baseline_pinned_across_multiple_stable_boots(self):
        self.good_boot()
        original = (self.state/'snapshots/last-good.db').read_bytes()
        original_manifest = (self.state/'snapshots/last-good.enabled').read_text()
        mods = json.loads(self.mods.read_text())
        mods['mod.beta']=True
        self.mods.write_text(json.dumps(mods))
        self._make_db(version=0)
        self.next_boot('boot-two')
        self.run_shell('service.sh')
        self.assertEqual((self.state/'snapshots/last-good.db').read_bytes(), original)
        self.assertEqual((self.state/'snapshots/last-good.enabled').read_text(), original_manifest)
        self.assertIn('mod.beta', (self.state/'snapshots/observed.enabled').read_text())
        self.assertIn('mode=OBSERVE',self.run_shell('guardian.sh','doctor'))
        self.assertIn('  baseline_policy=pinned',self.run_shell('guardian.sh','status').replace('baseline_policy=','  baseline_policy='))

    def test_changes_reports_new_and_removed_modules_without_mutating(self):
        self.good_boot()
        mods = json.loads(self.mods.read_text()); mods['mod.alpha']=False;mods['mod.beta']=True
        self.mods.write_text(json.dumps(mods))
        result=self.run_shell('guardian.sh','changes')
        self.assertIn('+ mod.beta', result)
        self.assertIn('- mod.alpha', result)
        self.assertFalse(json.loads(self.mods.read_text())['mod.alpha'])

    def test_explicit_promote_rotates_baseline_only_after_successful_boot(self):
        self.good_boot()
        baseline=(self.state/'snapshots/last-good.db').read_bytes()
        self._make_db(version=0)
        self.run_shell('guardian.sh','promote',expect=2)
        self.run_shell('guardian.sh','promote','--apply')
        self.assertNotEqual((self.state/'snapshots/last-good.db').read_bytes(), baseline)
        self.assertEqual((self.state/'snapshots/previous-good.db').read_bytes(), baseline)
        self.assertFalse((self.state/'snapshots/baseline-in-progress').exists())
        self.assertIn('baseline_policy=pinned',self.run_shell('guardian.sh','status'))

    def test_assess_review_is_read_only_and_reports_historical_crashes(self):
        self.good_boot()
        event=self.state/'crashes/events.tsv'
        event.parent.mkdir(exist_ok=True)
        event.write_text('b-1\t1792451234\tcom.android.systemui\t777\n'
                         'b-2\t1792451235\tcom.android.systemui:worker\t778\n')
        original=(self.state/'snapshots/last-good.db').read_bytes()
        result=self.run_shell('guardian.sh','assess','com.android.systemui')
        self.assertIn('Retained crashes=2 across_boots=2',result)
        self.assertIn('mod.alpha',result)
        self.assertIn('No causal attribution',result)
        self.assertEqual((self.state/'snapshots/last-good.db').read_bytes(),original)

    def test_incomplete_baseline_update_blocks_restore_and_arming(self):
        self.good_boot()
        (self.state/'snapshots/baseline-in-progress').write_text('incomplete')
        self.run_shell('guardian.sh','arm',expect=1)
        self.assertFalse(json.loads(self.run_shell('guardian.sh','report'))['recovery_armed'])

    def test_empty_last_collector_failure_serializes_as_null(self):
        self.good_boot()
        report=json.loads(self.run_shell('guardian.sh','report'))
        self.assertIsNone(report['collector_last_failure_reason'])

    def test_runtime_version_matches_installed_module_metadata(self):
        self.good_boot()
        prop = dict(line.split('=',1) for line in (ROOT/'module.prop').read_text().splitlines() if '=' in line)
        version = prop['version']
        self.assertEqual(json.loads(self.run_shell('guardian.sh','report'))['version'], version)
        self.assertIn(f'LSPosed Guardian {version}', self.run_shell('guardian.sh','status'))
        self.assertIn(f'LSPosed Guardian {version}', self.run_shell('guardian.sh','doctor'))

    def test_legacy_origin_is_explicitly_unknown_and_snapshot_preserved(self):
        self.good_boot()
        snap = self.state/'snapshots'
        baseline = (snap/'last-good.db').read_bytes()
        (snap/'last-good.complete').unlink()
        (snap/'last-good.boot-id').unlink()
        status = self.run_shell('guardian.sh','doctor')
        self.assertIn('baseline_boot=unknown_legacy', status)
        self.assertIn('baseline_provenance=unknown_legacy', status)
        report = json.loads(self.run_shell('guardian.sh','report'))
        self.assertIsNone(report['baseline_boot_id'])
        self.assertEqual(report['baseline_provenance'],'unknown_legacy')
        self.assertEqual(report['snapshot_validation'],'sqlite_integrity_verified')
        self.assertFalse(json.loads(self.run_shell('guardian.sh','report'))['snapshot_valid'])
        changes = self.run_shell('guardian.sh','changes')
        self.assertIn('baseline_boot=unknown_legacy', changes)
        self.assertEqual((snap/'last-good.db').read_bytes(), baseline)

    def test_new_baseline_records_real_origin_without_faking_provenance(self):
        realistic_boot = '92d2c606-b7bf-42ae-88d3-28eac8ca5e9d'
        self.boot.write_text(realistic_boot + '\n')
        self.good_boot()
        report=json.loads(self.run_shell('guardian.sh','report'))
        self.assertEqual(report['baseline_boot_id'], realistic_boot)
        self.assertEqual(report['baseline_provenance'], 'recorded')
        self.assertIn(f'baseline_boot={realistic_boot}', self.run_shell('guardian.sh','doctor'))

    def test_upgrade_existing_v04_snapshot_remains_pinned(self):
        self.good_boot()
        base=(self.state/'snapshots/last-good.db').read_bytes()
        (self.state/'snapshots/last-good.complete').unlink()
        (self.state/'snapshots/last-good.boot-id').unlink()
        (self.state/'snapshots/observed.complete').unlink()
        self.next_boot('boot-two')
        self.run_shell('service.sh')
        self.assertEqual((self.state/'snapshots/last-good.db').read_bytes(),base)
        self.assertIn('mode=OBSERVE',self.run_shell('guardian.sh','doctor'))


    def test_snapshot_integrity_digest_and_sqlite_structure(self):
        self.good_boot()
        snap=self.state/'snapshots'
        out=self.run_shell('guardian.sh','integrity')
        self.assertIn('baseline=sqlite_integrity_verified',out)
        self.assertIn('observed=sqlite_integrity_verified',out)
        self.assertTrue((snap/'last-good.sha256').is_file())
        self.assertTrue(json.loads(self.run_shell('guardian.sh','report'))['snapshot_valid'])
        with open(snap/'last-good.db','ab') as fh: fh.write(b'corrupted')
        self.assertIn('baseline=digest_mismatch',self.run_shell('guardian.sh','integrity'))
        self.run_shell('guardian.sh','arm',expect=1)
        self.assertFalse(json.loads(self.run_shell('guardian.sh','report'))['snapshot_valid'])

    def test_legacy_snapshot_never_automatically_promoted_or_armed(self):
        self.good_boot()
        snap=self.state/'snapshots'
        (snap/'last-good.sha256').unlink()
        original=(snap/'last-good.db').read_bytes()
        self.next_boot('boot-two');self.run_shell('service.sh')
        self.assertEqual(original,(snap/'last-good.db').read_bytes())
        self.assertIn('legacy_header_only',self.run_shell('guardian.sh','integrity'))
        self.run_shell('guardian.sh','arm',expect=1)

    def test_device_qualification_gate_prevents_arming(self):
        self.good_boot()
        cfg=self.state/'config.conf'
        cfg.write_text(cfg.read_text().replace('RECOVERY_DEVICE_QUALIFIED=1','RECOVERY_DEVICE_QUALIFIED=0'))
        self.run_shell('guardian.sh','arm',expect=1)
        self.assertFalse(json.loads(self.run_shell('guardian.sh','report'))['recovery_armed'])

    def test_quarantine_is_opt_in_targeted_and_reversible(self):
        self.good_boot()
        before=json.loads(self.mods.read_text())
        preview=self.run_shell('guardian.sh','quarantine','mod.alpha')
        self.assertIn('Preview:',preview)
        self.assertEqual(json.loads(self.mods.read_text()),before)
        self.assertIn('QUARANTINED',self.run_shell('guardian.sh','quarantine','mod.alpha','--apply'))
        self.assertFalse(json.loads(self.mods.read_text())['mod.alpha'])
        self.assertEqual(json.loads(self.mods.read_text())['mod.beta'],before['mod.beta'])
        self.assertIn('active: mod.alpha',self.run_shell('guardian.sh','quarantine-status'))
        self.assertIn('ROLLED_BACK',self.run_shell('guardian.sh','rollback','mod.alpha','--apply'))
        self.assertEqual(json.loads(self.mods.read_text()),before)
        self.assertIn('ledger_events=2',self.run_shell('guardian.sh','quarantine-status'))
        self.assertIn('mode=OBSERVE',self.run_shell('guardian.sh','doctor'))

    def test_quarantine_never_operates_on_disabled_or_unknown(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.beta','--apply',expect=1)
        self.run_shell('guardian.sh','quarantine','mod.absent','--apply',expect=1)
        self.run_shell('guardian.sh','quarantine','lspd','--apply',expect=2)
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',expect=1)
        self.assertEqual(json.loads(self.mods.read_text()),{'mod.alpha':True,'mod.beta':False})

    def test_quarantine_interrupted_state_reconciliation(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        q=self.state/'quarantine';active=q/'active';pending=q/'pending'
        (pending/'mod.alpha.record').write_bytes((active/'mod.alpha.record').read_bytes())
        (pending/'mod.alpha.before').write_bytes((active/'mod.alpha.before').read_bytes())
        (active/'mod.alpha.record').unlink();(active/'mod.alpha.before').unlink()
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',expect=1)
        self.assertIn('RECONCILED',self.run_shell('guardian.sh','quarantine-reconcile','mod.alpha','--apply'))
        self.assertIn('ROLLED_BACK',self.run_shell('guardian.sh','rollback','mod.alpha','--apply'))
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_quarantine_rollback_preserves_unrelated_module_mutations(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        modules=json.loads(self.mods.read_text());modules['mod.beta']=True
        self.mods.write_text(json.dumps(modules))
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply')
        self.assertEqual(json.loads(self.mods.read_text()),{'mod.alpha':True,'mod.beta':True})


    def test_legacy_baseline_can_be_explicitly_promoted_without_pretending_prior_integrity(self):
        self.good_boot()
        snap=self.state/'snapshots'
        old=(snap/'last-good.db').read_bytes()
        (snap/'last-good.sha256').unlink()
        (snap/'last-good.validation').unlink()
        (snap/'last-good.bytes').unlink()
        (snap/'last-good.complete').unlink()
        (snap/'last-good.boot-id').unlink()
        self._make_db(version=0)
        self.run_shell('guardian.sh','promote','--apply')
        self.assertEqual((snap/'previous-good.db').read_bytes(),old)
        self.assertEqual(json.loads(self.run_shell('guardian.sh','report'))['snapshot_validation'],'sqlite_integrity_verified')
        self.assertEqual(self.get_version(),0)

    def test_missing_sqlite_verifier_does_not_create_restore_qualified_baseline(self):
        env=self.env.copy()
        env['GUARDIAN_SQLITE_CLI']=str(self.base/'not-installed')
        self.run_shell('post-fs-data.sh',env=env)
        self.run_shell('service.sh',env=env)
        self.assertFalse((self.state/'snapshots/last-good.db').exists())
        self.assertFalse(json.loads(self.run_shell('guardian.sh','report',env=env))['snapshot_valid'])
        self.run_shell('guardian.sh','arm',env=env,expect=1)

    # v0.7 consolidated historical decision & interruption-injection gates.
    def add_recent_crashes(self, count=3, target='com.android.systemui', boot=None):
        (self.state/'crashes').mkdir(exist_ok=True)
        bid=(boot if boot is not None else 'b-e')
        epoch=int(time.time())
        events=self.state/'crashes/events.tsv'
        events.write_text(''.join(f'{bid}\t{epoch}\t{target}\t{9000+i}\n' for i in range(count)))

    def test_history_monitor_runs_once_then_stops_on_boot_change(self):
        # Fake sleep advances to a distinct boot; no busy-loop or live Android process.
        (self.fakebin/'sleep').write_text('#!/bin/sh\necho changed-boot > "$GUARDIAN_BOOT_ID_PATH"\n')
        cfg=self.state/'config.conf'
        cfg.write_text(cfg.read_text().replace('HISTORY_MONITOR=0','HISTORY_MONITOR=1'))
        self.run_shell('history-monitor.sh')
        self.assertIn('history_recent_poll=no',self.run_shell('guardian.sh','history-health'))
        self.assertEqual(len((self.state/'history/samples.tsv').read_text().splitlines()),1)
        self.assertEqual((self.state/'history/last-result').read_text().strip(),'ok')

    def test_history_checkpoint_records_enabled_and_explicit_scope(self):
        self.run_shell('guardian.sh','history-capture')
        idx=(self.state/'history/samples.tsv').read_text().strip().split('\t')
        self.assertEqual(len(idx),6)
        checkpoint=(self.state/'history/checkpoints'/idx[2]).read_text()
        self.assertIn('M\tmod.alpha\n',checkpoint)
        self.assertIn('S\tmod.alpha\tcom.android.systemui\t0\n',checkpoint)
        self.assertNotIn('mod.beta',checkpoint)
        self.assertIn('enabled=1',self.run_shell('guardian.sh','history'))
        self.assertEqual(json.loads(self.run_shell('guardian.sh','report'))['historical_checkpoints'],1)

    def test_history_scope_collection_failure_does_not_commit_partial_sample(self):
        self.run_shell('guardian.sh','history-capture')
        before=(self.state/'history/samples.tsv').read_bytes()
        env=self.env.copy();env['FAKE_SCOPE_FAIL']='mod.alpha'
        self.run_shell('guardian.sh','history-capture',env=env,expect=1)
        self.assertEqual(before,(self.state/'history/samples.tsv').read_bytes())

    def test_history_second_boot_does_not_impute_first_boot_scope(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes(boot='b-different')
        out=self.run_shell('guardian.sh','decision','com.android.systemui')
        self.assertIn('decision=HISTORICAL_COVERAGE_MISSING',out)

    def test_user_excluded_app_never_nominated(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes(target='com.openai.chatgpt')
        out=self.run_shell('guardian.sh','decision','com.openai.chatgpt')
        self.assertIn('decision=EXCLUDED_BY_USER',out)
        self.assertNotIn('candidate_for_manual_review',out)

    def test_decision_refuses_fewer_than_three_crashes(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes(2)
        self.assertIn('decision=INSUFFICIENT_CRASH_EVIDENCE',self.run_shell('guardian.sh','decision','com.android.systemui'))

    def test_decision_single_candidate_is_review_only(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes()
        out=self.run_shell('guardian.sh','decision','com.android.systemui')
        self.assertIn('decision=REVIEW_SINGLE_SCOPED_MODULE',out)
        self.assertIn('candidate_for_manual_review=mod.alpha',out)
        self.assertIn('causality=NOT_ESTABLISHED',out)
        self.assertIn('automatic_action=disabled',out)
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_decision_multiple_scoped_candidates_not_attributed(self):
        modules=json.loads(self.mods.read_text());modules['mod.beta']=True;self.mods.write_text(json.dumps(modules))
        env=self.env.copy()
        env['FAKE_SCOPES_JSON']=json.dumps({'mod.alpha':[{'APP_PACKAGE':'com.android.systemui','USER_ID':0}], 'mod.beta':[{'APP_PACKAGE':'com.android.systemui','USER_ID':0}]})
        self.run_shell('guardian.sh','history-capture',env=env)
        self.add_recent_crashes()
        out=self.run_shell('guardian.sh','decision','com.android.systemui')
        self.assertIn('decision=MULTIPLE_SCOPED_CANDIDATES',out)
        self.assertNotIn('candidate_for_manual_review',out)

    def test_decision_rejects_modified_checkpoint(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes()
        idx=(self.state/'history/samples.tsv').read_text().strip().split('\t')
        with (self.state/'history/checkpoints'/idx[2]).open('a') as fp:fp.write('M\tmod.evil\n')
        self.assertIn('decision=HISTORICAL_CHECKPOINT_INVALID',self.run_shell('guardian.sh','decision','com.android.systemui'))

    def test_decision_requires_checkpoint_before_crash_not_after(self):
        self.run_shell('guardian.sh','history-capture')
        epoch=int(time.time())
        idxfile=self.state/'history/samples.tsv'
        cells=idxfile.read_text().strip().split('\t')
        cells[1]=str(epoch+10)
        idxfile.write_text('\t'.join(cells)+'\n')
        self.add_recent_crashes()
        self.assertIn('decision=HISTORICAL_COVERAGE_MISSING',self.run_shell('guardian.sh','decision','com.android.systemui'))

    def test_decision_refuses_changed_module_state(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes()
        modules=json.loads(self.mods.read_text());modules['mod.alpha']=False;self.mods.write_text(json.dumps(modules))
        self.assertIn('decision=CONFIGURATION_CHANGED_SINCE_CRASH',self.run_shell('guardian.sh','decision','com.android.systemui'))

    def test_failed_quarantine_toggle_persists_pending_and_reconciles(self):
        self.good_boot()
        env=self.env.copy();env['FAKE_TOGGLE_MODE']='pretend'
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply',env=env,expect=1)
        self.assertTrue((self.state/'quarantine/pending/mod.alpha.record').exists())
        self.assertIn('CANCELLED',self.run_shell('guardian.sh','quarantine-reconcile','mod.alpha','--apply'))
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])

    def test_mutation_after_lost_vector_response_is_reconcilable(self):
        self.good_boot()
        env=self.env.copy();env['FAKE_TOGGLE_MODE']='mutate-then-error'
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply',env=env,expect=1)
        self.assertFalse(json.loads(self.mods.read_text())['mod.alpha'])
        self.assertIn('RECONCILED',self.run_shell('guardian.sh','quarantine-reconcile','mod.alpha','--apply'))
        self.assertIn('ROLLED_BACK',self.run_shell('guardian.sh','rollback','mod.alpha','--apply'))

    def test_decision_rejects_changed_current_scope(self):
        self.run_shell('guardian.sh','history-capture')
        self.add_recent_crashes()
        env=self.env.copy();env['FAKE_SCOPES_JSON']='{}'
        out=self.run_shell('guardian.sh','decision','com.android.systemui',env=env)
        self.assertIn('decision=CONFIGURATION_CHANGED_SINCE_CRASH',out)

    def test_rollback_failed_response_is_journaled_and_reconcilable(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        env=self.env.copy();env['FAKE_TOGGLE_MODE']='mutate-then-error'
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',env=env,expect=1)
        self.assertTrue((self.state/'quarantine/pending/mod.alpha.rollback').exists())
        self.assertTrue(json.loads(self.mods.read_text())['mod.alpha'])
        self.assertIn('ROLLBACK_RECONCILED',self.run_shell('guardian.sh','rollback-reconcile','mod.alpha','--apply'))
        self.assertFalse((self.state/'quarantine/active/mod.alpha.record').exists())

    def test_rollback_pretend_is_journaled_and_can_be_cancelled(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        env=self.env.copy();env['FAKE_TOGGLE_MODE']='pretend'
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',env=env,expect=1)
        self.assertIn('ROLLBACK_CANCELLED',self.run_shell('guardian.sh','rollback-reconcile','mod.alpha','--apply'))
        self.assertTrue((self.state/'quarantine/active/mod.alpha.record').exists())
        self.assertFalse(json.loads(self.mods.read_text())['mod.alpha'])

    def test_unwritable_ledger_keeps_pending_quarantine_evidence(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine-status')
        ledger=self.state/'quarantine/events.tsv'
        ledger.mkdir()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply',expect=1)
        self.assertTrue((self.state/'quarantine/pending/mod.alpha.record').exists())
        ledger.rmdir()
        self.assertIn('RECONCILED',self.run_shell('guardian.sh','quarantine-reconcile','mod.alpha','--apply'))

    def test_unwritable_ledger_keeps_pending_rollback_evidence(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        ledger=self.state/'quarantine/events.tsv'
        ledger.unlink(); ledger.mkdir()
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',expect=1)
        self.assertTrue((self.state/'quarantine/pending/mod.alpha.rollback').exists())
        ledger.rmdir()
        self.assertIn('ROLLBACK_RECONCILED',self.run_shell('guardian.sh','rollback-reconcile','mod.alpha','--apply'))

    def test_rollback_unrelated_mutation_requires_manual_review(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine','mod.alpha','--apply')
        env=self.env.copy();env['FAKE_TOGGLE_MODE']='mutate-other'
        self.run_shell('guardian.sh','rollback','mod.alpha','--apply',env=env,expect=1)
        self.run_shell('guardian.sh','rollback-reconcile','mod.alpha','--apply',expect=1)
        self.assertTrue((self.state/'quarantine/active/mod.alpha.record').exists())
        self.assertTrue((self.state/'quarantine/pending/mod.alpha.rollback').exists())

    def test_isolated_quarantine_lab_faults_do_not_touch_real_vector(self):
        self.good_boot()
        real_db=self.db.read_bytes()
        real_modules=self.mods.read_bytes()
        output=self.run_shell('guardian.sh','quarantine-lab')
        for marker in ('PREVIEW_NO_MUTATION','TRANSACTIONAL_DISABLE_ROLLBACK',
                       'NOOP_RESPONSE_CANCELLED','LOST_REPLY_RECONCILED',
                       'LEDGER_FAILURE_RECOVERED','UNRELATED_DELTA_BLOCKED'):
            self.assertIn('PASS_Q_LAB_'+marker,output)
        self.assertIn('PASS_GUARDIAN_ISOLATED_QUARANTINE_LAB',output)
        self.assertEqual(self.db.read_bytes(),real_db)
        self.assertEqual(self.mods.read_bytes(),real_modules)
        self.assertFalse((self.state/'quarantine-lab/.lock').exists())
        self.assertFalse(list((self.state/'quarantine-lab').glob('run-*')))
        self.assertEqual((self.state/'quarantine-lab/last-result.txt').read_text().strip(),'PASS')
        self.assertFalse((self.state/'quarantine/active/lab.alpha.record').exists())

    def test_qualification_distinguishes_sandbox_from_live_gate(self):
        self.good_boot()
        self.run_shell('guardian.sh','quarantine-lab')
        self.run_shell('guardian.sh','recovery-lab')
        output=self.run_shell('guardian.sh','qualification')
        self.assertIn('sandbox_quarantine_lab=PASS',output)
        self.assertIn('sandbox_restore_lab=PASS',output)
        self.assertIn('actual_early_boot_restore_test=NOT_VERIFIED',output)
        self.assertIn('live_quarantine_roundtrip=NOT_VERIFIED',output)
        self.assertIn('qualification=UNQUALIFIED',output)
        self.assertEqual(self.run_shell('guardian.sh','report').find('"qualification":"UNQUALIFIED"')>=0,True)

    def test_recovery_lab_rehearses_staging_without_touching_real_vector(self):
        self.good_boot()
        real = self.db.read_bytes()
        before = json.loads(self.mods.read_text())
        result = self.run_shell('guardian.sh', 'recovery-lab')
        self.assertIn('PASS_STAGE_DIGEST_REJECTION', result)
        self.assertIn('PASS_INTERRUPTED_STAGE_PRESERVES_OLD_TARGET', result)
        self.assertIn('PASS_STAGED_REPLACEMENT_AND_SQLITE_INTEGRITY', result)
        self.assertIn('PASS_STAGE_ROLLBACK_AFTER_POSTCOMMIT_FAULT',result)
        self.assertIn('PASS_GUARDIAN_ISOLATED_RECOVERY_LAB', result)
        self.assertEqual(self.db.read_bytes(), real)
        self.assertEqual(json.loads(self.mods.read_text()), before)
        self.assertFalse((self.state/'recovery-lab/.lock').exists())
        evidence=json.loads((self.state/'recovery-lab/last-result.json').read_text())
        self.assertEqual(evidence['result'], 'PASS')
        self.assertFalse(evidence['real_vector_db_modified'])
        self.assertFalse(evidence['offline_restore_device_qualified'])

    def test_recovery_lab_refuses_unattested_snapshot(self):
        self.good_boot()
        observed=self.state/'snapshots/observed.db'
        observed.write_bytes(observed.read_bytes()+b'corruption')
        original=self.db.read_bytes()
        self.run_shell('guardian.sh','recovery-lab',expect=1)
        self.assertEqual(self.db.read_bytes(), original)
        self.assertFalse((self.state/'recovery-lab/last-result.json').exists())

    def test_recovery_plan_exclusion_is_read_only(self):
        self.good_boot()
        before=self.mods.read_bytes()
        result=self.run_shell('guardian.sh','recovery-plan','com.openai.chatgpt')
        self.assertIn('decision=EXCLUDED_BY_USER',result)
        self.assertIn('next_step=NO_MODULE_ACTION',result)
        self.assertIn('automatic_action=disabled',result)
        self.assertEqual(before,self.mods.read_bytes())

    def test_recovery_plan_never_mutates_without_evidence(self):
        self.good_boot()
        before=self.mods.read_bytes()
        result=self.run_shell('guardian.sh','recovery-plan','system_server')
        self.assertIn('decision=INSUFFICIENT_CRASH_EVIDENCE',result)
        self.assertIn('next_step=NO_MODULE_ACTION',result)
        self.assertEqual(before,self.mods.read_bytes())
        self.run_shell('guardian.sh','recovery-plan','oops;id',expect=2)

    def test_panel_is_read_only_and_shows_snapshot_state(self):
        self.good_boot()
        original=self.db.read_bytes()
        result=self.run_shell('guardian.sh','panel')
        self.assertIn('READ-ONLY PANEL',result)
        self.assertIn('observed=sqlite_integrity_verified',result)
        self.assertIn('mode=OBSERVE',result)
        self.assertEqual(self.db.read_bytes(), original)

    def test_webui_is_bundled_and_has_no_mutation_or_network_calls(self):
        root=ROOT/'webroot'
        for file in ('index.html','main.css','main.js'):
            self.assertTrue((root/file).is_file())
        js=(root/'main.js').read_text()
        self.assertIn('recovery-plan ${target}',js)
        self.assertIn('report',js)
        self.assertIn('textContent',js)
        self.assertNotIn('innerHTML',js)
        self.assertNotIn('fetch(',js)
        self.assertNotIn('rollback --apply',js)
        self.assertNotIn('quarantine --apply',js)
        self.assertNotIn('restore --apply',js)
        self.assertNotIn('https://', (root/'index.html').read_text())


if __name__=='__main__': unittest.main()
