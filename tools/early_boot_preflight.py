#!/usr/bin/env python3
"""READ-ONLY Android early-boot restore readiness inventory.

Never mutates the live Vector database or creates a baseline. A green preflight
is not a genuine early-boot restoration qualification.
"""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path.home()/'.local'/'state'/'lsposed-guardian'/'real-gates'
ROOT.mkdir(parents=True, exist_ok=True)
p = ROOT/('early-boot-preflight-'+time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())+'.json')
commands = {
    'android_build': 'getprop ro.build.fingerprint',
    'selinux_mode': 'getenforce',
    'root_context': 'id -Z',
    'boot_completed': 'getprop sys.boot_completed',
    'vector_db_metadata': 'ls -ldZ /data/adb/lspd/config /data/adb/lspd/config/modules_config.db',
    'vector_wal_metadata': 'ls -lZ /data/adb/lspd/config/modules_config.db-wal /data/adb/lspd/config/modules_config.db-shm',
    'guardian_restore_qualification': '/data/adb/modules/lsposed_guardian/guardian.sh qualification',
}
results={}
logs=[]
for name, cmd in commands.items():
    try:
        res=subprocess.run(['su','-c',cmd],capture_output=True,text=True,timeout=30,errors='replace')
        results[name]={'exit_code':res.returncode,'stdout':res.stdout.strip(),'stderr':res.stderr.strip()}
    except Exception as e:
        results[name]={'error':str(e)}
    logs.append('=== '+name+' ===\n'+json.dumps(results[name],ensure_ascii=False))
receipt={'schema':'guardian-early-boot-preflight-v1','qualification':'NOT_VERIFIED',
         'mutation':False,'actual_restore_attempted':False,
         'note':'This is inventory only. Real restore must be tested on a disposable Android environment with independent rescue.',
         'evidence':results}
p.write_text(json.dumps(receipt,indent=2,ensure_ascii=False)+'\n')
logs += ['qualification=NOT_VERIFIED','actual_early_boot_restore_test=NOT_VERIFIED','evidence='+str(p)]
out='\n'.join(logs)+'\n'
print(out,end='',flush=True)
try:
    clip=subprocess.run(['termux-clipboard-set'],input=out,text=True,timeout=15,capture_output=True)
    print('clipboard='+('COPIED' if clip.returncode==0 else 'FAILED'))
except Exception:
    print('clipboard=UNAVAILABLE')
