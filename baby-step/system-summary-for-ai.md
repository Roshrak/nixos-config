# Tonelico NixOS System Context for AI Assistance

Generated: 2026-08-31T01:34:24+07:00
Owner/user: `aesc` (UID 1000)
Purpose: Paste this file into an AI conversation when troubleshooting this computer.

This document deliberately contains no passwords, tokens, private keys, cookies,
IP addresses, MAC addresses, or Wi-Fi names. Dynamic facts can change after an
update. Verify current state before making important changes.

## Instructions for the assisting AI

- Treat the user as a Linux and NixOS beginner. Give copy/paste commands one at
  a time and explain what success or failure looks like.
- Prefer targeted, read-only discovery before changing anything.
- Prefer declarative NixOS changes under `/etc/nixos` over imperative fixes.
- Do not recursively scan `/`, `/nix/store`, the entire home directory, browser
  data, Steam games, caches, or Git object databases.
- Preserve unrelated user changes and create a backup before meaningful edits.
- Never display, log, or commit secrets.
- Build before switching. Never activate a configuration that failed to build.
- Do not force-push, reset destructively, or delete unknown files.
- The hostname and flake attribute are intentionally different. Always use the
  explicit target `/etc/nixos#tonelico` unless fresh evaluation proves it changed.
- Files named `*.backup.*` and directories named `backup-*` are historical safety
  material, not active modules.

## System identity

| Item | Current value |
| --- | --- |
| Hostname | `tonelico-nix` |
| NixOS flake attribute | `tonelico` |
| Correct rebuild target | `/etc/nixos#tonelico` |
| OS | NixOS 26.05 (Yarara) |
| Architecture | `x86_64-linux` |
| Kernel | Linux 7.2.1 (`linuxPackages_latest`) |
| Nix | 2.34.8, flakes and `nix-command` enabled |
| Time zone | `Asia/Ho_Chi_Minh` |
| Locale | `en_US.UTF-8` |
| Current generation | 57, activated 2026-08-31 01:04:02 +07:00 |
| Current system path | `/nix/store/11z1lwpl69riaxd7aw8314h4yq66xm71-nixos-system-tonelico-nix-26.05.20260827.d57af92` |

## Hardware and storage

- Computer: Acer Swift SFG16-72 laptop.
- CPU: Intel Core Ultra 5 125U.
- GPU: Intel Meteor Lake-P integrated graphics, PCI ID `8086:7d45`.
- Wi-Fi: Intel Meteor Lake PCH CNVi, PCI ID `8086:7e40`.
- Audio: Intel Meteor Lake-P HD Audio, PCI ID `8086:7e28`.
- Memory: 15 GiB RAM; zram swap is enabled at 50% of RAM.
- Root filesystem: `/dev/nvme0n1p2`, ext4, 468 GiB total, about 343 GiB
  available at generation time.
- EFI system partition: `/dev/nvme0n1p1`, vfat, mounted at `/boot`, about 1 GiB.
- The EFI partition is shared with Arch. Do not reformat or casually replace it.
- Boot loader: systemd-boot, EFI variable access enabled, editor disabled,
  configuration limit 5.
- Automatic Nix store optimisation is enabled.
- Nix garbage collection runs weekly and removes generations older than 14 days.
- Firmware, Intel microcode, `fwupd`, periodic SSD trim, `thermald`, UPower, and
  power-profiles-daemon are enabled.

## Active NixOS configuration

Primary directory: `/etc/nixos`

Canonical Git source: `/home/aesc/nixos-config/nixos`

The flake automatically discovers complete directories under `hosts/`. The
active profile is `hosts/tonelico/`, which contains:

1. `host.nix`: flake/hostname/platform/deployment metadata.
2. `hardware-configuration.nix`: the generated Tonelico filesystem and hardware
   module.
3. `default.nix`: Intel Core Ultra graphics, microcode, VA-API, modesetting, and
   `thermald` settings specific to this Acer laptop.

The shared module graph then includes Mango, Comic Mono, Noctalia, Noctalia
Greeter, Fcitx5 Lotus, applications, Claude Code, Plasma, Niri, and
`configuration.nix`. Tonelico opts into `wave75-via.nix` and `windows-vm.nix`
through `host.nix`; new machines do not receive those optional modules unless
their own host metadata requests them.

The conventional `/etc/nixos/hardware-configuration.nix` is retained for
generation and recovery, but the active flake imports the host-scoped copy.

Main inputs include NixOS 26.05, Mango, Noctalia, Noctalia Greeter, Niri,
Fcitx5 Lotus, and Claude Code.

Important declarative settings:

- NetworkManager and the NixOS firewall are enabled.
- Bluetooth is enabled and powers on at boot.
- PipeWire handles ALSA, 32-bit ALSA, and PulseAudio compatibility.
- WirePlumber manages audio policy; realtime scheduling through rtkit is enabled.
- Intel `iHD` media acceleration and 32-bit graphics support are enabled.
- Flatpak, xdg-desktop-portal, GVfs, UDisks2, dconf, and GNOME Keyring are enabled.
- Cloudflare WARP is declaratively enabled.
- Unfree packages are allowed.
- `sudo` requires the user's password.
- The user belongs to `wheel`, `networkmanager`, `video`, `render`, `audio`,
  `input`, and `libvirtd` where declared.

## Desktop and login architecture

- Display/login manager: greetd with Noctalia Greeter.
- SDDM is deliberately disabled.
- Current session when this file was generated: Mango on Wayland.
- Three selectable Wayland sessions are installed:
  - Mango with Noctalia
  - KDE Plasma 6
  - Niri
- Session registration is shared with the Noctalia greeter.
- Mango and Niri use guarded wrappers to clean stale sessions during relogin.
- Niri uses `xwayland-satellite` for X11 applications and a session-owned LXQt
  polkit agent.
- Portal selection is intentionally session-specific so Mango, Plasma, and Niri
  do not steal each other's screenshot or screencast backends.
- Noctalia provides the bar, launcher, notifications, wallpaper, lock screen,
  OSD, tray, control center, and clipboard functions where configured.
- Global Wayland-related variables include `NIXOS_OZONE_WL=1`,
  `MOZ_ENABLE_WAYLAND=1`, `TERMINAL=kitty`, and `LIBVA_DRIVER_NAME=iHD`.

## Input methods and keyboards

- Fcitx5 is enabled with the Wayland frontend, Unikey, GTK integration, and the
  Fcitx5 Lotus service for user `aesc`.
- The intentional Mango settings are:

  ```text
  env=QT_IM_MODULES,wayland;fcitx
  env=XMODIFIERS,@im=fcitx
  exec-once=fcitx5 -d
  ```

- Preserve those settings. Do not restore an older Mango backup over them.
- The invalid Mango keyword `ov_tab_mode=0` was removed. Mango 0.16.2 parses the
  live config and both restorable theme profiles successfully.
- Wave75/VIA keyboard support is in `wave75-via.nix`; QMK and VIA udev rules are
  enabled there.
- Wireless keyboard receiver: `36b0:3002 RDMCTMZT Wireless 2.4G Dongle`.
- It previously exposed `ID_INPUT_JOYSTICK=1`, which made Minecraft detect a
  controller. A merged `services.udev.extraRules` entry now clears that property.
- Current receiver interfaces were verified without `ID_INPUT_JOYSTICK=1`.
- Input event numbers such as `event9` are temporary; always locate the receiver
  by vendor/product IDs rather than a fixed event number.
- A separate `36b0:3009` hidraw rule grants VIA access through `users`/`uaccess`.
- There must be only one `services.udev.extraRules` assignment in
  `configuration.nix`; merge future rules into its multiline block.

## Current service health

Last verified on 2026-08-31:

- Failed system services: 0.
- Failed user services: 0.
- NetworkManager: active; Wi-Fi connected.
- DNS lookup: working through NetworkManager-managed DNS.
- `systemd-resolved` is not the configured DNS owner, so a failed `resolvectl`
  command by itself does not prove DNS is broken.
- Bluetooth: active.
- greetd: active.
- PipeWire and WirePlumber user services: active.
- Default output: Intel Meteor Lake-P speaker.
- Default input: Intel Meteor Lake-P digital microphone.
- Final baby-step health check: 14/14 checks passed.

## Important applications and command versions

- Mango 0.16.2.
- Niri stable 26.04.
- Fcitx5 5.1.19.
- Python 3.13.15.
- Codex CLI 0.146.0.
- Claude Code 2.1.251.
- Git 2.54.0.
- Flatpak 1.16.6.
- Chromium 152.0.7977.64.
- Kitty 0.48.2.
- Neovim 0.12.4.
- Steam, OBS Studio, Prism Launcher, Discord, Obsidian, LibreOffice, MangoHud,
  GameMode, GitHub CLI, GCC, fzf, and lazygit are configured or available.
- Steam and OBS are reached through custom wrappers under `~/.local/bin`.
- Codex, Claude Code, and Python are declaratively installed so a rebuild keeps
  them available.

## Virtualisation

- libvirt/QEMU is enabled.
- virt-manager is installed.
- Software TPM (`swtpm`), `virtiofsd`, dnsmasq, and SPICE USB redirection are
  configured.
- User `aesc` belongs to `libvirtd`.

## Custom helper scripts

Important files under `/home/aesc/.local/bin` include:

- `apply-theme-profile`
- `clean-stray-sessions`
- `mango-session-guarded`
- `niri-session-guarded`
- `noctalia-greeter-sync-smart`
- `save-noctalia-profile`
- `mango-animation`
- `steam`
- `obs`, `obs-safe`, and `obs-fix-recording-paths`
- `slogout`

Do not remove a custom helper before checking which session or configuration
calls it.

## Beginner-safe maintenance tools

Canonical directory: `/home/aesc/baby-step`

```bash
# Read-only health check
~/baby-step/check-system.sh

# Update NixOS and safely activate it
~/baby-step/update-system.sh

# Update, snapshot configuration, commit, and push to GitHub
~/baby-step/update-and-push.sh

# Rebuild current inputs without updating them
~/baby-step/rebuild-system.sh

# Refresh only the recoverable local configuration snapshot
~/baby-step/backup-config.sh
```

Multi-machine deployment and installation:

```text
Guide:  /home/aesc/nixos-config/docs/MIGRATION-INSTALL.md
Script: /home/aesc/nixos-config/scripts/bootstrap-nixos.sh
```

The bootstrap script detects or creates host profiles, imports freshly generated
hardware configuration, validates a complete temporary candidate, backs up
existing system and selected user configuration, deploys required files, and can
optionally build, switch, or run `nixos-install`. It was tested for current-host
detection, new-host creation, repeated idempotent deployment, selected user-file
placement, automatic host discovery, and a complete Tonelico system build.

The scripts dynamically detect the flake attribute, use timestamped logs, check
disk space and required commands, evaluate before building, build before
switching, stop on failure, and verify services afterward. The Git workflow
checks identity and remote state early, scans staged additions for obvious
secrets, never force-pushes, and verifies the remote commit.

Logs: `/home/aesc/baby-step/logs`
Maintenance state: `/home/aesc/baby-step/state/last-maintenance.txt`
Safety backups: `/home/aesc/baby-step/backups`

## Git and recovery configuration

- Recoverable Git repository: `/home/aesc/nixos-config`.
- GitHub repository: `https://github.com/Roshrak/nixos-config.git`.
- Branch: `main`.
- Run `git -C /home/aesc/nixos-config log -1 --oneline` for the current verified
  commit; the maintenance state records the last confirmed remote hash.
- The repository stores the canonical multi-host NixOS source, per-host generated
  hardware modules, selected user configuration, selected helpers, documentation,
  deployment scripts, and the baby-step toolkit. It does not intentionally store
  logs, runtime state, secrets, or large personal data.
- Generated hardware files contain filesystem UUIDs needed for reinstall; those
  identifiers are not authentication secrets. Never add passwords, encryption
  recovery material, tokens, or private keys.
- `/etc/nixos` also has a local Git recovery repository on branch `master`.
- Both repositories should be kept clean after verified Git snapshots; check with
  `git status --short --branch` rather than assuming.
- Repo-local Git identity is configured as `Roshrak` with a GitHub noreply
  address. Do not invent or replace the user's email.

Existing backups include:

- `/home/aesc/baby-step/backups/2026-08-31-pre-maintenance`
- `/home/aesc/baby-step/backups/etc-nixos-before-multihost-20260831-1022`
- timestamped `repository-before-*` snapshots under the backup directory
- `/etc/nixos/configuration.nix.backup.20260830-224757`
- `/etc/nixos/configuration.nix.backup.20260830-224805`
- `/etc/nixos/configuration.nix.backup.20260830-224832`

Those files are not active modules. Do not delete or restore them casually.

## Important repair history

1. A keyboard udev change initially created two `services.udev.extraRules`
   definitions and Nix evaluation failed. Nothing was activated by that failed
   rebuild. The rules were later merged correctly.
2. `sudo nixos-rebuild switch` once selected the hostname `tonelico-nix` as a
   flake attribute and failed. The real attribute is `tonelico`; use the explicit
   target.
3. A downloaded `fix-keyboard-controller.sh` stopped before editing because
   `python3` was missing. Python is now installed, but do not assume old failed
   scripts changed anything.
4. Mango previously rejected `ov_tab_mode=0`. The unsupported line was removed
   from the live and restorable source configs without disturbing Fcitx5 Lotus.
5. Claude Code's module existed but was not imported. It is now imported by the
   active flake.
6. An older update script in `~/Downloads` was retained for history but replaced
   operationally by the baby-step tools.

## Known low-priority observations

The final health check has no outstanding actionable warnings. Earlier boot-log
inspection observed some low/informational noise: Noctalia greeter DRM atomic
retries before login, duplicate DBus service-name messages, one ACPI firmware
warning, and an optional GVfs `wsdd` component not being present. Login works and
no system or user services are failed. Investigate these only if a related symptom
appears; do not apply speculative fixes.

## Recovery rules

If a build fails before activation, the running generation is unchanged. Do not
switch it manually.

If a newly activated generation is broken but Terminal still works:

```bash
sudo nixos-rebuild switch --rollback
```

If the login screen cannot be reached, reboot and choose an older NixOS generation
from the systemd-boot menu. Do not delete old generations while troubleshooting.

Last successful rebuild log:
`/home/aesc/baby-step/logs/rebuild-2026-08-31-011844.log`

Last full health log at generation time:
`/home/aesc/baby-step/logs/check-2026-08-31-012657.log`

## Trash and free-space state

- The standard user Trash was emptied with KDE's `ktrash6 --empty`.
- Verified items remaining: 0.
- The Trash directory itself uses about 24 KiB for required folder metadata.
- No root, filesystem-level, or `/boot` Trash directory was found.
- Root filesystem space after the check: about 343 GiB available (23% used).
- No caches, Downloads, backups, personal files, or Nix store paths were deleted.
