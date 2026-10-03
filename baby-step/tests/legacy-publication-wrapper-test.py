#!/usr/bin/env python3
"""Execute current legacy wrapper in a disposable repository/home only."""
import os,json,hashlib,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];REPO=Path(os.environ.get('BACKUP_REPO',str(Path.home()/'nixos-config')));SCRIPT=REPO/'scripts/sync-current-tonelico-to-github.sh';GIT=shutil.which('git')
def run(args,env=None,ok=True):
 r=subprocess.run(list(map(str,args)),env=env,capture_output=True,text=True,stdin=subprocess.DEVNULL)
 if ok and r.returncode:raise AssertionError('fixture command failed: '+r.stderr)
 return r

def write(p,s):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s);p.chmod(0o755)
with tempfile.TemporaryDirectory(prefix='legacy-publication-wrapper-test.') as tmp:
 t=Path(tmp);t.chmod(0o700);home=t/'home';repo=home/'nixos-config';wrapper=repo/'scripts/sync-current-tonelico-to-github.sh';wrapper.parent.mkdir(parents=True);shutil.copy2(SCRIPT,wrapper);env=os.environ.copy();env['HOME']=str(home)
 r=run(['bash',wrapper],env,False);assert r.returncode!=0;assert 'nothing changed' in r.stderr
 marker=t/'arguments';target=home/'baby-step/update-and-push.sh';write(target,'#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\nPath('+repr(str(marker))+').write_text(json.dumps(sys.argv[1:]))\nraise SystemExit(37)\n')
 for args,want in [([],['--backup-only']),(['--check-only'],['--check-only']),(['--help'],['--help']),(['-h'],['--help'])]:
  r=run(['bash',wrapper,*args],env,False);assert r.returncode==37;assert json.loads(marker.read_text())==want
 marker.unlink();r=run(['bash',wrapper,'--resume-backup'],env,False);assert r.returncode==64;assert not marker.exists()
 r=run(['bash',wrapper,'--check-only','extra'],env,False);assert r.returncode==64;assert not marker.exists()
 print('Actual wrapper dispatch is snapshot-only; unsupported/missing implementations fail closed and executor status propagates: PASS')
 # Actual maintained implementation: staged user work must survive intact.
 for rel in ['update-and-push.sh','lib/common.sh','lib/source-manifest.sh','lib/publication-check.py','lib/custom-service-manifest.json']:
  p=home/'baby-step'/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/rel,p)
 for rel in ['backup-config.sh','check-system.sh','update-system.sh']:
  write(home/'baby-step'/rel,'#!/usr/bin/env bash\n[ "${1:-}" = --check-only ] && exit 0\nexit 79\n')
 run([GIT,'init','-q','-b','main',repo]);run([GIT,'-C',repo,'config','user.name','Fixture']);run([GIT,'-C',repo,'config','user.email','fixture@example.invalid']);run([GIT,'-C',repo,'remote','add','origin','https://github.com/Roshrak/nixos-config.git'])
 p=repo/'README.md';p.write_text('baseline\n');run([GIT,'-C',repo,'add','--','README.md']);run([GIT,'-C',repo,'commit','-qm','fixture baseline']);head=run([GIT,'-C',repo,'rev-parse','HEAD']).stdout.strip();run([GIT,'-C',repo,'update-ref','refs/remotes/origin/main',head]);p.write_text('preexisting staged user work\n');run([GIT,'-C',repo,'add','--','README.md']);untracked=repo/'untracked-work';untracked.write_text('keep\n');index=hashlib.sha256((repo/'.git/index').read_bytes()).hexdigest()
 env.update(BABY_STEP_DIR=str(home/'baby-step'),BACKUP_REPO=str(repo),NIXOS_DIR=str(repo/'nixos'))
 r=run(['bash',wrapper],env,False);assert r.returncode!=0;assert 'Existing staged work' in r.stderr;assert hashlib.sha256((repo/'.git/index').read_bytes()).hexdigest()==index;assert untracked.read_text()=='keep\n';assert run([GIT,'-C',repo,'rev-parse','HEAD']).stdout.strip()==head
 print('Actual legacy→maintained path refuses existing staged work and preserves HEAD/index/untracked files: PASS')
 # A clean index plus declared/active drift must refuse snapshot publication.
 p.write_text('baseline\n');run([GIT,'-C',repo,'add','--','README.md']);index=hashlib.sha256((repo/'.git/index').read_bytes()).hexdigest();
 for directory in ['baby-step','dotfiles','docs']:(repo/directory).mkdir()
 (repo/'.gitignore').write_text('# isolated fixture\n')
 (repo/'nixos').mkdir();(repo/'nixos/flake.nix').write_text('{}\n');bins=t/'bin';bins.mkdir();calls=t/'calls'
 write(bins/'nix','''#!/usr/bin/env python3
import sys,os
from pathlib import Path
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write('nix\\n')
a=' '.join(sys.argv[1:])
if '--json' in a:print('["tonelico"]')
elif 'networking.hostName' in a:
 import socket;print(socket.gethostname(),end='')
elif 'system.build.toplevel.outPath' in a:print('/nix/store/fixture-declared-drift',end='')
else:raise SystemExit(77)
''')
 write(bins/'git','''#!/usr/bin/env python3
import os,sys,subprocess
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write('git '+repr(sys.argv[1:])+'\\n')
if 'fetch' in sys.argv[1:]:raise SystemExit(0)
if any(a in ['push','pull','rebase','commit'] for a in sys.argv[1:]) or ('add' in sys.argv[1:] and '--dry-run' not in sys.argv[1:]):raise SystemExit(81)
raise SystemExit(subprocess.call([os.environ['FIXTURE_REAL_GIT']]+sys.argv[1:]))
''');env.update(PATH=str(bins)+os.pathsep+os.environ['PATH'],FIXTURE_CALLS=str(calls),FIXTURE_REAL_GIT=GIT)
 r=run(['bash',wrapper],env,False);assert r.returncode!=0;assert 'declared configuration differs' in r.stderr, (r.stdout,r.stderr);assert hashlib.sha256((repo/'.git/index').read_bytes()).hexdigest()==index;assert untracked.read_text()=='keep\n';assert not any("'push'" in s or "'commit'" in s or ("'add'" in s and "'--dry-run'" not in s) for s in calls.read_text().splitlines())
 print('Actual maintained drift guard blocks legacy snapshot before staging/commit/push: PASS')
print('Legacy snapshot wrapper suite: PASS (network blocked; no real repository or system mutation)')
