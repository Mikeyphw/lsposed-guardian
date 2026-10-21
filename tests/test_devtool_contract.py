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
  self.assertEqual([x['id'] for x in steps],['preflight','unit','contract','ui','ci-parity','qualification','package','verify','install'])
  self.assertEqual(steps[-1]['ref'],'job:flash-ksu')
  self.assertEqual(steps[-1]['depends_on'],['verify'])
  self.assertEqual(steps[-2]['ref'],'job:verify-package')

 def test_install_requires_full_qualification_graph(self):
  steps=TARGET['workflows']['install']
  q=next(item for item in steps if item['id']=='qualification')
  self.assertEqual(set(q['depends_on']),{'unit','contract','ui','ci-parity'})
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
  self.assertEqual(ids,{'guardian-shell','guardian-python','guardian-webui','guardian-devtool-contract'})

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

 def test_app_package_is_android_installable_root_module(self):
  prop=(ROOT/'module.prop').read_text()
  self.assertIn('id=lsposed_guardian\n',prop)
  for name in ('service.sh','post-fs-data.sh','customize.sh','webroot/index.html'):
   self.assertTrue((ROOT/name).is_file())

if __name__=='__main__':unittest.main()
