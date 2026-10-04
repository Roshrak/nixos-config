#!/usr/bin/env python3
"""One live-USB command: choose disk, prepare it, restore, build and install."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile
import time
import shlex

URL = 'https://github.com/Roshrak/nixos-config.git'
MIN_DISK = 80 * 1024**3
TARGET = Path('/mnt')

def run(argv, capture=False):
    print('[RUN] ' + shlex.join(str(a) for a in argv), flush=True)
    result = subprocess.run(argv, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    print('[OK] Command completed.', flush=True)
    return result.stdout.strip() if capture else None

def flatten(nodes):
    for node in nodes:
        yield node
        yield from flatten(node.get('children',[]))

def require_live_usb():
    fields={}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key,value=line.split('=',1);fields[key]=value.strip('"')
    if fields.get('ID')!='nixos' or fields.get('VARIANT_ID')!='installer':
        raise ValueError('Run this from the NixOS live installer USB, not an installed system.')
    if platform.machine()!='x86_64' or not Path('/sys/firmware/efi').is_dir():
        raise ValueError('Boot the x86_64 NixOS USB in UEFI mode.')
    mounts=json.loads(run(['findmnt','--json','--output','TARGET,FSTYPE'],True))
    if not any(row.get('fstype') in ('squashfs','iso9660') for row in flatten(mounts['filesystems'])):
        raise ValueError('No live installation medium filesystem detected.')
    if os.geteuid()!=0: raise ValueError('The installer must be run as root through the launcher.')

def disk_inventory():
    # PATH without NAME suppresses lsblk's tree unless --tree is explicit.
    # Retain partition/mapper children so a mounted child excludes its disk.
    return json.loads(run(['lsblk','--tree','--json','--bytes','--paths','--output',
        'PATH,TYPE,SIZE,MODEL,SERIAL,WWN,RO,RM,TRAN,MAJ:MIN,MOUNTPOINTS'],True))['blockdevices']

def busy_reason(disk,allowed_mounts=()):
    if disk.get('type')!='disk':return 'not a whole disk'
    if disk.get('ro') or disk.get('rm') or disk.get('tran')=='usb':return 'read-only, removable or USB device'
    if int(disk.get('size',0))<MIN_DISK:return 'less than 80 GiB'
    active_swap=set()
    for line in Path('/proc/swaps').read_text().splitlines()[1:]:
        active_swap.add(os.path.realpath(line.split()[0]))
    for child in flatten([disk]):
        if any(point and point not in allowed_mounts for point in child.get('mountpoints',[])):
            return 'disk or partition is mounted'
        if os.path.realpath(child['path']) in active_swap:return 'active swap'
        holders=Path('/sys/class/block')/Path(child['path']).name/'holders'
        if holders.is_dir() and any(holders.iterdir()):return 'active device-mapper/RAID holder'
    return None

def identity(disk):
    info=os.stat(disk['path'])
    if not stat.S_ISBLK(info.st_mode):raise ValueError('Selected target is not a block device.')
    return {key:disk.get(key) for key in ('path','maj:min','size','serial','wwn','model')} | {'rdev':info.st_rdev}

def select_disk():
    choices=[]
    for disk in disk_inventory():
        reason=busy_reason(disk)
        if disk.get('type')!='disk':continue
        summary=f"{disk['path']} · {int(disk['size'])/1024**3:.1f} GiB · {disk.get('model') or 'unknown model'} · serial {disk.get('serial') or 'unavailable'}"
        if reason:print(f'[EXCLUDED] {summary}: {reason}')
        else:
            choices.append(disk);print(f'[{len(choices)}] {summary}')
    if not choices:raise ValueError('No eligible unmounted internal disk. Existing mounted disks and the USB are preserved.')
    with open('/dev/tty','r+') as tty:
        tty.write('\nInstall to disk number: ');tty.flush();answer=tty.readline().strip()
        if not answer.isdecimal() or not 1<=int(answer)<=len(choices):raise ValueError('No disk selected; nothing erased.')
        disk=choices[int(answer)-1];expected=identity(disk);token=f"ERASE {disk['path']}"
        tty.write(f'\nThis replaces ALL partitions/data on {disk["path"]} with NixOS.\nType {token} to select that disk for erasure: ');tty.flush()
        if tty.readline().strip()!=token:raise ValueError('Erasure not confirmed; nothing erased.')
    revalidate_disk(expected)
    return disk,expected

def revalidate_disk(expected,allowed_mounts=()):
    found=[d for d in disk_inventory() if d.get('path')==expected['path']]
    if len(found)!=1 or identity(found[0])!=expected:raise ValueError('Disk identity changed; stopping.')
    reason=busy_reason(found[0],allowed_mounts) if allowed_mounts else busy_reason(found[0])
    if reason:raise ValueError(f'Disk became busy: {reason}; stopping.')
    return found[0]

def acquire_disk(expected):
    """Hold the whole-disk descriptor and a cooperative lock through partitioning."""
    import fcntl
    flags=os.O_RDWR|os.O_NOFOLLOW
    fd=os.open(expected['path'],flags)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        info=os.fstat(fd)
        if not stat.S_ISBLK(info.st_mode) or info.st_rdev!=expected['rdev']:
            raise ValueError('Opened disk no longer matches the selected block device.')
        revalidate_disk(expected)
        return fd
    except BaseException:
        os.close(fd);raise

def find_partition(disk, number):
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        rows=json.loads(run(['lsblk','--json','--paths','--output','PATH,TYPE,PARTN,PKNAME',disk],True))['blockdevices']
        matches=[row for row in flatten(rows) if row.get('type')=='part'
                 and str(row.get('partn'))==str(number) and row.get('pkname')==disk]
        if len(matches)>1:raise ValueError('Ambiguous partition identity.')
        if matches:return matches[0]['path']
        time.sleep(0.25)
    raise ValueError(f'Partition {number} did not become available on {disk}.')

def partition_identity(expected, number, path,allowed_mounts=()):
    revalidate_disk(expected,allowed_mounts) if allowed_mounts else revalidate_disk(expected)
    if find_partition(expected['path'],number)!=path:
        raise ValueError('Partition path changed; refusing filesystem write.')
    info=os.lstat(path)
    if not stat.S_ISBLK(info.st_mode):raise ValueError('Partition must be a real block device, not a symlink.')
    return info.st_rdev

def format_partition(expected,number,path,rdev,argv):
    if partition_identity(expected,number,path)!=rdev:
        raise ValueError('Partition identity changed; refusing filesystem write.')
    run(argv)

def partition_disk(expected):
    revalidate_disk(expected)
    disk=expected['path']
    run(['parted','--script','--align','optimal',disk,'mklabel','gpt',
         'mkpart','ESP','fat32','1MiB','1025MiB','set','1','esp','on',
         'mkpart','NixOS','ext4','1025MiB','100%'])
    run(['udevadm','settle'])
    esp=find_partition(disk,1);root=find_partition(disk,2)
    # Revalidate the whole disk and its children before each filesystem write.
    esp_id=partition_identity(expected,1,esp);root_id=partition_identity(expected,2,root)
    format_partition(expected,1,esp,esp_id,['mkfs.fat','-F','32','-n','TONELICOEFI',esp])
    # -F handles stale signatures ONLY on the newly created, acknowledged partition.
    format_partition(expected,2,root,root_id,['mkfs.ext4','-F','-L','TONELICO_ROOT',root])
    return root,esp,{'root':root_id,'esp':esp_id}

def verify_mount(path,rdev):
    mounts=json.loads(run(['findmnt','--json','--mountpoint',str(path),'--output','MAJ:MIN'],True))['filesystems']
    expected=f'{os.major(rdev)}:{os.minor(rdev)}'
    if len(mounts)!=1 or mounts[0].get('maj:min')!=expected:
        raise ValueError(f'Mounted device identity differs at {path}; stopping.')

def mount_target(root,esp,expected,ids):
    if TARGET.is_symlink():raise ValueError('Linked /mnt refused.')
    current=subprocess.run(['findmnt','--mountpoint',str(TARGET)],stdout=subprocess.DEVNULL)
    if current.returncode==0:raise ValueError('/mnt is already mounted; use --reuse-mounted to preserve it.')
    if TARGET.exists() and any(TARGET.iterdir()):raise ValueError('/mnt is not empty; preserved.')
    TARGET.mkdir(exist_ok=True)
    if partition_identity(expected,2,root)!=ids['root']:
        raise ValueError('Root partition identity changed before mount.')
    run(['mount',root,str(TARGET)])
    verify_mount(TARGET,ids['root'])
    (TARGET/'boot').mkdir()
    if partition_identity(expected,1,esp,(str(TARGET),))!=ids['esp']:
        raise ValueError('EFI partition identity changed before mount.')
    run(['mount',esp,str(TARGET/'boot')])
    verify_mount(TARGET/'boot',ids['esp'])

def validate_empty_target_mountpoint():
    if TARGET.is_symlink() or (TARGET.exists() and any(TARGET.iterdir())):
        raise ValueError('/mnt is linked or already populated; use --reuse-mounted for prepared filesystems.')
    result=subprocess.run(['findmnt','--mountpoint',str(TARGET)],stdout=subprocess.DEVNULL)
    if result.returncode==0:raise ValueError('/mnt is mounted already; use --reuse-mounted.')

def checkout_revision(revision,work):
    if not re.fullmatch(r'[0-9a-f]{40}',revision):
        raise ValueError('Use the GitHub nix run command so the installer has an exact source revision.')
    repo=work/'repository'
    run(['git','init',str(repo)])
    run(['git','-C',str(repo),'remote','add','origin',URL])
    run(['git','-C',str(repo),'fetch','--depth','1','origin',revision])
    run(['git','-C',str(repo),'checkout','--detach','FETCH_HEAD'])
    head=run(['git','-C',str(repo),'rev-parse','HEAD'],True)
    if head!=revision:raise ValueError('Source revision mismatch.')
    for rel in ('installation/flake.lock','scripts/install-from-live-usb.py','scripts/bootstrap-nixos.sh','wallpapers'):
        if not (repo/rel).exists():raise ValueError(f'Incomplete source: {rel}')
    return repo

def install_all(repo):
    tool=repo/'scripts/install-from-live-usb.py'
    for index,phase in enumerate(('prepare','build','install','password','verify'),1):
        print(f'\n[{index}/5] {phase.upper()}\n'+'='*56,flush=True)
        run([sys.executable,str(tool),'--phase',phase,'--target',str(TARGET)])

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision',default='')
    parser.add_argument('--plan',action='store_true',help='Show the flow without changes, even on an installed system.')
    parser.add_argument('--reuse-mounted',action='store_true',help='Preserve partitions already mounted at /mnt and /mnt/boot.')
    args=parser.parse_args(argv)
    if args.plan:
        print(json.dumps({'mode':'PLAN_ONLY','source_revision':args.revision,
            'flow':['select internal disk','confirm that disk erasure','1 GiB EFI + ext4 root',
                    'generate fresh hardware','restore full desktop and wallpapers','build',
                    'install system and bootloader','set aesc login password','verify'],
            'reboot':'manual after completion','target':'/mnt'},indent=2));return 0
    require_live_usb()
    if not sys.stdin.isatty():raise ValueError('Run the pasted command in the live USB terminal.')
    os.environ['NIX_CONFIG']=os.environ.get('NIX_CONFIG','')+'\nexperimental-features = nix-command flakes\n'
    print('\nTONELICO · COMPLETE NIXOS INSTALLATION\n'+'='*56,flush=True)
    work=Path(tempfile.mkdtemp(prefix='tonelico-full-install.',dir='/tmp'))
    work.chmod(0o700)
    print(f'[WORKSPACE] {work}; retained if a phase fails.',flush=True)
    repo=checkout_revision(args.revision,work)
    if not args.reuse_mounted:
        validate_empty_target_mountpoint()
        selected,expected=select_disk()
        fd=acquire_disk(expected)
        try:
            root,esp,ids=partition_disk(expected)
            mount_target(root,esp,expected,ids)
        finally:os.close(fd)
    install_all(repo)
    run(['sync'])
    print('\n[COMPLETE] NixOS is installed on the internal disk.\nLogin: aesc, using the password you just set.\nShut down, remove the installer USB, then power on normally.\nThe desktop, applications, settings and wallpapers are on the installed disk.\nPrivate Telegram/API credentials are not in the public repository.\nNo reboot was triggered by the installer.',flush=True)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (ValueError,OSError,subprocess.CalledProcessError,KeyError) as exc:
        print(f'\n[FAILED] {exc}\nNo reboot performed. Existing install work and receipts remain available.',file=sys.stderr)
        raise SystemExit(1)
