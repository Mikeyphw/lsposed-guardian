#!/usr/bin/env python3
"""Verify release ZIP against source, archive paths, modes and recorded hashes."""
from __future__ import annotations
import hashlib, json
from pathlib import Path
from zipfile import ZipFile
ROOT=Path(__file__).resolve().parents[1]
D=ROOT/'dist'
evidence=json.loads((D/'build-evidence.json').read_text())
assert evidence['device_restore_qualified'] is False
for kind in ('install','source'):
 info=evidence[kind]
 name=info['filename']
 p=D/name
 assert p.is_file(), f'missing {p}'
 assert hashlib.sha256(p.read_bytes()).hexdigest()==info['sha256'],f'archive digest mismatch: {name}'
 with ZipFile(p) as z:
  assert z.testzip() is None
  entries=z.namelist()
  assert len(entries)==info['file_count']==len(set(entries))
  assert all(not item.startswith('/') and '..' not in Path(item).parts for item in entries)
  if kind=='install':
   assert z.read('module.prop')==(ROOT/'module.prop').read_bytes()
   manifest=z.read('FILE_SHA256SUMS.txt').decode().splitlines()
   assert len(manifest)==len(entries)-1
   for line in manifest:
    digest,path=line.split('  ',1)
    assert hashlib.sha256(z.read(path)).hexdigest()==digest==hashlib.sha256((ROOT/path).read_bytes()).hexdigest(),path
   for item in entries:
    assert item=='FILE_SHA256SUMS.txt' or item in [x.split('  ',1)[1] for x in manifest]
print('PASS_GUARDIAN_BUILD_HASHES_ARCHIVES_AND_MANIFEST')
