#!/usr/bin/env python3
"""Prepare, build and install this desktop from a NixOS live USB, in explicit phases.

No partitioning, formatting, reboot or live-system activation is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[1]
HOST = 'tonelico'

def run(argv, capture=False):
    print('[RUN] ' + shlex.join([str(a) for a in argv]), flush=True)
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE if capture else None, check=True)
    print('[OK] Command completed.', flush=True)
    return result.stdout.strip() if capture else None

def regular_path(path):
    """Reject links in every existing component, including dangling links."""
    p = Path(path)
    if not p.is_absolute() or '..' in p.parts:
        raise ValueError('Target must be an absolute path without parent traversal.')
    for part in [p, *p.parents]:
        if part.is_symlink(): raise ValueError(f'Linked path refused: {part}')
    return p

def mount_info(path):
    raw = run(['findmnt', '--json', '--mountpoint', str(path), '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN'], True)
    entries = json.loads(raw)['filesystems']
    if len(entries) != 1: raise ValueError('Expected exactly one mountpoint.')
    return entries[0]

def validate_target(target):
    target = regular_path(target)
    if target == Path('/') or target.parts[1:2] in [('home',),('etc',),('nix',),('boot',),('run',),('var',)]:
        raise ValueError('Protected running-system path refused.')
    root = mount_info(target)
    live = mount_info(Path('/'))
    if root['maj:min'] == live['maj:min']:
        raise ValueError('Target shares the running root filesystem.')
    if root['fstype'] not in ('ext4', 'btrfs', 'xfs') or 'rw' not in root['options'].split(','):
        raise ValueError('Target must be a writable ext4, btrfs or XFS mount.')
    boot = mount_info(regular_path(target/'boot'))
    if boot['fstype'] not in ('vfat', 'fat', 'fat32') or 'rw' not in boot['options'].split(','):
        raise ValueError('Mount a writable FAT EFI system partition at TARGET/boot.')
    if boot['maj:min'] == root['maj:min']:
        raise ValueError('EFI partition must be distinct from the root filesystem.')
    for rel in ('etc/nixos', 'etc/shadow', 'home/aesc', 'var', 'nix/var/nix/profiles', 'nix/store', 'boot/loader/entries'):
        regular_path(target/rel)
    # Protect the live machine's own ESP when running outside an installer.
    try: live_boot = mount_info(Path('/boot'))
    except subprocess.CalledProcessError: live_boot = None
    if live_boot and boot['maj:min'] == live_boot['maj:min']:
        raise ValueError('Target EFI partition is the running system ESP.')
    if not Path('/sys/firmware/efi').is_dir(): raise ValueError('Boot the live USB in UEFI mode.')
    if platform.machine() != 'x86_64': raise ValueError('This desktop snapshot is supported on x86_64 only.')
    return target, {'root': root, 'boot': boot}

def source_digest(source):
    result = hashlib.sha256()
    for p in sorted(source.rglob('*')):
        if '.git' in p.relative_to(source).parts: continue
        if p.is_symlink(): raise ValueError(f'Source symlink refused: {p}')
        if p.is_dir(): continue
        if not stat.S_ISREG(p.stat().st_mode): raise ValueError('Nonregular source input refused.')
        result.update(str(p.relative_to(source)).encode() + b'\0' + str(p.stat().st_mode & 0o111).encode() + b'\0' + hashlib.sha256(p.read_bytes()).digest())
    return result.hexdigest()

def installed_identity_matches(target, candidate):
    profile=target/'nix/var/nix/profiles/system'
    # Profiles may contain absolute store links or target-root-relative links.
    expected={str(candidate),str(target/str(candidate).lstrip('/'))}
    return profile.is_symlink() and os.path.realpath(profile) in expected

def target_payload_exists(target, candidate, name):
    """Resolve payload symlinks inside the installed root, never the live /nix."""
    store=target/'nix/store'
    p=target/str(candidate).lstrip('/')/name
    for _ in range(32):
        if not p.is_relative_to(store): return False
        # Store objects themselves must be real directories, not host-namespace links.
        regular_path(p.parent)
        if not p.is_symlink(): return p.is_file()
        link=os.readlink(p)
        p=target/link.lstrip('/') if link.startswith('/') else Path(os.path.normpath(p.parent/link))
    return False

def boot_entry_matches(target,candidate):
    entries=regular_path(target/'boot/loader/entries')
    for entry in entries.glob('*.conf'):
        regular_path(entry)
        fields={}
        for line in entry.read_text().splitlines():
            parts=line.split(None,1)
            if len(parts)==2: fields.setdefault(parts[0],[]).append(parts[1])
        if not any(f'init={candidate}/init' in shlex.split(options) for options in fields.get('options',[])): continue
        payloads=fields.get('linux',[])+fields.get('initrd',[])
        if not fields.get('linux') or not fields.get('initrd'): continue
        if all(path.startswith('/') and regular_path(target/'boot'/path.lstrip('/')).is_file() for path in payloads): return True
    return False

def receipt_path(target):
    path = regular_path(target/'var/lib/nixos-live-installer')
    if path.exists():
        info = path.stat()
        if not path.is_dir() or info.st_uid != 0 or info.st_mode & 0o077:
            raise ValueError('Installer receipt directory must be private and root-owned.')
    else: path.mkdir(parents=True, mode=0o700)
    return regular_path(path/'receipt.json')

def save_receipt(path, data):
    data['updated_at'] = datetime.now(timezone.utc).isoformat()
    fd, name = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
        dir_fd = os.open(path.parent, os.O_DIRECTORY)
        try: os.fsync(dir_fd)
        finally: os.close(dir_fd)
    finally:
        if os.path.exists(name): os.unlink(name)

def load_receipt(path, target, mounts):
    if not path.is_file() or path.stat().st_uid != 0 or path.stat().st_mode & 0o077:
        raise ValueError('A private root-owned prepare receipt is required.')
    data = json.loads(path.read_text())
    if data.get('schema') != 1 or data.get('target') != str(target) or data.get('mounts') != mounts:
        raise ValueError('Target mount identity changed; prepare again.')
    if data.get('source_sha256') != source_digest(target/'etc/nixos'):
        raise ValueError('Prepared source changed; prepare and build again.')
    return data

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('inspect','prepare','build','install','password','verify'), default='inspect')
    parser.add_argument('--target', default='/mnt')
    args=parser.parse_args(argv)
    os.environ['NIX_CONFIG'] = os.environ.get('NIX_CONFIG','') + '\nexperimental-features = nix-command flakes\n'
    print(f'\n=== LIVE USB · {args.phase.upper()} ===', flush=True)
    if args.phase == 'inspect':
        run(['lsblk','-o','NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL'])
        print('Scope: reviewed x86_64 desktop, user aesc. Mount the chosen root at /mnt and EFI partition at /mnt/boot.\nNext: --phase prepare. This command did not change disks or configuration.')
        return 0
    if os.geteuid() != 0: raise ValueError('Run the selected phase with sudo from the live USB.')
    target,mounts=validate_target(args.target)
    # Recheck mount identities before every mutating phase. No claim of race-proofness.
    receipt=receipt_path(target)
    source=target/'etc/nixos'
    if args.phase == 'prepare':
        portable=REPO/'installation'
        if not (portable/'flake.lock').is_file(): raise ValueError('Clone is missing the portable source.')
        if receipt.exists():
            previous=json.loads(receipt.read_text())
            if previous.get('installed'): raise ValueError('Already installed: use build/verify, not prepare over an installed target.')
        with tempfile.TemporaryDirectory(prefix='nixos-live-hardware.') as tmp:
            run(['nixos-generate-config','--root',str(target),'--dir',tmp])
            run(['bash',str(REPO/'scripts/bootstrap-nixos.sh'),'--source',str(portable),
                 '--host',HOST,'--hardware',str(Path(tmp)/'hardware-configuration.nix'),
                 '--target-root',str(target),'--yes'])
        save_receipt(receipt, {'schema':1,'target':str(target),'mounts':mounts,'host':HOST,
                              'source_sha256':source_digest(source),'prepared':True,
                              'built':False,'installed':False,'account_state':'PENDING_CREDENTIAL_INITIALIZATION'})
        print('[VERIFIED] Prepared source, fresh hardware, selected dotfiles, scripts and wallpapers. Nothing activated.')
    else:
        data=load_receipt(receipt,target,mounts)
        if args.phase == 'build':
            # Match nixos-install's local target-store strategy; the live ISO's
            # writable /nix/store is RAM-backed and cannot hold this desktop.
            scratch=regular_path(target/'var/lib/nixos-live-installer/build-tmp')
            scratch.mkdir(exist_ok=True,mode=0o700)
            previous_tmp=os.environ.get('TMPDIR');os.environ['TMPDIR']=str(scratch)
            try:
                output=run(['nix','--extra-experimental-features','nix-command flakes','build','--no-link',
                            '--store',str(target),'--extra-substituters','auto?trusted=1',
                            '--print-out-paths','--no-write-lock-file',
                            f'path:{source}#nixosConfigurations.{HOST}.config.system.build.toplevel'],True)
            finally:
                if previous_tmp is None:os.environ.pop('TMPDIR',None)
                else:os.environ['TMPDIR']=previous_tmp
            candidate=Path(output)
            if candidate.parent!=Path('/nix/store') or not target_payload_exists(target,candidate,'bin/switch-to-configuration'):
                raise ValueError('Build did not return one valid NixOS toplevel.')
            data.update(built=True,candidate=str(candidate));save_receipt(receipt,data)
            print(f'[VERIFIED] Built candidate: {candidate}. No activation.')
        elif args.phase == 'install':
            if not data.get('built'): raise ValueError('Run build before install.')
            candidate=Path(data['candidate'])
            for name in ('kernel','initrd','init','bin/switch-to-configuration'):
                if not target_payload_exists(target,candidate,name): raise ValueError(f'Missing target candidate payload: {name}')
            # Confirm source still evaluates to the exact closure being installed.
            expected=run(['nix','--extra-experimental-features','nix-command flakes','eval','--raw',
                          '--no-write-lock-file',f'path:{source}#nixosConfigurations.{HOST}.config.system.build.toplevel'],True)
            if expected != str(candidate): raise ValueError('Build identity drift; build again.')
            validate_target(str(target))
            run(['nixos-install','--root',str(target),'--system',str(candidate),'--no-root-passwd','--no-channel-copy'])
            if not installed_identity_matches(target,candidate) or not all(target_payload_exists(target,candidate,name) for name in ('kernel','initrd','init','bin/switch-to-configuration')):
                raise ValueError('Installed system profile does not match built closure.')
            data['installed']=True;save_receipt(receipt,data)
            print('[VERIFIED] Installation profile matches candidate. Set the aesc password next; no credentials were copied.')
        elif args.phase == 'password':
            if not data.get('installed'): raise ValueError('Install before initializing the login password.')
            if not sys.stdin.isatty(): raise ValueError('Password needs a terminal; no password was invented or logged.')
            run(['nixos-enter','--root',str(target),'-c','passwd aesc'])
            data['account_state']='INITIALIZED';save_receipt(receipt,data)
            print('[OK] Password command completed; verify checks the resulting account hash without displaying it.')
        else:
            if not data.get('installed'): raise ValueError('Installation is not recorded as completed.')
            if not installed_identity_matches(target,data['candidate']):
                raise ValueError('Installed profile changed.')
            if not all(target_payload_exists(target,data['candidate'],name) for name in ('kernel','initrd','init','bin/switch-to-configuration')):
                raise ValueError('Copied target candidate payload is incomplete.')
            shadow=regular_path(target/'etc/shadow'); password_ok=False
            if shadow.is_file():
                for row in shadow.read_text().splitlines():
                    fields=row.split(':')
                    if fields[0]=='aesc' and len(fields)>1:
                        password_ok=bool(fields[1]) and not fields[1].startswith(('!','*'))
            if not boot_entry_matches(target,data['candidate']): raise ValueError('No matching bootloader entry with existing ESP payloads.')
            if not regular_path(target/'boot/EFI/BOOT/BOOTX64.EFI').is_file():
                raise ValueError('Standalone UEFI boot payload is missing from the installed disk.')
            if not password_ok: raise ValueError('aesc login password is not initialized: run --phase password.')
            data['account_state']='VERIFIED_INITIALIZED';data['verified']=True;save_receipt(receipt,data)
            print('[VERIFIED] Source, installed profile, account password and boot entries. Cold boot and desktop acceptance remain untested. No reboot performed.')
    print(f'[RECEIPT] {receipt}')
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError,json.JSONDecodeError) as exc:
        print(f'[FAILED] {exc}\nExisting backups and previous phases are preserved; no reboot performed.', file=sys.stderr)
        raise SystemExit(1)
