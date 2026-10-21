#!/usr/bin/env python3
import subprocess, pathlib, json, sys, time
root=pathlib.Path(__file__).resolve().parents[1]
names=['test_panel_is_read_only_and_shows_snapshot_state','test_recovery_plan_exclusion_is_read_only','test_runtime_version_matches_installed_module_metadata','test_snapshot_integrity_digest_and_sqlite_structure','test_triage_counts_stored_events_without_sampling']
out=[]
for name in names:
    start=time.monotonic()
    try:
        p=subprocess.run([sys.executable,'-m','unittest',f'test_guardian.GuardianTests.{name}','-q'],cwd=root/'tests',capture_output=True,text=True,timeout=120)
        status='PASS' if p.returncode==0 else 'FAIL'
        d=(p.stdout+p.stderr)[-2800:] if status!='PASS' else ''
    except subprocess.TimeoutExpired:
        status='TIMEOUT';d='Exceeded 120 seconds'
    item={'name':name,'status':status,'elapsed_seconds':round(time.monotonic()-start,2),'details':d}
    out.append(item)
    print(status,name,item['elapsed_seconds'],flush=True)
    (root.parent/'LSPosed-Guardian-v0.8.0-targeted-retest-results.json').write_text(json.dumps({'total':len(out),'passed':sum(x['status']=='PASS' for x in out),'results':out},indent=2)+'\n')
raise SystemExit(0 if all(x['status']=='PASS' for x in out) else 1)
