#!/usr/bin/env python3
"""Isolated, parallel host regression tests. Tests never use the device."""
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import importlib.util
import json
import pathlib
import subprocess
import sys
import time
from source_inventory import inventory, fingerprint

parser=argparse.ArgumentParser()
parser.add_argument('--workers',type=int,default=2)
parser.add_argument('--timeout',type=int,default=180)
args=parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'tests' / 'test_guardian.py'
spec = importlib.util.spec_from_file_location('test_guardian', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
names = sorted(n for n in dir(module.GuardianTests) if n.startswith('test_'))
source_inventory_before=inventory()

def run_one(name):
    started=time.monotonic()
    try:
        p=subprocess.run([sys.executable,'-S','-m','unittest',f'test_guardian.GuardianTests.{name}','-q'],cwd=root/'tests',capture_output=True,text=True,timeout=args.timeout)
        ok=p.returncode==0
        return {'name':name,'status':'PASS' if ok else 'FAIL','elapsed_seconds':round(time.monotonic()-started,2),'details':'' if ok else (p.stdout+p.stderr)[-1800:]}
    except subprocess.TimeoutExpired:
        return {'name':name,'status':'TIMEOUT','elapsed_seconds':round(time.monotonic()-started,2)}

with ThreadPoolExecutor(max_workers=max(1,min(args.workers,4))) as pool:
    futures=[pool.submit(run_one,n) for n in names]
    results=[]
    for future in as_completed(futures):
        result=future.result()
        results.append(result)
        print(f"{result['status']:7} {result['name']} ({result['elapsed_seconds']}s)", flush=True)
results.sort(key=lambda r:r['name'])
evidence={'schema_version':2,'total':len(results),'passed':sum(r['status']=='PASS' for r in results),'failed':sum(r['status']!='PASS' for r in results),'source_inventory':source_inventory_before,'source_fingerprint':fingerprint(source_inventory_before),'results':results}
if inventory()!=source_inventory_before:
    evidence['failed']+=1
    evidence['source_changed_during_run']=True
    print('FAIL_GUARDIAN_SOURCE_CHANGED_DURING_REGRESSION',flush=True)
(root/'dist').mkdir(exist_ok=True)
(root/'dist'/'host-test-results.json').write_text(json.dumps(evidence,indent=2)+'\n')
print('TOTAL',evidence['passed'],'/',evidence['total'])
raise SystemExit(0 if evidence['failed']==0 else 1)
