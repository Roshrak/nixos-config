# Tonelico · NixOS desktop & live-USB restore

A pinned NixOS desktop for **aesc**: Niri, Sway, Mango, Hyprland, KDE Plasma, GNOME and XFCE, Noctalia, Fcitx5 Lotus, development tools, and the declared agent services.

**Start here:** [Live-USB installation](docs/LIVE-USB-INSTALL.md) · [Maintenance commands](baby-step/README.txt) · [Wallpapers](wallpapers/)

| Path | Purpose |
| --- | --- |
| [`installation/`](installation/) | Reviewed desktop source for a fresh install; no saved laptop recovery-generation pins |
| [`scripts/install-from-live-usb.py`](scripts/install-from-live-usb.py) | Explicit inspect → prepare → build → install → password → verify phases |
| [`scripts/bootstrap-nixos.sh`](scripts/bootstrap-nixos.sh) | Host/hardware import, recoverable configuration deployment and selected user-file restore |
| [`dotfiles/`](dotfiles/) | Selected desktop settings and manifest-approved service code; credentials excluded |
| [`baby-step/`](baby-step/) | Maintenance commands with stages, live output, exit codes, private logs and isolated tests |
| [`wallpapers/`](wallpapers/) | All 30 original images, approximately 100 MiB; restored into `~/Pictures/Wallpapers` |
| [`nixos/`](nixos/) | Original configuration/history; the installer uses the reviewed `installation/` subtree |

## From the NixOS live USB

Boot in **UEFI mode**, choose and mount your installation root at `/mnt` and its EFI partition at `/mnt/boot`. The helper **does not partition or format disks**, reboot, or switch the live system. This snapshot targets the current Intel x86_64 laptop and user `aesc` (UID 1000); it is not a universal hardware image.

```bash
nix-shell -p git python3
git clone https://github.com/Roshrak/nixos-config.git
cd nixos-config
python3 scripts/install-from-live-usb.py --phase inspect
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase prepare
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase build
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase install
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase password
sudo "$(command -v python3)" scripts/install-from-live-usb.py --phase verify
```

`prepare` generates **fresh hardware configuration**; no old disk UUIDs are reused. `build` records the exact output; `install` checks that source and mount identities still match before installing it. `password` sets the login password interactively without saving it in a log. Detailed preparation, failure recovery and limitations are in the [installation guide](docs/LIVE-USB-INSTALL.md).

## On the installed desktop

```bash
~/baby-step/check-system.sh
~/baby-step/rebuild-system.sh --build-only
~/baby-step/update-system.sh --check-only
~/baby-step/run-tests.sh --quick
```

Run maintenance as your normal user. A private source pointer selects `/etc/nixos` on fresh installs and `/etc/nixos/gen129-recovery` on the recovered laptop. Explicit `path:` flake references include required new files without staging unrelated Git work.

`autosleep on` selects lock/display-off after five minutes of inactivity while applications remain running; `autosleep off` disables idle display-off. Overview bindings are `Super+O` and `Super+Shift+middle-click` in the configured sessions. Automated source/build tests verify integration; physical shortcuts, actual idle/lock behavior and subjective visual acceptance still need desktop acceptance.

Publication and backup tools preserve existing Git work and scan approved source paths. Cloud wallpaper transfer uses `rclone copy` rather than deleting destination-only files. Read [custom-service restore boundaries](docs/CUSTOM-SERVICE-RESTORE.md) before restoring agents.

## Wallpaper previews

<p>
  <img src="wallpapers/tree.jpg" width="290" alt="Tree wallpaper">
  <img src="wallpapers/nix.png" width="290" alt="Nix wallpaper">
</p>

[Browse the complete folder](wallpapers/). Images retain their original filenames and bytes. This repository does not grant ownership or a new license to third-party artwork.

## What a restore does and does not include

The clone contains the declared system, selected dotfiles, scripts, fonts, wallpaper assets and approved custom-service source. It does not contain Telegram/API tokens, browser cookies, passwords, private keys, personal documents, VM disks or the entire home directory. Agent credentials and any omitted application data need their own private restore. A successful build is not proof of a successful cold boot, working screen sharing or physical hardware behavior.
