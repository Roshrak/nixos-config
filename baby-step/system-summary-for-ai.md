# Tonelico NixOS — AI Context Card

Refreshed: 2026-09-02 ~21:18 +07:00. No secrets in this file. Shows username, hostname, hardware model, and GitHub repo identity.

## SYSTEM

- Hostname: `tonelico-nix` | Flake attr: `tonelico` (NOT the same!) | Always use `/etc/nixos#tonelico`
- NixOS 26.05 (Yarara), kernel 7.2.2 #1-NixOS, active generation 71, fallback generation 61, x86_64
- Acer Swift SFG16-72: Intel Core Ultra 5 125U, Meteor Lake iGPU, 15 GiB RAM, zram swap
- Disk: 468 GiB NVMe (`/dev/nvme0n1p2`), 104 GiB used (24%), ~341 GiB free; `/boot` 1 GiB vfat ~968 MiB free (shared with Arch — never reformat)
- User: `aesc` (UID 1000, wheel, libvirtd). TZ Asia/Ho_Chi_Minh. Locale en_US.UTF-8.
- Login: greetd + Noctalia Greeter (SDDM intentionally off). Sessions: Mango+Noctalia, Plasma 6, Niri, Sway+Noctalia. Current: Niri on Wayland.
- Audio: PipeWire + WirePlumber. Input: Fcitx5 + Unikey + Fcitx5 Lotus (Wayland frontend).
- Health 2026-09-02: 0 failed system units, 0 failed user units. Network/DNS/Bluetooth/audio services OK.

## VIRTUALIZATION & ISO ASSETS (STRICTLY PROTECTED)

- VM `win11` disk: `/var/lib/libvirt/images/win11.qcow2` (38.92 GiB allocated / 150 GiB capacity)
- ISOs: `/home/aesc/Downloads/virtio-win.iso` (754 MiB), `/home/aesc/VM-ISO/virtio-win.iso` (837 MiB), `/home/aesc/Downloads/virtio-win.isocd` (2.84 MiB)
- Storage Pools: `default` (`/var/lib/libvirt/images`), `Downloads` (`/home/aesc/Downloads`)
- NEVER DELETE OR MODIFY VM IMAGES OR ISOs.

## RULES FOR ANY AI HELPING

- User is a beginner: one copy-paste command at a time, say what success looks like.
- Target is always `/etc/nixos#tonelico`, never `#tonelico-nix`.
- Build before switch. Never switch a failed build. Broken after switch: `sudo nixos-rebuild switch --rollback`. No login screen: boot older generation from systemd-boot menu.
- Live config: `/etc/nixos`. Git backup: `/home/aesc/nixos-config` (branch `main` → github.com/Roshrak/nixos-config).
- Only ONE `services.udev.extraRules` block exists in `configuration.nix` — merge new udev rules into it.
- Preserve Mango lines: `env=QT_IM_MODULES,wayland;fcitx`, `env=XMODIFIERS,@im=fcitx`, `exec-once=fcitx5 -d`.
- Mandatory agent operating guidelines: see `~/baby-step/AGENTS.md`, `~/baby-step/AI-MAINTENANCE-RULES.md`, and `~/baby-step/GEMINI.md`.

## STATE RIGHT NOW (2026-09-02)

- Machine healthy. 0 critical problems.
- Nix dead store paths garbage collected: freed 3.2 GiB on `/`.
- All 7 maintenance scripts verified healthy (0 broken, 0 unsafe, 0 obsolete).
- Full audit reference: `~/baby-step/system-audit.md` and `~/baby-step/cleanup-results.md`. Logs: `~/baby-step/logs`.

## COMMANDS

- `~/baby-step/check-system.sh` — health check (exit 0 clean / 1 warnings / 2 failures)
- `~/baby-step/update-system.sh` — update; `update-and-push.sh` — update + Git
- `~/baby-step/rebuild-system.sh` — rebuild only; `backup-config.sh` — local snapshot
- Beginner summary: `~/baby-step/system-summary.txt`
