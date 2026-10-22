#!/usr/bin/env python3
"""Build reproducible installable and source archives. No root/device required."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'dist'
VERSION = next(line.split('=',1)[1].strip() for line in (ROOT/'module.prop').read_text().splitlines() if line.startswith('version='))
INSTALL = [
 'module.prop','config.defaults','customize.sh','action.sh','guardian.sh',
 'post-fs-data.sh','service.sh','crash-monitor.sh','history-monitor.sh','selftest.sh','uninstall.sh',
 'lib/common.sh','lib/crash.sh','lib/history.sh','lib/quarantine.sh',
 'lib/recovery-lab.sh','lib/quarantine-lab.sh','lib/qualification.sh','lib/policy.sh','lib/boot-probe.sh','lib/boot-trial.sh',
 'webroot/index.html','webroot/main.css','webroot/main.js','README.md','docs/ROADMAP.md',
]
EXECUTABLE={'customize.sh','action.sh','guardian.sh','post-fs-data.sh','service.sh',
 'crash-monitor.sh','history-monitor.sh','selftest.sh','uninstall.sh'}
SKIP_DIRS={'.git','.devtool','.venv','dist','__pycache__','.pytest_cache','device-evidence'}
SKIP_FILES={'.DS_Store','.devtool-wrapper.lock'}

def sha(data: bytes) -> str:
 return hashlib.sha256(data).hexdigest()

def source_paths():
 return sorted(p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()
    and not set(p.relative_to(ROOT).parts).intersection(SKIP_DIRS)
    and p.name not in SKIP_FILES and not p.name.endswith(('.pyc','.log')))

def add(z, path, content):
 info=ZipInfo(path, date_time=(2026,10,21,0,0,0))
 info.create_system=3
 info.external_attr=(0o100000 | (0o755 if path in EXECUTABLE or path in {'devtoolw','tools/bootstrap.sh','tools/install.sh','tools/device_check.sh'} else 0o644))<<16
 info.compress_type=ZIP_DEFLATED
 z.writestr(info,content)

def make(paths,out,extra=None):
 with ZipFile(out,'w') as z:
  for path in paths:
   add(z,path,(ROOT/path).read_bytes())
  for path,content in (extra or {}).items():
   add(z,path,content)
 with ZipFile(out) as z:
  assert z.testzip() is None
  names=z.namelist()
  assert len(names)==len(set(names))
  assert all(not n.startswith('/') and '..' not in Path(n).parts for n in names)
 return {'filename':out.name,'size':out.stat().st_size,'sha256':sha(out.read_bytes()),'file_count':len(names)}

if __name__=='__main__':
 OUT.mkdir(parents=True,exist_ok=True)
 for file in INSTALL:
  if not (ROOT/file).is_file():
   raise SystemExit(f'Missing package file: {file}')
 manifest=''.join(f'{sha((ROOT/p).read_bytes())}  {p}\n' for p in INSTALL).encode()
 version='v'+VERSION.lstrip('v')
 install=make(INSTALL,OUT/f'LSPosed-Guardian-{version}.zip',{'FILE_SHA256SUMS.txt':manifest})
 source=make(source_paths(),OUT/f'LSPosed-Guardian-{version}-source.zip')
 result={'schema_version':1,'producer':'guardian-repo-builder','version':VERSION,
         'source_revision':os.environ.get('GITHUB_SHA','not-recorded'),
         'device_restore_qualified':False,'automatic_quarantine_enabled':False,
         'install':install,'source':source}
 (OUT/'build-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result,indent=2))
