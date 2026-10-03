# Install this desktop from a NixOS live USB

This workflow prepares the reviewed desktop snapshot in `installation/`, derived from the Gen129 recovery line plus reviewed fixes used by the prepared Gen134 candidate. Laptop-only Gen128/129 boot recovery pins are deliberately absent: those store paths do not exist on a new installation. The pinned `flake.lock` is retained unchanged.

## 1. Prepare the target yourself

Use the current NixOS installer ISO and boot it in **UEFI mode**. This desktop snapshot supports the existing Intel x86_64 laptop, username `aesc`, UID 1000. Keep any existing system/data backups before choosing installation partitions.

Follow the [official NixOS installation instructions](https://nixos.org/manual/nixos/stable/#sec-installation) to select partitions, create filesystems if needed, and mount the intended root at `/mnt` and a FAT EFI system partition at `/mnt/boot`. The helper intentionally contains no automatic disk selection or formatting commands. Root may be ext4, Btrfs or XFS; generated hardware configuration records your mounts. Other hardware needs a separate reviewed host profile.

Open a shell with the prerequisites:

```bash
nix-shell -p git python3
git clone https://github.com/Roshrak/nixos-config.git
cd nixos-config
python3 scripts/install-from-live-usb.py --phase inspect
```

The first command displays disks and mountpoints only. Establish network access in the live environment; builds can require substantial downloads and disk space. Keep the cloned directory available through all phases.

## 2. Prepare source and user configuration

```bash
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase prepare
```

The helper rejects the running root, protected system paths, linked paths, missing/wrong mounts, read-only mounts and reuse of the running system's EFI partition. It generates hardware configuration in a private temporary directory and invokes the bootstrap to deploy it into `/mnt/etc/nixos`. Selected dotfiles, maintained baby-step scripts, approved service source and all wallpapers are restored into `/mnt/home/aesc`. The local maintenance pointer is set to `/etc/nixos` for the future installed system.

Existing configuration and user entries are retained in timestamped before-images, including `/mnt/etc/nixos.before-bootstrap-*` and `/mnt/var/backups/nixos-bootstrap/`. Existing Git indexes are never automatically staged. Source files are validated by complete toplevel evaluation before deployment. The existing bootstrap can change the cloned host hardware file, preserving its before-image in the target backup.

A private receipt is stored at `/mnt/var/lib/nixos-live-installer/receipt.json`. It records mount identities, source digest, phase state and built output; no secret values. Do not change files between build and install. If source or mount identity changes, the helper refuses stale continuation.

## 3. Build without installing

```bash
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase build
```

The complete `path:/mnt/etc/nixos#nixosConfigurations.tonelico.config.system.build.toplevel` is built without a result link, lock update or activation. The actual compiler/download output remains visible. The receipt records the exact candidate store path. Free space must accommodate the build and copied system closure.

## 4. Install the exact built candidate

```bash
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase install
```

The helper revalidates mounts, source digest, candidate identity and kernel/initrd/activation payloads, then uses `nixos-install --system` for that exact output. It validates the resulting system-profile link. It does not reboot or switch the live USB. The [NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installation) documents installation into a mounted root. Root's password prompt is skipped explicitly; **the login user still needs a password** in the next phase.

## 5. Initialize and verify the login account

```bash
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase password
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase verify
```

Password entry goes directly to `passwd aesc` through `nixos-enter`, never to captured logs or a command-line password. Noninteractive execution refuses this phase. No password is guessed or copied from another machine. `verify` checks account initialization without printing the hash, source identity, installed profile and boot entries. It fails if the password is still unset. Existing intentional wheel/trusted-Nix-user policy remains part of this personal desktop; review it for shared machines.

At that point the automated preparation is complete. Normal reboot, desktop login, idle/display behavior, audio quality, physical shortcuts, external monitors, suspend and agent credentials are separate acceptance items. The helper does not claim these were tested.

## Failures and recovery

Every phase stops on errors, shows the failing command/status and preserves before-images and receipts. `build` can be rerun while source/mount identity is unchanged. An interrupted `install` can be rerun against the recorded candidate; NixOS installation is designed to be repeatable. Do not rerun `prepare` after a recorded successful install; build/verify the existing source instead. If source changes intentionally, inspect the diff and start a fresh preparation before installation.

Rollback of prepared configuration uses its exact before-image; restore only the affected entries after inspecting their paths. Do not overwrite later edits or run blanket Git resets/cleans. No cleanup, backup replacement, shutdown or formatting happens automatically. The installer cannot make disk selection, credentials or physical acceptance autonomous.

## Advanced bootstrap

`bootstrap-nixos.sh --help` documents custom host/source/hardware selection and dry-run. Its default source is now the portable installation subtree. For this laptop's installed recovery configuration, use an explicit `--source /etc/nixos/gen129-recovery` when appropriate; preserve existing recovery roots. The older migration document is background information; this guide is authoritative for live-USB phases.

## Validation boundaries

The published portable source was evaluated and built as a complete system without activation. Installer path/mount/source-drift failures and bootstrap restore failures are exercised with disposable fixtures. No actual fresh disk installation, password change, cold boot or desktop switch was performed on the working laptop during development. Keep a real recovery backup for an installation.
