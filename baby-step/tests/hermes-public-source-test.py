#!/usr/bin/env python3
"""Actual selected-source/restore functions, confined to disposable paths."""
import hashlib,json,os,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REPO=Path(os.environ.get('BACKUP_REPO',str(Path.home()/'nixos-config')))
MANIFEST=ROOT/'custom-service-manifest.tsv'
CONTRACT=ROOT/'lib/custom-service-manifest.json'
RESTORE=REPO/'scripts/lib/custom-service-restore.sh'
PREPARE=ROOT/'lib/custom-service-manifest.sh'
PUBLIC=json.loads(CONTRACT.read_text())['public_files']
def run(body,*args,ok=True):
 r=subprocess.run(['bash','-euo','pipefail','-c',body,'fixture',*map(str,args)],capture_output=True,text=True)
 if ok and r.returncode:raise AssertionError('Actual fixture function failed: '+r.stderr)
 return r

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='hermes-public-source-test.') as tmp:
 t=Path(tmp);t.chmod(0o700);home=t/'home';repo=t/'retained-repository';prepared=t/'prepared';target=t/'target';recovery=t/'recovery'
 for p in [home,target,prepared,repo]:p.mkdir(mode=0o700)
 for f in PUBLIC:
  source=REPO/'dotfiles'/f['path'];dest=(home if f['origin']=='home' else repo/'dotfiles')/f['path'];dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest)
 for rel in ['.local/bin/mc_chat_responder.py','.config/systemd/user/agy-bridge.service','.config/systemd/user/mc-chat-responder.service']:
  dest=home/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(REPO/'dotfiles'/rel,dest)
 # Include private decoys only in the source HOME, never in the public repo.
 (home/'.hermes/.env').write_text('private operator fixture\n');(home/'.hermes/auth.json').write_text('{}\n');(home/'.hermes/cron').mkdir();(home/'.hermes/cron/jobs.json').write_text('private scheduler fixture\n')
 dotconfig=prepared/'dotconfig';shutil.copytree(home/'.config',dotconfig);localbin=prepared/'local-bin';files=prepared/'custom-files'
 command='source "$1"; prepare_custom_service_sources "$2" "$3" "$4" "$5" "$6" "$7"'
 run(command,PREPARE,MANIFEST,home,dotconfig,localbin,files,repo)
 for f in PUBLIC:
  expected=(home if f['origin']=='home' else repo/'dotfiles')/f['path'];assert digest(files/f['path'])==digest(expected)
 assert sorted(str(p.relative_to(files)) for p in files.rglob('*') if p.is_file())==sorted(f['path'] for f in PUBLIC)
 assert not (home/'.hermes/plugins').exists()
 print('Exact selected code/retained source coverage, no private cron/credentials, no policy activation: PASS')
 # Build a production-shaped dotfiles input, then call the actual shared restore.
 dotfiles=t/'restore-source';shutil.copytree(files,dotfiles);shutil.copytree(dotconfig,dotfiles/'.config');shutil.copytree(localbin,dotfiles/'.local/bin')
 (target/'.hermes/scripts').mkdir(parents=True);(target/'.hermes').chmod(0o700)
 preserved=target/'.hermes/.env';preserved.write_text('preserved private fixture\n');private_hash=digest(preserved)
 originals={}
 for f in PUBLIC:
  if f['restore']:
   p=target/f['path'];p.parent.mkdir(parents=True,exist_ok=True);p.write_text('original '+f['path']+'\n');p.chmod(0o600);originals[f['path']]=(digest(p),p.stat().st_mode & 0o777)
 uid=os.getuid();gid=os.getgid();body='source "$1"; run_root() { "$@"; }; restore_hermes_bridge "$2" "$3" "$4" "$5" "$6" "$7"'
 run(body,RESTORE,MANIFEST,dotfiles,target,recovery,uid,gid)
 for f in PUBLIC:
  p=target/f['path']
  if f['restore']:
   assert digest(p)==digest(dotfiles/f['path']);assert p.stat().st_mode & 0o777==int(f['mode'],8)
  else:assert not p.exists()
 assert digest(preserved)==private_hash
 recipe=json.loads((target/'.hermes/scripts/clean-system.job.json').read_text());assert recipe['schedule']=={'kind':'interval','minutes':720};assert recipe['no_agent'] is True;assert not (target/'.hermes/cron').exists()
 state={f['path']:(target/f['path']).stat().st_ino for f in PUBLIC if f['restore']}
 run(body,RESTORE,MANIFEST,dotfiles,target,t/'noop-recovery',uid,gid)
 assert state=={f['path']:(target/f['path']).stat().st_ino for f in PUBLIC if f['restore']};assert not (t/'noop-recovery').exists()
 print('Actual isolated bridge/cleaner/recipe restore, executable mode, source parity, preserved secrets, no policy or cron activation, idempotence: PASS')
 rollback='source "$1"; run_root() { "$@"; }; rollback_hermes_bridge "$2" "$3" "$4" "$5"'
 run(rollback,RESTORE,recovery,target,uid,gid)
 for rel,(sha,mode) in originals.items():assert digest(target/rel)==sha;assert (target/rel).stat().st_mode & 0o777==mode
 assert digest(preserved)==private_hash
 print('All three per-file rollback receipts restore exact before-images and modes: PASS')
 # A later helper edit is preserved rather than silently rolled back.
 recovery2=t/'recovery-2';run(body,RESTORE,MANIFEST,dotfiles,target,recovery2,uid,gid);p=target/'.hermes/scripts/clean-system.py';p.write_text('later user edit\n');sha=digest(p)
 r=run(rollback,RESTORE,recovery2,target,uid,gid,ok=False);assert r.returncode!=0;assert digest(p)==sha;assert (recovery2/'hermes-clean-system/previous').is_file()
 print('Later cleaner edits refuse rollback and preserve both user work and before-image: PASS')
 # The actual public-content preflight rejects all unknown/private and linked data.
 check='source "$1"; custom_restore_validate_repository_private_content "$2"'
 source_repo=t/'public-repository';shutil.copytree(dotfiles,source_repo/'dotfiles');run(check,RESTORE,source_repo)
 for rel in ['.hermes/.env','.hermes/auth.json','.hermes/cache/junk','.hermes/plugins/human-stage-policy/unreviewed.py','.hermes/cron/jobs.json']:
  p=source_repo/'dotfiles'/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('private decoy\n');assert run(check,RESTORE,source_repo,ok=False).returncode!=0;p.unlink()
  # Remove only newly-created empty decoy directory skeletons.
  for parent in [p.parent,p.parent.parent]:
   if parent in [source_repo/'dotfiles/.hermes/cache',source_repo/'dotfiles/.hermes/cron'] and parent.exists():parent.rmdir()
 leaf=source_repo/'dotfiles/.hermes/scripts/clean-system.py';leaf.unlink();leaf.symlink_to(t/'outside');assert run(check,RESTORE,source_repo,ok=False).returncode!=0;leaf.unlink();shutil.copy2(dotfiles/'.hermes/scripts/clean-system.py',leaf)
 scripts=source_repo/'dotfiles/.hermes/scripts';scripts.rename(source_repo/'dotfiles/.hermes/held');scripts.symlink_to(t/'outside-directory');assert run(check,RESTORE,source_repo,ok=False).returncode!=0
 print('Real private-content preflight rejects private/unknown files and leaf/ancestor symlinks: PASS')
 # Pinned source preparation refuses a linked ancestor, never reading its target.
 source_scripts=home/'.hermes/scripts';source_scripts.rename(home/'.hermes/saved-scripts');source_scripts.symlink_to(home/'.hermes/saved-scripts');fresh=t/'prepare-refusal';fresh.mkdir()
 assert run(command,PREPARE,MANIFEST,home,dotconfig,fresh/'bin',fresh/'files',repo,ok=False).returncode!=0
 print('Selected source ancestor symlink is rejected during descriptor-relative copy: PASS')
print('Hermes exact public-source/recovery suite: PASS (no live replacement, scheduling, service or network action)')
