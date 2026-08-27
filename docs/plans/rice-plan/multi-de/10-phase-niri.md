# Phase 5 — Niri + Noctalia v5

Status: **staged, awaiting rebuild #1**

## Purpose
Third independent session (Niri compositor + Noctalia v5 shell) per the
master plan, with zero configuration coupling to Mango/KDE.

## Scope
- System (via sudo, staged): `flake.nix` (+niri input), new `desktop/niri.nix`
- User-owned: `~/.config/niri/config.kdl`, `theme-profiles/niri/*`,
  extended `apply-theme-profile`, new `save-noctalia-profile`,
  reorder+re-add of the mango exec-once line (live config **and both
  desktop-look-toggle saved profiles**, which had clobbered it once)

## Decisions recorded
- niri source: `github:epireyn/niri-flake` (officially recommended module;
  provides session units, portal-gnome, keyring wiring; builds for 26.05)
- Two-step rebuild to activate their binary cache before compiling niri
- Module's user-wide KDE polkit agent disabled (`niri-flake-polkit`);
  niri spawns `lxqt-policykit` inside its own config instead
- Niri visual identity: adw-gtk3-dark / Papirus-Dark / Bibata-Original-Amber /
  kitty Tokyo-Night-style palette / Noctalia builtin "Noctalia" palette —
  distinct from Mango (wallpaper-vibrant) and KDE (breeze)
- Portal selection via `/etc/xdg/xdg-desktop-portal/niri-portals.conf`
  (gtk default, gnome ScreenCast/Screenshot, gnome-keyring Secret)
- XWayland: xwayland-satellite in PATH; auto-launched by niri ≥25.08;
  `DISPLAY ":0"` set in niri env block
- Noctalia state isolation: every login stamps
  `~/.local/state/noctalia/settings.toml` from the profile; in-session
  changes persist for that session only until you run
  `save-noctalia-profile <mango|kde|niri>`
- Mango guard: `apply-theme-profile mango` now runs BEFORE `exec-once=noctalia`

## Runbook
```sh
sudo bash "$HOME/rice plan/multi-de/staging/APPLY-rebuild1.sh"   # commit+chown+stage+eval
sudo nixos-rebuild switch --flake /etc/nixos#tonelico            # rebuild 1
#   -> then flip programs.niri.enable = true in /etc/nixos/desktop/niri.nix
sudo nixos-rebuild switch --flake /etc/nixos#tonelico            # rebuild 2
```

## Verification (after rebuild 2)
1. `grep -q 'programs.niri.enable = true' /etc/nixos/desktop/niri.nix`
2. `ls /run/current-system/sw/share/wayland-sessions/ | grep niri` → `niri.desktop`
3. Greeter lists **Niri**; log in: Noctalia bar appears, panels open
   (`Mod+D` launcher, `Mod+C` control center), lock works (`Mod+L`)
4. kitty shows amber palette; GTK apps show Papirus icons
5. Polkit prompt works (`pkexec true`)

## Regression gate (MANDATORY)
- Mango+Noctalia: bar, launcher, notify-send, screenshot, wallpaper intact,
  theme still the wallpaper-vibrant look (state was NOT swapped)
- KDE: login, breeze GTK+kitty restored automatically at next KDE login,
  file dialog portal OK, lock screen OK

## Rollback
```sh
sudo nixos-rebuild switch --rollback          # or pick previous gen in boot menu
cd /etc/nixos && sudo git checkout <pre-phase5-commit> -- .   # config side
rm -rf ~/.config/niri                          # user side (optional)
```

## Open items
- Confirm Mango's existing polkit agent identity under live Mango login
- If niri-stable cache misses on 26.05 pin, expect one local rust build (~10–20 min)
