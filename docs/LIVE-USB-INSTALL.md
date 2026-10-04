# Complete NixOS installation from one pasted command

Use an x86_64 NixOS live USB booted in UEFI mode, with internet access. This installs the personal Intel laptop profile, user `aesc` (UID 1000), reviewed Gen129 lineage with approved fixes. It includes the configured desktop sessions, applications, selected dotfiles, maintenance tools and every repository wallpaper. Existing laptop recovery generations are excluded from the portable profile; no old disk UUIDs are reused.

```bash
nix --extra-experimental-features 'nix-command flakes' run --refresh github:Roshrak/nixos-config#install
```

The root flake packages the prerequisites and pins the checkout to the same exact GitHub commit as the launcher. It uses a private workspace, never a fixed `/tmp` download or partial `curl | bash` execution. The program refuses an installed OS, non-UEFI boot or a non-terminal invocation. The first fetch completes before any disk is erased.

## Within that single command

1. Select an eligible internal disk from the displayed number/model/size/serial list. Mounted disks, active swap/RAID holders, USB/removable/read-only devices and disks below 80 GiB are excluded. Minimum capacity is a floor, not a guarantee that every future package collection fits.
2. Type the exact `ERASE /dev/...` phrase for that disk. **Its entire partition table and all previous data will be replaced.** Keep separate backups before using the installer. No disk is automatically chosen.
3. The installer creates GPT, a 1 GiB FAT32 EFI partition and an ext4 root partition, and mounts them at `/mnt` and `/mnt/boot`. Swap uses the declared zram configuration.
4. Generate a fresh hardware configuration using `nixos-generate-config`, validate the complete NixOS toplevel, deploy source into `/mnt/etc/nixos`, restore selected desktop configuration and wallpapers, and retain the clone in `/mnt/home/aesc/nixos-config`.
5. Build the entire system **in the target disk's Nix store**, with target-disk build scratch space. This avoids filling the live USB's RAM-backed store. Download/compiler progress stays visible. Install exactly the recorded built closure and bootloader without switching the live USB.
6. Enter the `aesc` login password through `passwd` in the target root. It is neither guessed nor logged. Root's password prompt is skipped; the configured wheel policy provides administrator access to `aesc`.
7. Verify source identity, installed profile, target-store kernel/initrd/activation files, boot entry payloads, standalone UEFI fallback loader and initialized login password. Sync disk writes. No automatic reboot, logout or suspend occurs.

After `[COMPLETE]`, shut down normally, remove the USB and power on. Cold boot and graphical/physical acceptance are separate from static installation checks. Private Telegram/API credentials, personal documents, VM images and browser/session secrets are not published or copied.

## Already prepared partitions

If you intentionally partitioned/mounted writable root and EFI filesystems yourself, use the same command with `-- --reuse-mounted`. This preserves partitioning/formatting and uses `/mnt` and `/mnt/boot`; the phased helper independently rejects the running root, live ESP, linked paths, bad filesystem types and mount identity drift.

```bash
nix --extra-experimental-features 'nix-command flakes' run --refresh github:Roshrak/nixos-config#install -- --reuse-mounted
```

`-- --plan` prints the flow without elevating privilege or changing anything, even on an installed system.

## Failure and continuation

The installer stops on a failed command, prints its error, and retains the named `/tmp/tonelico-full-install.*` workspace and private target receipt `/mnt/var/lib/nixos-live-installer/receipt.json`. A build/download failure does not produce a completion message. Formatting is irreversible; failure recovery preserves the new target state, not erased old data.

While still in the same live session, continue the failed phase from the printed workspace instead of running disk selection/formatting again:

```bash
cd /tmp/tonelico-full-install.REPLACE_WITH_PRINTED_SUFFIX/repository
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase build
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase install
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase password
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase verify
```

Use the launcher-provided tools' shell if the live terminal lacks a prerequisite. Re-run only the necessary phase: install is repeatable against the recorded candidate, password may be retried, verify is non-destructive except for its receipt. Do not rerun prepare over a recorded installed target. Source/mount drift refuses stale continuation; inspect it before proceeding. The phase script is an internal/recovery tool, not the primary installation workflow.

Receipts are root-owned, mode 0600, atomically replaced and fsynced, with mount identity, source digest and exact built output. Before-images preserve pre-existing target configuration and selected user entries. Existing Git indexes are not bulk staged or reset. Concurrent partition writers cannot be proven impossible: an exclusive descriptor lock is cooperative, and identity/busy/parent checks narrow the check/use window. Do not run other disk tools during installation.

Hardware detection records devices and filesystems; it does not redesign this Intel laptop profile for an unrelated GPU or other architecture. No script can bypass credentials, physical boot testing, internet availability or disk-selection responsibility. See the [official NixOS installation manual](https://nixos.org/manual/nixos/stable/#sec-installation) for installation semantics.
