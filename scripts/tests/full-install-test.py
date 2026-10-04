#!/usr/bin/env python3
"""Full-entry safety/ordering fixtures; never format or mount a real device."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('full',Path(__file__).resolve().parents[1]/'install-everything.py')
full=importlib.util.module_from_spec(spec);spec.loader.exec_module(full)

def disk(**changes):
    data={'path':'/dev/testdisk','type':'disk','size':128*1024**3,'ro':False,'rm':False,
          'tran':'nvme','model':'test-model','serial':'test-serial','wwn':'test-wwn',
          'maj:min':'259:1','mountpoints':[None],'children':[]}
    data.update(changes);return data

class TTY(io.StringIO):
    def __init__(self,answers):super().__init__();self.answers=iter(answers)
    def readline(self):return next(self.answers)+'\n'
    def __exit__(self,*args):pass

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='full-install-test.')
        self.target=Path(self.temp.name)/'mnt'
        self.expected={'path':'/dev/testdisk','rdev':1}
    def tearDown(self):self.temp.cleanup()
    def test_plan_has_no_commands_or_writes(self):
        with patch.object(full,'run') as run,patch.object(full,'require_live_usb') as live,patch.object(full.tempfile,'mkdtemp') as temp,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(full.main(['--plan']),0)
            self.assertEqual(json.loads(out.getvalue())['mode'],'PLAN_ONLY')
            run.assert_not_called();live.assert_not_called();temp.assert_not_called()
    def test_installed_os_refused_before_disk_commands(self):
        with patch.object(Path,'read_text',return_value='ID=nixos\nVARIANT_ID=""\n'),patch.object(full,'run') as run:
            with self.assertRaisesRegex(ValueError,'live installer'):full.require_live_usb()
            run.assert_not_called()
    def test_live_iso_guard_requires_uefi_and_media(self):
        release='ID=nixos\nVARIANT_ID="installer"\n'
        with patch.object(Path,'read_text',return_value=release),patch.object(full.platform,'machine',return_value='x86_64'),patch.object(Path,'is_dir',return_value=False):
            with self.assertRaisesRegex(ValueError,'UEFI'):full.require_live_usb()
        with patch.object(Path,'read_text',return_value=release),patch.object(full.platform,'machine',return_value='x86_64'),patch.object(Path,'is_dir',return_value=True),patch.object(full,'run',return_value=json.dumps({'filesystems':[{'fstype':'ext4'}]})):
            with self.assertRaisesRegex(ValueError,'medium'):full.require_live_usb()
    def test_live_iso_guard_accepts_nested_squashfs(self):
        with patch.object(Path,'read_text',return_value='ID=nixos\nVARIANT_ID=installer\n'),patch.object(full.platform,'machine',return_value='x86_64'),patch.object(Path,'is_dir',return_value=True),patch.object(full.os,'geteuid',return_value=0),patch.object(full,'run',return_value=json.dumps({'filesystems':[{'fstype':'overlay','children':[{'fstype':'squashfs'}]}]})):
            full.require_live_usb()
    def test_ineligible_devices_excluded(self):
        with patch.object(Path,'read_text',return_value='Filename Type Size Used Priority\n'),patch.object(Path,'is_dir',return_value=False):
            self.assertIsNone(full.busy_reason(disk()))
            for changes in ({'ro':True},{'rm':True},{'tran':'usb'},{'size':1024},{'type':'part'},
                            {'mountpoints':['/']},{'children':[{'path':'/dev/testdisk1','mountpoints':['/mnt']}]}):
                with self.subTest(changes=changes):self.assertIsNotNone(full.busy_reason(disk(**changes)))
    def test_disk_inventory_explicitly_requests_children(self):
        with patch.object(full,'run',return_value='{"blockdevices": []}') as run:
            self.assertEqual(full.disk_inventory(),[])
            self.assertIn('--tree',run.call_args.args[0])
    def test_swap_and_holders_excluded(self):
        with patch.object(Path,'read_text',return_value='Filename Type Size Used Priority\n/dev/testdisk partition 1 0 -2\n'):
            self.assertEqual(full.busy_reason(disk()),'active swap')
        with patch.object(Path,'read_text',return_value='Filename Type Size Used Priority\n'),patch.object(Path,'is_dir',return_value=True),patch.object(Path,'iterdir',return_value=iter([Path('held')])):
            self.assertIn('holder',full.busy_reason(disk()))
    def selection(self,answers):
        return patch.multiple(full,disk_inventory=lambda:[disk()],busy_reason=lambda d:None,
                              identity=lambda d:copy.copy(self.expected),revalidate_disk=lambda d:disk())
    def test_explicit_erasure_required(self):
        for answers in ([''],['1','yes'],['1','ERASE /dev/otherdisk']):
            with self.selection(answers),patch('builtins.open',return_value=TTY(answers)),contextlib.redirect_stdout(io.StringIO()),self.assertRaises(ValueError):full.select_disk()
    def test_identity_frozen_before_erasure_prompt(self):
        events=[]
        class RecordingTTY(TTY):
            def readline(self):events.append('answer');return super().readline()
        with patch.object(full,'disk_inventory',return_value=[disk()]),patch.object(full,'busy_reason',return_value=None),patch.object(full,'identity',side_effect=lambda d:events.append('identity') or self.expected),patch.object(full,'revalidate_disk') as validate,patch('builtins.open',return_value=RecordingTTY(['1','ERASE /dev/testdisk'])),contextlib.redirect_stdout(io.StringIO()):
            full.select_disk()
            self.assertEqual(events,['answer','identity','answer']);validate.assert_called_once_with(self.expected)
    def test_disk_identity_drift_and_busy_fail(self):
        with patch.object(full,'disk_inventory',return_value=[disk()]),patch.object(full,'identity',return_value={'path':'/dev/testdisk','rdev':2}):
            with self.assertRaisesRegex(ValueError,'identity'):full.revalidate_disk(self.expected)
        with patch.object(full,'disk_inventory',return_value=[disk()]),patch.object(full,'identity',return_value=self.expected),patch.object(full,'busy_reason',return_value='mounted'):
            with self.assertRaisesRegex(ValueError,'busy'):full.revalidate_disk(self.expected)
    def test_symlink_and_nonblock_partition_rejected(self):
        with patch.object(full,'revalidate_disk'),patch.object(full,'find_partition',return_value='/dev/testpart'),patch.object(full.os,'lstat',return_value=SimpleNamespace(st_mode=stat.S_IFLNK,st_rdev=2)):
            with self.assertRaisesRegex(ValueError,'block device'):full.partition_identity(self.expected,1,'/dev/testpart')
    def test_partition_path_and_rdev_drift_block_format(self):
        with patch.object(full,'revalidate_disk'),patch.object(full,'find_partition',return_value='/dev/otherpart'):
            with self.assertRaisesRegex(ValueError,'path changed'):full.partition_identity(self.expected,1,'/dev/testpart')
        with patch.object(full,'partition_identity',return_value=9),patch.object(full,'run') as run:
            with self.assertRaisesRegex(ValueError,'identity changed'):full.format_partition(self.expected,1,'/dev/testpart',8,['mkfs.fat'])
            run.assert_not_called()
    def test_partition_lookup_rejects_wrong_parent(self):
        rows={'blockdevices':[{'type':'part','partn':1,'pkname':'/dev/other','path':'/dev/other1'}]}
        with patch.object(full,'run',return_value=json.dumps(rows)),patch.object(full.time,'monotonic',side_effect=[0,0,21]),patch.object(full.time,'sleep'):
            with self.assertRaisesRegex(ValueError,'not become'):full.find_partition('/dev/testdisk',1)
    def test_partition_lookup_accepts_exact_parent(self):
        rows={'blockdevices':[{'type':'part','partn':1,'pkname':'/dev/testdisk','path':'/dev/testdisk1'}]}
        with patch.object(full,'run',return_value=json.dumps(rows)):
            self.assertEqual(full.find_partition('/dev/testdisk',1),'/dev/testdisk1')
    def test_partition_sequence_and_command_failures(self):
        for failed in (None,'parted','udevadm','mkfs.fat','mkfs.ext4'):
            calls=[]
            def command(argv,capture=False):
                calls.append(argv)
                if argv[0]==failed:raise subprocess.CalledProcessError(7,argv)
            with patch.object(full,'revalidate_disk'),patch.object(full,'find_partition',side_effect=lambda d,n:f'/dev/testdisk{n}'),patch.object(full,'partition_identity',side_effect=lambda e,n,p:n),patch.object(full,'run',side_effect=command):
                if failed:
                    with self.assertRaises(subprocess.CalledProcessError):full.partition_disk(self.expected)
                    self.assertEqual(calls[-1][0],failed)
                else:
                    self.assertEqual(full.partition_disk(self.expected),('/dev/testdisk2','/dev/testdisk1',{'root':2,'esp':1}))
                    self.assertEqual([c[0] for c in calls],['parted','udevadm','mkfs.fat','mkfs.ext4'])
                    self.assertIn('1MiB',calls[0]);self.assertIn('1025MiB',calls[0]);self.assertIn('100%',calls[0])
                    self.assertLessEqual(len(calls[2][calls[2].index('-n')+1]),11)
    def test_target_nonempty_or_linked_preserved(self):
        self.target.mkdir();(self.target/'keep').write_text('user data')
        with patch.object(full,'TARGET',self.target),self.assertRaises(ValueError):full.validate_empty_target_mountpoint()
        self.assertEqual((self.target/'keep').read_text(),'user data')
        link=Path(self.temp.name)/'link';link.symlink_to(self.target)
        with patch.object(full,'TARGET',link),self.assertRaises(ValueError):full.validate_empty_target_mountpoint()
    def test_pinned_revision_required_before_git_commands(self):
        with patch.object(full,'run') as run,self.assertRaisesRegex(ValueError,'exact source revision'):
            full.checkout_revision('main',Path(self.temp.name))
        run.assert_not_called()
    def test_mount_identity_checked_and_descriptor_retained(self):
        # The whole-disk fd must stay held until both mounts have been observed.
        events=[]
        def format_(expected):events.append('format');return 'root','esp',{'root':2,'esp':1}
        def mount_(*args):events.append('mount')
        with patch.object(full,'require_live_usb'),patch.object(full.sys.stdin,'isatty',return_value=True),patch.object(full.tempfile,'mkdtemp',return_value=self.temp.name),patch.object(full,'checkout_revision',return_value=Path(self.temp.name)),patch.object(full,'validate_empty_target_mountpoint'),patch.object(full,'select_disk',return_value=(disk(),self.expected)),patch.object(full,'acquire_disk',return_value=99),patch.object(full,'partition_disk',side_effect=format_),patch.object(full,'mount_target',side_effect=mount_),patch.object(full.os,'close',side_effect=lambda fd:events.append('close')),patch.object(full,'install_all'),patch.object(full,'run'),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(full.main(['--revision','a'*40]),0)
        self.assertEqual(events,['format','mount','close'])
    def test_mount_verification_rejects_other_device(self):
        with patch.object(full,'run',return_value=json.dumps({'filesystems':[{'maj:min':'8:2'}]})),self.assertRaisesRegex(ValueError,'identity differs'):
            full.verify_mount(self.target,os.makedev(8,1))
    def test_mount_sequence_preserves_failure_and_checks_identities(self):
        self.target.mkdir()
        calls=[]
        with patch.object(full,'TARGET',self.target),patch.object(full.subprocess,'run',return_value=SimpleNamespace(returncode=1)),patch.object(full,'partition_identity',side_effect=[2,1]) as identity,patch.object(full,'run',side_effect=lambda a,capture=False:calls.append(a)),patch.object(full,'verify_mount') as verify:
            full.mount_target('/dev/root','/dev/esp',self.expected,{'root':2,'esp':1})
            self.assertEqual(calls,[['mount','/dev/root',str(self.target)],['mount','/dev/esp',str(self.target/'boot')]])
            self.assertEqual(verify.call_count,2)
            self.assertEqual(identity.call_args_list[1].args[-1],(str(self.target),))
    def test_changed_root_refused_before_mount(self):
        self.target.mkdir()
        with patch.object(full,'TARGET',self.target),patch.object(full.subprocess,'run',return_value=SimpleNamespace(returncode=1)),patch.object(full,'partition_identity',return_value=9),patch.object(full,'run') as run:
            with self.assertRaisesRegex(ValueError,'Root partition'):full.mount_target('/dev/root','/dev/esp',self.expected,{'root':2,'esp':1})
            run.assert_not_called()
    def test_all_phases_in_order_and_stop_on_error(self):
        for fail in (None,'prepare','build','install','password','verify'):
            calls=[]
            def command(argv,capture=False):
                phase=argv[argv.index('--phase')+1];calls.append(phase)
                if phase==fail:raise subprocess.CalledProcessError(7,argv)
            with patch.object(full,'run',side_effect=command),contextlib.redirect_stdout(io.StringIO()):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):full.install_all(Path(self.temp.name))
                    self.assertEqual(calls[-1],fail)
                else:
                    full.install_all(Path(self.temp.name));self.assertEqual(calls,['prepare','build','install','password','verify'])
    def test_reuse_mounted_never_formats(self):
        with patch.object(full,'require_live_usb'),patch.object(full.sys.stdin,'isatty',return_value=True),patch.object(full.tempfile,'mkdtemp',return_value=self.temp.name),patch.object(full,'checkout_revision',return_value=Path(self.temp.name)),patch.object(full,'select_disk') as select,patch.object(full,'partition_disk') as format_,patch.object(full,'mount_target') as mount,patch.object(full,'install_all') as install,patch.object(full,'run'),contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(full.main(['--revision','a'*40,'--reuse-mounted']),0)
            select.assert_not_called();format_.assert_not_called();mount.assert_not_called();install.assert_called_once()
            self.assertIn('[COMPLETE]',out.getvalue())
    def test_failed_install_never_claims_completion(self):
        with patch.object(full,'require_live_usb'),patch.object(full.sys.stdin,'isatty',return_value=True),patch.object(full.tempfile,'mkdtemp',return_value=self.temp.name),patch.object(full,'checkout_revision',return_value=Path(self.temp.name)),patch.object(full,'install_all',side_effect=ValueError('verify failed')),contextlib.redirect_stdout(io.StringIO()) as out:
            with self.assertRaises(ValueError):full.main(['--revision','a'*40,'--reuse-mounted'])
            self.assertNotIn('[COMPLETE]',out.getvalue())

if __name__=='__main__':unittest.main()
