# Phase 0 — Audit Report (2026-08-26, read-only)

Raw evidence in `audit/`. Nothing was modified during collection.

## System
- NixOS 26.05 (flake pin `nixpkgs/nixos-26.05`), kernel see `audit/kernel.txt`
- Root fs: **ext4 on NVMe** — no snapshot capability; rollback = NixOS generations + tarballs
- Disk: 468G total, ~104G used, 340G free · RAM 16G + zram swap
- GPU: Intel Meteor Lake-P (iHD VA-API, LIBVA_DRIVER_NAME=iHD already set)

## Sessions & greeter
- Installed sessions: `mango.desktop`, `plasma.desktop` (audit/sessions.txt)
- Login: greetd + **noctalia-greeter** (SDDM disabled); session picker scans
  `share/wayland-sessions` via the dm-sessions-share runCommand package in
  `/etc/nixos/desktop/plasma.nix`; X11 sessions not yet exposed there
- Mango 0.16.1: started from its .desktop → reads `~/.config/mango/config.conf`;
  autostart chain: `exec-once=noctalia`, `exec-once=apply-theme-profile mango`, fcitx5
- KDE 6.6.6: standard plasma-wayland session; user env hooks
  `~/.config/plasma-workspace/env/00-theme-profile.sh` (kde theme stamp) and
  `01-reset-stale-plasma.sh` (stale-unit fix)
- Noctalia v5.0.0 state dir: `~/.local/state/noctalia/` (settings.toml with
  `[theme.templates] builtin_ids = [btop, cava, gtk3, gtk4, kitty, mango, qt]`,
  community_ids = [discord, obsidian, prismlauncher, obs])
- Known-good isolation already deployed: `~/.config/theme-profiles/{mango,kde}`,
  `~/.local/bin/apply-theme-profile`, kded gtkconfig module disabled,
  kitty niri-breeze pin for KDE

## Portals (`audit/portals.conf`, `audit/mango-portals.conf`, `audit/portal-packages.txt`)
- Installed backends: gtk, wlr, kde, kwallet, gnome-keyring
- Global `/etc/xdg/xdg-desktop-portal/portals.conf`: default=gtk,
  ScreenCast/Screenshot=wlr, Secret=gnome-keyring
- Per-session override exists only for mango; KDE auto-selects via XDG_CURRENT_DESKTOP

## Services & units
- System-enabled unit files: 92 (audit/system-services.txt) — PipeWire/WirePlumber/
  NetworkManager/BlueZ/greetd among them; nothing desktop-specific beyond the above
- User manager (aesc): 27 running services, dominated by plasma-* (expected while in
  KDE session) — confirms persistent-user-manager behavior that caused stale-unit bug

## Keyring / PAM / polkit (audit/pam.txt)
- gnome-keyring enabled system-wide (`services.gnome.gnome-keyring.enable`), unlocked via
  greetd PAM (gkr-pam logs), Secret portal working
- PAM services include greetd, kde (added by plasma.nix for kscreenlocker)

## Environment snapshot
- Full dump of current KDE session env in `audit/current-session-env.txt`
- Globals present: NIXOS_OZONE_WL=1, MOZ_ENABLE_WAYLAND=1, QT_WAYLAND_RECONNECT=1,
  XMODIFIERS=@im=fcitx, NIXPKGS_QT6_QML_IMPORT_PATH (plasma-injected).
  No GDK_BACKEND / QT_QPA_PLATFORM globals ✓

## Upstream facts verified (2026-08-26)
- Noctalia README: official compositor integrations incl. **Niri**, Hyprland, Mango…;
  workspace backends per-compositor or ext-workspace-v1; TOML hot-reload config;
  separate noctalia-greeter project
- niri wiki "Important Software": portals = gtk + **xdg-desktop-portal-gnome
  (required for screencast)** + gnome-keyring; ships niri-portals.conf; needs
  FileChooser=gtk if nautilus unwanted; polkit agent required; XWayland via
  xwayland-satellite; **do not set GDK_BACKEND globally**
- Illogical Impulse (end-4/dots-hyprland): Quickshell-based shell now; installer
  `bash <(curl -s https://ii.clsty.link/get)` or repo `./setup install` (transparent);
  ⚠️ Hyprland 0.55 Luaification transition may require their pre-Lua release branch
  depending on Hyprland version available in nixpkgs at install time

## Open items carried into later phases
- Identify Mango-session polkit agent process (check under live Mango login during P5)
- Decide niri Noctalia profile mechanism after reading Noctalia CLI/config docs (P5)
- Confirm Hyprland version in nixpkgs-26.05 vs II branch requirement (P8 gate)
