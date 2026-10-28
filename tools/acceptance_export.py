#!/usr/bin/env python3
"""Export already recorded manual Guardian acceptance; no device mutations."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
GUARDIAN='/data/adb/modules/lsposed_guardian/guardian.sh'
SOURCES=('guardian.sh','lib/qualification.sh','lib/one-shot.sh','lib/crash.sh','module.prop')

def parsed(text: str) -> dict:
    result={}
    for line in text.splitlines():
        if '=' not in line:continue
        key,value=line.split('=',1)
        if re.fullmatch(r'[a-z_][a-z_0-9]*',key):
            result[key]=value[:256]
    return result

def safe_receipt(qualification: str, restore: str, crash: str, boot_id: str) -> dict:
    q=parsed(qualification);r=parsed(restore);c=parsed(crash)
    manual=q.get('actual_early_boot_restore_test') == 'PASS_MANUAL_ONE_SHOT_RECEIPT'
    confirmed=r.get('transaction_phase') == 'HEALTH_CONFIRMED' and 'PASS_GUARDIAN_REAL_ONE_SHOT_RESTORE' in restore
    return {
       'schema_version':1,'producer':'lsposed-guardian','receipt_type':'historical_manual_device_evidence',
       'boot_id_at_export':boot_id, 'guardian_version':q.get('version','unknown'),
       'manual_restore_receipt':'PASS' if manual and confirmed else 'UNVERIFIED',
       'historical_restore_boot_id':q.get('actual_restore_boot_id'),
       'historical_quarantine':q.get('live_quarantine_roundtrip','NOT_VERIFIED'),
       'historical_boot_order':q.get('boot_order_observation','NOT_VERIFIED'),
       'historical_copy_only_trial':q.get('copy_only_boot_trial','NOT_VERIFIED'),
       'transaction_phase':r.get('transaction_phase','unknown'),
       'crash_history_current_count':c.get('retained_events','unknown'),
       'crash_history_sha256':c.get('history_sha256','unknown'),
       'continuity_last_digest_status':c.get('continuity_current_digest','unknown'),
       'overall_automatic_recovery_qualified':False,
       'automatic_quarantine_enabled':False,
       'offline_undo_verified':False,
       'power_loss_verified':False,
       'exclusive_sqlite_access_verified':False,
       'evidence_digests_sha256':{
         'qualification':hashlib.sha256(qualification.encode()).hexdigest(),
         'one_shot_status':hashlib.sha256(restore.encode()).hexdigest(),
         'crash_audit':hashlib.sha256(crash.encode()).hexdigest(),
       },
       'source_sha256':{path:hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in SOURCES},
    }

def call(cmd):
    p=subprocess.run(['su','-c',"'/system/bin/sh' '"+GUARDIAN+"' "+cmd],capture_output=True,text=True,timeout=35)
    if p.returncode:raise RuntimeError('guardian_read_only_'+cmd.replace('-','_')+'_failed')
    return p.stdout

def main():
    try:
        values=[call(cmd) for cmd in ('qualification','one-shot-status','crash-audit')]
        boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        if not re.fullmatch(r'[0-9a-fA-F-]{36}',boot):raise RuntimeError('invalid_boot_id')
        data=safe_receipt(*values,boot)
        dest=Path.home()/'.local/state/lsposed-guardian/acceptance'
        dest.mkdir(mode=0o700,parents=True,exist_ok=True)
        target=dest/('manual-evidence-'+boot+'-'+str(time.time_ns())+'.json')
        fd,sp=tempfile.mkstemp(prefix='.receipt-',dir=dest)
        try:
            with os.fdopen(fd,'w') as f:
                json.dump(data,f,sort_keys=True,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
            os.chmod(sp,0o600)
            os.replace(sp,target)
        finally:
            if os.path.exists(sp):os.unlink(sp)
        print('PASS_GUARDIAN_HISTORICAL_ACCEPTANCE_EXPORT')
        print('automatic_recovery_qualified=false')
        print('manual_restore_receipt='+data['manual_restore_receipt'])
        print('evidence='+str(target))
        return 0
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as e:
        print('FAIL_GUARDIAN_ACCEPTANCE_EXPORT: '+str(e),file=sys.stderr)
        return 1
if __name__=='__main__':sys.exit(main())
