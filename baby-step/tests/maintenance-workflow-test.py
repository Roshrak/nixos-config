#!/usr/bin/env python3
"""Execute production rebuild/update workflows against disposable command shims."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REAL_READLINK = shutil.which("readlink")
SHIM = r'''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]; root=pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root/'calls').open('a') as f: f.write(json.dumps([name]+args)+'\n')
candidate=str(root/'candidate'); previous=str(root/'previous'); fallback=str(root/'fallback')
if name=='hostname': print('fixture-host')
elif name=='df': print('Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 99999999 1 88888888 1% /')
elif name=='readlink':
    path=args[-1]
    targets={'/run/current-system':(root/'active').read_text(),'/run/booted-system':previous,
      '/nix/var/nix/profiles/system':candidate,'/nix/var/nix/profiles/system-130-link':candidate,
      '/nix/var/nix/profiles/system-128-link':previous,'/nix/var/nix/profiles/system-profiles/fallback':fallback}
    if path in targets: print(targets[path])
    else: sys.exit(subprocess.call([os.environ['REAL_READLINK']]+args))
elif name=='nix':
    if args[:2]==['flake','update']: (root/'source/flake.lock').write_text('updated fixture lock\n')
    elif 'builtins.attrNames' in args: print('["tonelico"]')
    elif any('networking.hostName' in a for a in args): print('fixture-host')
    else: print('/nix/store/fixture-system.drv')
elif name=='nixos-rebuild':
    if args[:1]==['list-generations']: print('[{"generation":130,"current":true},{"generation":128,"current":false}]')
    elif 'build' in args:
        if os.environ.get('FIXTURE_LOCK_EDIT')=='1': (root/'source/flake.lock').write_text('later user lock edit\n')
        if os.environ.get('FIXTURE_SOURCE_EDIT')=='1': (root/'source/configuration.nix').write_text('{ laterUserEdit = true; }\n')
        if os.environ.get('FIXTURE_BUILD_FAIL')=='1': print('fixture compiler failed',file=sys.stderr); sys.exit(7)
        if os.environ.get('FIXTURE_NO_RESULT')!='1': pathlib.Path('result').symlink_to(candidate)
        print('fixture compilation progress visible')
    elif 'switch' in args:
        assert '--no-reexec' in args and '--store-path' in args and args[args.index('--store-path')+1]==candidate
        (root/'active').write_text(candidate)
    elif 'dry-activate' in args:
        assert '--no-reexec' in args and '--store-path' in args
    else: sys.exit(91)
elif name=='sudo':
    if args==['-v']: sys.exit(0)
    if args and args[0]=='-n': args=args[1:]
    assert args and args[0] in ('nixos-rebuild','bootctl'), 'unexpected privileged operation in fixture'
    sys.exit(subprocess.call(args))
elif name=='bootctl':
    print(json.dumps([{'id':'nixos-generation-130.conf','isDefault':True,'options':'init='+candidate+'/init'},
                      {'id':'fallback.conf','isDefault':False,'options':'init='+fallback+'/init'}]))
elif name in ('systemctl','flatpak','fwupdmgr'): pass
else: sys.exit(92)
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="baby-workflow.")
        self.root = Path(self.scratch.name)
        self.baby = self.root/"baby"
        (self.baby/"lib").mkdir(parents=True)
        for path in (ROOT/"lib").glob("*"):
            if path.is_file(): shutil.copy2(path, self.baby/"lib"/path.name)
        for name in ("update-system.sh", "rebuild-system.sh"):
            shutil.copy2(ROOT/name, self.baby/name)
        (self.baby/"check-system.sh").write_text('#!/usr/bin/env bash\nexit "${FIXTURE_HEALTH:-0}"\n')
        (self.baby/"check-system.sh").chmod(0o755)
        source = self.root/"source"; source.mkdir()
        for name, text in (("flake.nix", "{}\n"), ("configuration.nix", "{}\n"), ("flake.lock", "original fixture lock\n")):
            (source/name).write_text(text)
        for kind in ("candidate", "previous", "fallback"):
            (self.root/kind).mkdir(); (self.root/kind/"init").write_text('#!/bin/sh\nexit 0\n'); (self.root/kind/"init").chmod(0o755)
        (self.root/"active").write_text(str(self.root/"previous"))
        bins=self.root/"bin"; bins.mkdir()
        for name in ("nix", "nixos-rebuild", "sudo", "hostname", "df", "readlink", "systemctl", "bootctl", "flatpak", "fwupdmgr"):
            (bins/name).write_text(SHIM); (bins/name).chmod(0o755)
        self.env=dict(os.environ, FIXTURE_ROOT=str(self.root), REAL_READLINK=REAL_READLINK,
                      PATH=str(bins)+":"+os.environ["PATH"], BABY_STEP_DIR=str(self.baby),
                      NIXOS_DIR=str(source), NO_COLOR="1")

    def tearDown(self): self.scratch.cleanup()

    def run_script(self, name, *args, **overrides):
        return subprocess.run(["bash",str(self.baby/name),*args], env=dict(self.env, **overrides), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)

    def calls(self):
        return [json.loads(line) for line in (self.root/"calls").read_text().splitlines()]

    def assert_no_activation(self):
        self.assertEqual((self.root/"active").read_text(), str(self.root/"previous"))
        self.assertFalse(any(call[0]=="nixos-rebuild" and "switch" in call for call in self.calls()))

    def test_build_only_streams_output_and_never_activates(self):
        r=self.run_script("rebuild-system.sh", "--build-only")
        self.assertEqual(r.returncode,0,r.stdout); self.assertIn('fixture compilation progress visible',r.stdout)
        self.assert_no_activation()
        self.assertFalse(any(call[0]=='sudo' for call in self.calls()))

    def test_rebuild_previews_and_activates_exact_candidate(self):
        r=self.run_script("rebuild-system.sh")
        self.assertEqual(r.returncode,0,r.stdout)
        operations=[call for call in self.calls() if call[0]=='nixos-rebuild']
        self.assertTrue(any('dry-activate' in call for call in operations))
        self.assertTrue(any('switch' in call and '--store-path' in call and '--flake' not in call for call in operations))

    def test_missing_build_artifact_is_rejected(self):
        r=self.run_script("rebuild-system.sh", "--build-only", FIXTURE_NO_RESULT="1")
        self.assertNotEqual(r.returncode,0); self.assertIn('without a usable candidate',r.stdout); self.assert_no_activation()

    def test_source_change_blocks_activation(self):
        r=self.run_script("rebuild-system.sh", FIXTURE_SOURCE_EDIT="1")
        self.assertNotEqual(r.returncode,0); self.assertIn('Source changed',r.stdout); self.assert_no_activation()

    def test_update_failure_restores_only_own_lock_and_preserves_prior_backup(self):
        (self.baby/'backups').mkdir(); prior=self.baby/'backups/flake.lock.previous'; prior.write_text('recovery sentinel')
        r=self.run_script("update-system.sh", FIXTURE_BUILD_FAIL="1")
        self.assertNotEqual(r.returncode,0,r.stdout); self.assert_no_activation()
        self.assertEqual((self.root/'source/flake.lock').read_text(),'original fixture lock\n')
        self.assertEqual(prior.read_text(),'recovery sentinel')

    def test_update_rollback_preserves_later_lock_edit(self):
        r=self.run_script("update-system.sh", FIXTURE_BUILD_FAIL="1", FIXTURE_LOCK_EDIT="1")
        self.assertNotEqual(r.returncode,0); self.assert_no_activation()
        self.assertEqual((self.root/'source/flake.lock').read_text(),'later user lock edit\n')
        self.assertIn('preserving it',r.stdout)

    def test_successful_update_records_matching_runtime_receipt(self):
        r=self.run_script("update-system.sh")
        self.assertEqual(r.returncode,0,r.stdout)
        receipt=(self.baby/'state/update-success-receipt.txt').read_text()
        self.assertIn('generation=130\n',receipt)
        self.assertIn('active_system='+str(self.root/'candidate'),receipt)
        self.assertIn('health=passed\n',receipt)

    def test_failed_health_does_not_issue_success_receipt(self):
        r=self.run_script("update-system.sh", FIXTURE_HEALTH="2")
        self.assertNotEqual(r.returncode,0,r.stdout)
        self.assertFalse((self.baby/'state/update-success-receipt.txt').exists())
        self.assertEqual((self.root/'active').read_text(),str(self.root/'candidate'))
        self.assertNotIn('SUCCESS: Your system update completed',r.stdout)

    def test_update_check_only_never_updates_inputs_or_requests_sudo(self):
        r=self.run_script("update-system.sh", "--check-only")
        self.assertEqual(r.returncode,0,r.stdout); self.assert_no_activation()
        self.assertFalse(any(call[0]=='sudo' or (call[0]=='nix' and 'update' in call) for call in self.calls()))
        self.assertEqual((self.root/'source/flake.lock').read_text(),'original fixture lock\n')

    def test_dangling_lock_is_refused_before_input_update(self):
        lock=self.root/'source/flake.lock'; lock.unlink()
        missing=self.root/'missing-user-target'; lock.symlink_to(missing)
        r=self.run_script('update-system.sh')
        self.assertNotEqual(r.returncode,0,r.stdout)
        self.assertIn('dangling link',r.stdout); self.assert_no_activation()
        self.assertTrue(lock.is_symlink()); self.assertFalse(missing.exists())
        self.assertFalse(any(call[0]=='nix' and 'update' in call for call in self.calls()))


if __name__ == '__main__': unittest.main(verbosity=2)
