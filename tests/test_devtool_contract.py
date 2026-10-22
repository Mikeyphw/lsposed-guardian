"""Audit the promises of the Devtool integration without requiring root or Devtool in CI."""
import pathlib
import subprocess
import tomllib
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
CONF=tomllib.loads((ROOT/'.devtool.toml').read_text())
WRAP=CONF['wrapper']['commands']
TARGET=CONF['targets']['guardian']

class DevtoolContractTests(unittest.TestCase):
 def test_wrapper_schema_canonical(self):
  self.assertEqual(CONF['wrapper']['schema'],2)
  self.assertEqual(CONF['workspace']['default_target'],'guardian')
  self.assertEqual(TARGET['execution_environment'],'native-termux')
  self.assertEqual(TARGET['runner'],'command')

 def test_install_workflow_has_integrity_prerequisite(self):
  steps=TARGET['workflows']['install']
  self.assertEqual([x['id'] for x in steps],['preflight','unit','contract','ui','ci-parity','wal-model','qualification','package','verify','install'])
  self.assertEqual(steps[-1]['ref'],'job:flash-ksu')
  self.assertEqual(steps[-1]['depends_on'],['verify'])
  self.assertEqual(steps[-2]['ref'],'job:verify-package')

 def test_install_requires_full_qualification_graph(self):
  steps=TARGET['workflows']['install']
  q=next(item for item in steps if item['id']=='qualification')
  self.assertEqual(set(q['depends_on']),{'unit','contract','ui','ci-parity','wal-model'})
  p=next(item for item in steps if item['id']=='package')
  self.assertEqual(p['depends_on'],['qualification'])
  src=(ROOT/'tools/qualify_host.py').read_text()
  self.assertIn('Tested source differs from current Guardian runtime',src)
  self.assertIn('Duplicate test result names',src)

 def test_ci_parity_checker(self):
  p=subprocess.run(['python3',str(ROOT/'tools/check_ci_parity.py')],cwd=ROOT,text=True,capture_output=True,timeout=10)
  self.assertEqual(p.returncode,0,p.stderr)
  self.assertIn('PASS_GUARDIAN_CI_MIRROR_MATCHES_DEVTOOL_CHECK_DAG',p.stdout)

 def test_install_not_auto_invoked_in_check_or_ci(self):
  for action in ('check','test','build'):
   refs=[x['ref'] for x in TARGET['workflows'][action]]
   self.assertNotIn('job:flash-ksu',refs)
  for f in (ROOT/'.github/workflows').glob('*.yml'):
   self.assertNotIn('devtoolw install',f.read_text())

 def test_explicit_ksud_install_preserves_tty(self):
  script=(ROOT/'tools/install.sh').read_text()
  self.assertIn('ksud module install',script)
  self.assertIn('su -c',script)
  self.assertNotIn('reboot\n',script)
  self.assertNotIn(' | tee ',script)
  self.assertIn('tools/pty_install.py',script)
  self.assertIn('tools/verify_build.py',script)

 def test_dry_run_has_no_root_mutation(self):
  # Build disposable artifacts so an old dist/ cannot fail the contract tests.
  import tempfile, shutil, os
  with tempfile.TemporaryDirectory(prefix='guardian-install-contract-') as d:
   target=pathlib.Path(d)/'repo'
   shutil.copytree(ROOT,target,ignore=shutil.ignore_patterns('dist','.git','__pycache__','.devtool','.pytest_cache'))
   p=subprocess.run(['python3','tools/build.py'],cwd=target,text=True,capture_output=True,timeout=15)
   self.assertEqual(p.returncode,0,p.stdout+p.stderr)
   env=os.environ.copy()
   env['GUARDIAN_INSTALL_DRY_RUN']='1'
   p=subprocess.run(['sh','tools/install.sh'],cwd=target,env=env,text=True,capture_output=True,timeout=15)
   self.assertEqual(p.returncode,0,p.stdout+p.stderr)
   self.assertIn('PASS_GUARDIAN_INSTALL_DRY_RUN',p.stdout)

 def test_host_qualification_rejects_untrue_evidence(self):
  import importlib.util, sys
  sys.path.insert(0,str(ROOT/'tools'))
  spec=importlib.util.spec_from_file_location('guardian_qualify',ROOT/'tools/qualify_host.py')
  module=importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  tests=module.expected_names()
  from importlib.util import spec_from_file_location, module_from_spec
  si_spec=spec_from_file_location('source_inventory',ROOT/'tools/source_inventory.py')
  si=module_from_spec(si_spec);si_spec.loader.exec_module(si)
  good={'schema_version':2,'total':len(tests),'passed':len(tests),'failed':0,'source_inventory':si.inventory(),'source_fingerprint':si.fingerprint(),'results':[{'name':x,'status':'PASS'} for x in tests]}
  self.assertEqual(module.verify(good,tests),len(tests))
  for bad in (
   {**good,'passed':len(tests)-1},
   {**good,'results':good['results'][:-1]},
   {**good,'results':good['results']+[good['results'][0]]},
   {**good,'results':[{**good['results'][0],'status':'TIMEOUT'},*good['results'][1:]]},
  ):
   with self.assertRaises(AssertionError):module.verify(bad,tests)

 def test_device_checks_clipboard_complete_stderr(self):
  script=(ROOT/'tools/device_check.sh').read_text()
  for c in ('termux-clipboard-set','2>&1','quarantine-lab','recovery-lab','qualification','exit_code='):
   self.assertIn(c,script)

 def test_pty_handoff_refuses_noninteractive_install(self):
  p=subprocess.run(['python3',str(ROOT/'tools/pty_install.py'),'sh','-c','echo BAD'],
                   stdin=subprocess.DEVNULL,text=True,capture_output=True,timeout=5)
  self.assertNotEqual(p.returncode,0)
  self.assertNotIn('BAD',p.stdout)
  self.assertIn('interactive Termux terminal',p.stderr)

 def test_source_contains_android_verified_journal_reader_and_failure_classes(self):
  reader=(ROOT/'lib/quarantine.sh').read_text()
  lab=(ROOT/'lib/quarantine-lab.sh').read_text()
  qual=(ROOT/'lib/qualification.sh').read_text()
  self.assertIn("sed -n '1p'",reader)
  self.assertIn('Unexpected transaction record: invalid field count',reader)
  self.assertIn('FAIL_Q_LAB_NOOP_RECONCILIATION',lab)
  self.assertIn('last-failure.txt',lab)
  self.assertIn('NOT_RUN',qual)

 def test_full_output_webui_has_async_callback(self):
  src=(ROOT/'webroot/main.js').read_text()
  self.assertIn('ksu.exec',src)
  self.assertTrue('callback' in src.lower() or 'Callback' in src)
  self.assertIn('modulecount',src)

 def test_wrapper_commands_target_guardian(self):
  required=('check','test','build','install','device-check','webui','preflight','doctor')
  for cmd in required:
   self.assertIn(cmd,WRAP)
   self.assertEqual(WRAP[cmd]['target'],'guardian')
   self.assertEqual(sum(x in WRAP[cmd] for x in ('workflow','devtool')),1)

 def test_typed_first_class_test_catalog(self):
  ids={x['id'] for x in CONF['test']}
  self.assertEqual(ids,{'guardian-shell','guardian-python','guardian-webui','guardian-devtool-contract','guardian-early-boot-wal'})

 def test_no_install_in_readonly_flows(self):
  for name in ('syntax','test','check','webui','device-check','preflight','doctor'):
   self.assertNotIn('job:flash-ksu',[s['ref'] for s in TARGET['workflows'][name]])

 def test_publish_is_manual_only(self):
  src=(ROOT/'tools/publish.sh').read_text()
  self.assertIn('gh repo create',src)
  self.assertIn('--public',src)
  self.assertIn('--source=.',src)
  for gate in ('tools/check_ci_parity.py','tools/qualify_host.py','tools/verify_build.py','wrapper seal --json'):
   self.assertIn(gate,src)
  for name in ('check','build','install'):
   self.assertNotIn('publish',str(TARGET['workflows'][name]).lower())

 def test_live_gate_is_explicit_and_never_in_default_ci_dags(self):
  for name in ('live-quarantine-preview','live-quarantine-gate','early-boot-preflight','early-boot-lab'):
   self.assertIn(name,WRAP)
   self.assertEqual(WRAP[name]['target'],'guardian')
   self.assertIn(name,TARGET['workflows'])
  for name in ('check','test','build','install','device-check'):
   refs=[x['ref'] for x in TARGET['workflows'][name]]
   self.assertNotIn('job:live-quarantine-apply',refs)
   self.assertNotIn('job:early-boot-inventory',refs)
  self.assertTrue(TARGET['jobs']['live-quarantine-apply']['metadata']['live_vector_mutation'])
  self.assertTrue(TARGET['jobs']['live-quarantine-apply']['metadata']['never_use_in_ci'])
  from importlib.util import module_from_spec,spec_from_file_location
  spec=spec_from_file_location('guardian_live_quarantine_gate',ROOT/'tools/live_quarantine_gate.py')
  module=module_from_spec(spec);spec.loader.exec_module(module)
  original='PACKAGE UID STATUS\n--------------------------------\neu.hxreborn.remembermysort 10001 enabled\ngithub.tornaco.android.thanos 10002 enabled\n'
  before=module.inventory(original)
  changed=module.inventory(original.replace('10001 enabled','10001 disabled'))
  self.assertTrue(module.only_target_disabled(before,changed))
  self.assertFalse(module.same_full_inventory(before,changed))
  self.assertTrue(module.same_full_inventory(before,module.inventory(original)))
  with self.assertRaises(module.GateFailure):module.inventory('eu.hxreborn.remembermysort 10001 enabled')
  with self.assertRaises(module.GateFailure):module.inventory(original+'eu.hxreborn.remembermysort 10001 enabled\n')
  with self.assertRaises(module.GateFailure):module.inventory(original+'other.package 10022 MAYBE\n')
  self.assertFalse(module.only_target_disabled(before,{**changed,'github.tornaco.android.thanos':{'uid':10002,'state':'disabled'}}))
  src=(ROOT/'tools/live_quarantine_gate.py').read_text()
  self.assertIn('GUARDIAN_GATE_TARGET',src)
  self.assertIn('quarantine-reconcile',src)
  self.assertIn('rollback-reconcile',src)
  self.assertNotIn('modules enable',src)
  self.assertNotIn('modules disable',src)
  self.assertNotIn('reboot(',src)

 def test_live_gate_preflight_uses_root_cli_not_unprivileged_stat(self):
  from unittest.mock import patch
  import importlib.util
  spec=importlib.util.spec_from_file_location('guardian_live_root_probe',ROOT/'tools/live_quarantine_gate.py')
  module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  pk=module.PACKAGE
  class Fake(module.LiveGate):
   def __init__(self, good=True):
    self.apply=False
    self.before=None
    self.results={}
    self.calls=[]
    self.good=good
   def log(self,msg):pass
   def q_status(self):return 'Manual quarantine records:\n (none)\nledger_events=0\n'
   def get_inventory(self,label):return {pk:{'uid':10257,'state':'enabled'},'other.example':{'uid':10888,'state':'enabled'}}
   def cmd(self,label,args,**kwargs):
    self.calls.append(list(args))
    if args==['help']:
     if not self.good:raise module.GateFailure('Guardian exited 127')
     return 0, 'LSPosed Guardian (Vector adapter)\nquarantine PKG\n'
    if args==['doctor']:
     return 0, 'LSPosed Guardian 0.9.0\nmode=OBSERVE\nvector_cli=available\nquarantine_active=0\nquarantine_pending=0\nmanual_restore_queued=no\ndevice_restore_qualified=0\n'
    if args==['scope',pk] or args==['quarantine',pk]:return 0,'read-only\n'
    raise AssertionError('Unexpected command '+repr(args))
  # This is the exact Android failure: stat by Termux can fail while root
  # execution works. Make any unprivileged filesystem probe an assertion.
  with patch.object(module.Path,'exists',side_effect=AssertionError('Unprivileged /data/adb stat forbidden')):
   ok=Fake();ok.preflight()
   self.assertEqual(ok.calls[0],['help'])
   self.assertEqual(ok.results['installed_guardian_root_probe'],'PASS')
   self.assertEqual(ok.results['preflight'],'PASS')
   bad=Fake(good=False)
   with self.assertRaises(module.GateFailure):bad.preflight()
   self.assertNotIn(['quarantine',pk,'--apply'],bad.calls)

 def test_live_gate_mocked_journal_roundtrip_and_failure_cleanup(self):
  import os, tempfile
  from unittest.mock import patch
  from importlib.util import module_from_spec,spec_from_file_location
  spec=spec_from_file_location('guardian_real_test_runner',ROOT/'tools/live_quarantine_gate.py')
  module=module_from_spec(spec);spec.loader.exec_module(module)
  PK=module.PACKAGE
  original={PK:{'uid':101,'state':'enabled'},'github.tornaco.android.thanos':{'uid':202,'state':'enabled'}}
  class Fake(module.LiveGate):
   def __init__(self, fail_apply=False):
    self.apply=True
    self.log_lines=[]
    self.results={}
    self.before=None
    self.disabled_seen=False
    self.rollback_attempted=False
    self.current={k:dict(v) for k,v in original.items()}
    self.pending=False
    self.active=False
    self.ledger=[]
    self.fail_apply=fail_apply
   def log(self,msg): self.log_lines.append(str(msg))
   def save_json(self): pass
   def preflight(self):
    self.before={k:dict(v) for k,v in self.current.items()}
    self.results['preflight']='PASS'
   def get_inventory(self,label):return {k:dict(v) for k,v in self.current.items()}
   def q_status(self):
    if self.pending:return 'NEEDS_RECONCILIATION: '+PK
    if self.active:return 'active: '+PK
    return '  (none)'
   def cmd(self,label,args,**kw):
    if args[:1]==['quarantine'] and args[-1:] == ['--apply']:
     self.current[PK]['state']='disabled'
     self.pending=self.fail_apply
     self.active=not self.fail_apply
     if not self.fail_apply:self.ledger.append('QUARANTINED\t'+PK+'\t999')
     return (1 if self.fail_apply else 0), ''
    if args[:1]==['quarantine-reconcile']:
     self.pending=False;self.active=True
     self.ledger.append('RECONCILED\t'+PK+'\t999')
     return 0,''
    if args[:1]==['rollback']:
     self.current[PK]['state']='enabled';self.active=False
     self.ledger.append('ROLLED_BACK\t'+PK+'\t999')
     return 0,''
    if args[:1]==['quarantine-ledger']:
     return 0,'\n'.join(self.ledger)+'\n'
    raise AssertionError('Unexpected fake command '+str(args))
  with patch.dict(os.environ,{'GUARDIAN_GATE_TARGET':PK}):
   a=Fake();self.assertTrue(a.execute(),a.log_lines)
   self.assertEqual(a.results['outcome'],'PASS_LIVE_VECTOR_QUARANTINE_ROUNDTRIP')
   self.assertEqual(a.current,original)
   self.assertFalse(a.active or a.pending)
   b=Fake(fail_apply=True);self.assertFalse(b.execute())
   self.assertEqual(b.results['outcome'],'FAILED_OR_UNVERIFIED')
   self.assertEqual(b.current,original)
   self.assertFalse(b.active or b.pending)
  with patch.dict(os.environ,{'GUARDIAN_GATE_TARGET':'not-authorized'}):
   c=Fake();self.assertFalse(c.execute());self.assertEqual(c.current,original)

 def test_early_boot_lab_is_hermetic_and_device_gates_remain_open(self):
  import tempfile,json
  from pathlib import Path
  with tempfile.TemporaryDirectory() as tmp:
   receipt=Path(tmp)/'receipt.json'
   p=subprocess.run(['python3',str(ROOT/'tools/early_boot_transaction_lab.py'),'--output',str(receipt)],
                    cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=40)
   self.assertEqual(p.returncode,0,p.stdout+p.stderr)
   data=json.loads(receipt.read_text())
   self.assertEqual(data['result'],'PASS')
   self.assertEqual(data['cases_passed'],9)
   self.assertFalse(data['real_vector_db_modified'])
   self.assertFalse(data['device_qualified'])
   self.assertFalse(data['post_fs_data_code_modified'])
  self.assertEqual(WRAP['early-boot-lab']['workflow'],'early-boot-lab')
  self.assertEqual(TARGET['workflows']['early-boot-lab'][0]['ref'],'job:early-boot-model')
  self.assertNotIn('job:early-boot-model',[x['ref'] for x in TARGET['workflows']['build']])
  self.assertNotIn('early_boot_transaction_lab', (ROOT/'post-fs-data.sh').read_text())

 def test_one_shot_real_boot_probe_is_opt_in_and_non_destructive(self):
  cfg=CONF['targets']['guardian']
  self.assertEqual(WRAP['boot-order-stage']['workflow'],'boot-order-stage')
  self.assertEqual(WRAP['boot-order-status']['workflow'],'boot-order-status')
  self.assertTrue(cfg['jobs']['boot-order-stage']['metadata']['never_use_in_ci'])
  self.assertTrue(cfg['jobs']['boot-order-status']['metadata']['read_only'])
  for workflow in ('check','test','install','build'):
   refs={step['ref'] for step in cfg['workflows'][workflow]}
   self.assertNotIn('job:boot-order-stage',refs)
   self.assertNotIn('job:boot-order-status',refs)
  boot=(ROOT/'post-fs-data.sh').read_text()
  self.assertIn('bp_early || :',boot)
  self.assertNotIn('boot-probe-stage --apply',boot)
  self.assertNotIn('rm -f "$DB-wal"', (ROOT/'lib/boot-probe.sh').read_text())
  p=subprocess.run(['python3','-m','unittest','discover','-s','tests','-p','test_boot_probe.py','-q'],cwd=ROOT,text=True,capture_output=True,timeout=60)
  self.assertEqual(p.returncode,0,p.stdout+p.stderr)

 def test_app_package_is_android_installable_root_module(self):
  prop=(ROOT/'module.prop').read_text()
  self.assertIn('id=lsposed_guardian\n',prop)
  for name in ('service.sh','post-fs-data.sh','customize.sh','webroot/index.html'):
   self.assertTrue((ROOT/name).is_file())

if __name__=='__main__':unittest.main()
