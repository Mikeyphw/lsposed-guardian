#!/usr/bin/env python3
"""Portable preflight: manifest, POSIX shell parse, Python parse, TOML and safety invariants."""
import ast, pathlib, subprocess, sys, tomllib
R=pathlib.Path(__file__).resolve().parents[1]
config=tomllib.loads((R/'.devtool.toml').read_text())
assert config['wrapper']['schema']==2
assert config['workspace']['default_target']=='guardian'
assert config['targets']['guardian']['execution_environment']=='native-termux'
for f in sorted(R.rglob('*.py')):
 if any(x in f.parts for x in ('dist','.git','.venv')):continue
 ast.parse(f.read_text(),filename=str(f))
for f in sorted(R.rglob('*.sh')):
 if any(x in f.parts for x in ('dist','.git','.venv')):continue
 p=subprocess.run(['sh','-n',str(f)],capture_output=True,text=True)
 if p.returncode:raise SystemExit(f'Shell syntax error {f}: {p.stderr}')
prop=(R/'module.prop').read_text()
assert 'id=lsposed_guardian\n' in prop
assert any(line.startswith('version=') and line[8:].strip() for line in prop.splitlines())
assert 'versionCode=' in prop
assert 'EXCLUDED' in (R/'lib/policy.sh').read_text() or 'com.openai.chatgpt' in (R/'config.defaults').read_text()
assert 'su -c' in (R/'tools/install.sh').read_text() and 'ksud module install' in (R/'tools/install.sh').read_text()
print('PASS_GUARDIAN_SOURCE_SYNTAX_TOML_AND_SAFETY_CONTRACT')
