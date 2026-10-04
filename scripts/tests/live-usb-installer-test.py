#!/usr/bin/env python3
"""Adversarial installer phase tests; no real mount, install or password changes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import os
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('installer',Path(__file__).resolve().parents[1]/'install-from-live-usb.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.scratch=tempfile.TemporaryDirectory(prefix='live-usb-test.')
        self.target=Path(self.scratch.name)/'target';self.target.mkdir()
        self.source=self.target/'etc/nixos';self.source.mkdir(parents=True)
        (self.source/'flake.nix').write_text('{}\n')
    def tearDown(self):self.scratch.cleanup()
    def test_running_paths_rejected_without_commands(self):
        with patch.object(installer,'run') as run:
            for name in ('/','/home/aesc','/etc/nixos','/boot','/nix/var','/var/tmp','/run/target'):
                with self.subTest(name=name),self.assertRaises(ValueError):installer.validate_target(name)
            run.assert_not_called()
    def test_linked_parent_rejected(self):
        link=Path(self.scratch.name)/'link';link.symlink_to(self.target)
        with self.assertRaises(ValueError):installer.regular_path(link/'child')
    def test_same_filesystem_rejected(self):
        mount={'maj:min':'1:1','fstype':'ext4','options':'rw'}
        with patch.object(installer,'mount_info',return_value=mount),self.assertRaisesRegex(ValueError,'running root'):
            installer.validate_target(str(self.target))
    def test_source_link_refused(self):
        (self.source/'hidden.nix').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):installer.source_digest(self.source)
    def test_nested_target_escape_rejected(self):
        mounts={str(self.target):{'maj:min':'2:2','fstype':'ext4','options':'rw'},
                '/':{'maj:min':'1:1','fstype':'ext4','options':'rw'},
                str(self.target/'boot'):{'maj:min':'3:3','fstype':'vfat','options':'rw'}}
        held=self.target/'held-etc';(self.target/'etc').rename(held)
        (self.target/'etc').symlink_to(held)
        with patch.object(installer,'mount_info',side_effect=lambda p:mounts[str(p)]),self.assertRaisesRegex(ValueError,'Linked path'):
            installer.validate_target(str(self.target))
    def test_inspect_is_read_only(self):
        with patch.object(installer,'run') as run,patch.object(installer,'validate_target') as validate,contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(installer.main(['--phase','inspect']),0)
            validate.assert_not_called()
            self.assertEqual(run.call_args.args[0][0],'lsblk')
    def test_build_requires_prepare(self):
        with patch.object(installer,'validate_target',return_value=(self.target,{})),patch.object(installer,'os') as os_mock,patch.object(installer,'run') as run:
            os_mock.geteuid.return_value=0
            with self.assertRaises(ValueError):installer.main(['--phase','build','--target',str(self.target)])
            run.assert_not_called()
    def test_receipt_drift_rejected(self):
        # Exercise real receipt writes under our owned fixture, patch only uid check.
        path=self.target/'receipt.json';mounts={'root':{'maj:min':'2:2'}}
        data={'schema':1,'target':str(self.target),'mounts':mounts,'source_sha256':installer.source_digest(self.source)}
        installer.save_receipt(path,data)
        self.assertEqual(json.loads(path.read_text())['schema'],1)
        # Root-owned receipt requirement itself is enforced on an ordinary user's fixture.
        if path.stat().st_uid != 0:
            with self.assertRaisesRegex(ValueError,'root-owned'):installer.load_receipt(path,self.target,mounts)
        class RootReceipt:
            def is_file(self):return path.is_file()
            def stat(self):
                from types import SimpleNamespace
                return SimpleNamespace(st_uid=0,st_mode=0o600)
            def read_text(self):return path.read_text()
        proxy=RootReceipt()
        installer.load_receipt(proxy,self.target,mounts)
        (self.source/'flake.nix').write_text('{ changed=true; }\n')
        with self.assertRaisesRegex(ValueError,'source changed'):installer.load_receipt(proxy,self.target,mounts)
        with self.assertRaisesRegex(ValueError,'mount identity'):installer.load_receipt(proxy,self.target,{'different':'mount'})
    def test_non_root_prepare_refused(self):
        with patch.object(installer.os,'geteuid',return_value=1000),patch.object(installer,'run') as run:
            with self.assertRaises(ValueError):installer.main(['--phase','prepare'])
            run.assert_not_called()
    def installed_fixture(self):
        candidate=Path('/run/current-system').resolve()
        if not str(candidate).startswith('/nix/store/'):
            self.skipTest('NixOS system required for a real live candidate reference.')
        local=self.target/str(candidate).lstrip('/')
        (local/'bin').mkdir(parents=True)
        for name in ('kernel','initrd','init','bin/switch-to-configuration'):
            (local/name).write_text('owned fixture payload\n')
        profile=self.target/'nix/var/nix/profiles/system';profile.parent.mkdir(parents=True)
        profile.symlink_to(candidate)
        loader=self.target/'boot/loader/entries';loader.mkdir(parents=True)
        (self.target/'boot/kernel').write_text('fixture kernel')
        (self.target/'boot/initrd').write_text('fixture initrd')
        fallback=self.target/'boot/EFI/BOOT/BOOTX64.EFI';fallback.parent.mkdir(parents=True)
        fallback.write_text('owned UEFI loader fixture')
        (loader/'nixos.conf').write_text(f'linux /kernel\ninitrd /initrd\noptions init={candidate}/init\n')
        (self.target/'etc/shadow').write_text('aesc:fixture-hash:1:0:99999:7:::\n')
        data={'schema':1,'target':str(self.target),'mounts':{},'host':'tonelico',
              'source_sha256':installer.source_digest(self.source),'prepared':True,'built':True,
              'installed':True,'candidate':str(candidate),'account_state':'PENDING_CREDENTIAL_INITIALIZATION'}
        return candidate,local,profile,data
    def phase(self,phase,data,run=None,tty=False):
        with patch.object(installer.os,'geteuid',return_value=0),patch.object(installer,'validate_target',return_value=(self.target,{})),\
             patch.object(installer,'receipt_path',return_value=self.target/'receipt.json'),\
             patch.object(installer,'load_receipt',return_value=dict(data)),\
             patch.object(installer,'run',side_effect=run),patch.object(installer.sys.stdin,'isatty',return_value=tty),\
             contextlib.redirect_stdout(io.StringIO()):
            return installer.main(['--phase',phase,'--target',str(self.target)])
    def test_exact_profile_and_target_payload(self):
        candidate,local,profile,data=self.installed_fixture()
        self.assertTrue(installer.installed_identity_matches(self.target,candidate))
        profile.unlink();profile.symlink_to(str(candidate)+'-stale')
        self.assertFalse(installer.installed_identity_matches(self.target,candidate))
        profile.unlink();profile.symlink_to(candidate)
        (local/'kernel').unlink()
        self.assertFalse(installer.target_payload_exists(self.target,candidate,'kernel'))
        with self.assertRaisesRegex(ValueError,'incomplete'):self.phase('verify',data)
    def test_payload_links_use_target_namespace(self):
        candidate,local,profile,data=self.installed_fixture()
        (local/'kernel').unlink();(local/'kernel').symlink_to(candidate/'kernel')
        # The live payload exists, but the corresponding target namespace link loops.
        self.assertFalse(installer.target_payload_exists(self.target,candidate,'kernel'))
    def test_verify_requires_matching_boot_and_initialized_account(self):
        candidate,local,profile,data=self.installed_fixture()
        entry=self.target/'boot/loader/entries/nixos.conf';original=entry.read_text()
        entry.write_text(original.replace(str(candidate),str(candidate)+'-stale'))
        with self.assertRaisesRegex(ValueError,'bootloader'):self.phase('verify',data)
        entry.write_text(original);(self.target/'etc/shadow').write_text('aesc:!:1:0:99999:7:::\n')
        with self.assertRaisesRegex(ValueError,'not initialized'):self.phase('verify',data)
    def test_linked_shadow_is_refused(self):
        candidate,local,profile,data=self.installed_fixture()
        shadow=self.target/'etc/shadow';shadow.unlink();shadow.symlink_to('/etc/shadow')
        with self.assertRaisesRegex(ValueError,'Linked path'):self.phase('verify',data)
    def test_password_non_tty_and_failure_preserve_pending(self):
        candidate,local,profile,data=self.installed_fixture()
        with self.assertRaisesRegex(ValueError,'terminal'):self.phase('password',data)
        def fail(argv,capture=False):raise subprocess.CalledProcessError(7,argv)
        with self.assertRaises(subprocess.CalledProcessError):self.phase('password',data,fail,True)
        self.assertFalse((self.target/'receipt.json').exists())
    def test_install_password_and_verify_owned_fixture(self):
        candidate,local,profile,data=self.installed_fixture();calls=[]
        def safe(argv,capture=False):
            calls.append(argv)
            return str(candidate) if capture else None
        self.assertEqual(self.phase('install',data,safe),0)
        self.assertTrue(any(c[0]=='nixos-install' and '--system' in c for c in calls))
        self.assertTrue(json.loads((self.target/'receipt.json').read_text())['installed'])
        self.assertEqual(self.phase('password',data,safe,True),0)
        self.assertEqual(self.phase('verify',data,safe),0)
        self.assertTrue(json.loads((self.target/'receipt.json').read_text())['verified'])

    def test_target_store_build_does_not_require_live_payload(self):
        candidate,local,profile,data=self.installed_fixture();calls=[]
        candidate=Path('/nix/store/0123456789abcdfghijklmnpqrsvwxyz-owned-system')
        payload=self.target/str(candidate).lstrip('/')/'bin/switch-to-configuration'
        payload.parent.mkdir(parents=True);payload.write_text('target-only fixture')
        scratch=self.target/'var/lib/nixos-live-installer';scratch.mkdir(parents=True)
        def safe(argv,capture=False):
            calls.append(argv)
            return str(candidate) if capture else None
        self.assertFalse((candidate/'bin/switch-to-configuration').exists())
        self.assertEqual(self.phase('build',data,safe),0)
        call=calls[0]
        self.assertEqual(call[call.index('--store')+1],str(self.target))
        self.assertIn('auto?trusted=1',call)
        self.assertEqual(json.loads((self.target/'receipt.json').read_text())['candidate'],str(candidate))

    def test_verify_requires_standalone_efi_loader(self):
        candidate,local,profile,data=self.installed_fixture()
        (self.target/'boot/EFI/BOOT/BOOTX64.EFI').unlink()
        with self.assertRaisesRegex(ValueError,'Standalone UEFI'):self.phase('verify',data)

if __name__=='__main__':unittest.main()
