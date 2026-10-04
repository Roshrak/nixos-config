#!/usr/bin/env python3
"""Evaluate and execute both real flake apps in read-only plan mode.

Package builds alone do not force evaluation of the apps attribute.
"""
import json
from pathlib import Path
import subprocess

repo=Path(__file__).resolve().parents[2]
for name in ('install','default'):
    command=['nix','--extra-experimental-features','nix-command flakes','run',
             '--offline','--no-write-lock-file',f'path:{repo}#{name}','--','--plan']
    result=subprocess.run(command,text=True,capture_output=True)
    if result.returncode:
        raise AssertionError(f'{name} app exit {result.returncode}: {result.stderr}')
    plan=json.loads(result.stdout)
    assert plan['mode']=='PLAN_ONLY' and plan['target']=='/mnt'
    assert plan['flow'][-1]=='verify' and plan['reboot']=='manual after completion'
    print(f'{name}: real nix run app evaluation + execution PLAN_ONLY: PASS')
