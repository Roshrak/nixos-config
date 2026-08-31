# Tonelico NixOS — AI Context Card

Refreshed: 2026-08-31 ~22:40 +07:00. No secrets in this file. It does show
username, hostname, hardware model, and GitHub repo identity.

## SYSTEM

- Hostname: `tonelico-nix` | Flake attr: `tonelico` (NOT the same!) | Always use `/etc/nixos#tonelico`
- NixOS 26.05 (Yarara), kernel 7.2.2, generation 58, x86_64
- Acer Swift SFG16-72: Intel Core Ultra 5 125U, Meteor Lake iGPU, 15 GiB RAM, zram swap
- Disk: 468 GiB NVMe, `/` ~339 GiB free; `/boot` 1 GiB vfat ~914 MiB free (shared with Arch — never reformat)
- User: `aesc` (UID 1000, wheel). TZ Asia/Ho_Chi_Minh. Locale en_US.UTF-8.
- Login: greetd + Noctalia Greeter (SDDM intentionally off). Sessions: Mango+Noctalia, Plasma 6, Niri. Current: Niri on Wayland.
- Audio: PipeWire + WirePlumber. Input: Fcitx5 + Unikey + Fcitx5 Lotus (Wayland frontend).
- Health 2026-08-31: 0 failed system units, 0 failed user units. Network/DNS/Bluetooth/audio services OK.

## RULES FOR ANY AI HELPING

- User is a beginner: one copy-paste command at a time, say what success looks like.
- Target is always `/etc/nixos#tonelico`, never `#tonelico-nix`.
- Build before switch. Never switch a failed build. Broken after switch: `sudo nixos-rebuild switch --rollback`. No login screen: boot older generation from systemd-boot menu.
- Live config: `/etc/nixos`. Git backup: `/home/aesc/nixos-config` (branch `main` → github.com/Roshrak/nixos-config). `/etc/nixos` also has a local-only repo on `master`.
- Never copy `hardware-configuration.nix` between machines. Each host has `nixos/hosts/<name>/`.
- Only ONE `services.udev.extraRules` block exists in `configuration.nix` — merge new udev rules into it.
- Preserve Mango lines: `env=QT_IM_MODULES,wayland;fcitx`, `env=XMODIFIERS,@im=fcitx`, `exec-once=fcitx5 -d`.
- No secrets in the repo; commit scripts scan for them. Never bypass or force-push.
- Don't scan `/`, `/nix/store`, browser data, or `.git/objects`. Don't rebuild unless config actually changed.

## STATE RIGHT NOW (after audit + repair, 2026-08-31)

- Laptop healthy. Audit found 0 critical problems; fixed 3 high + 9 medium maintenance-script flaws (wrong Git staging paths, false SUCCESS, unsafe backups, overlapping runs, Chromium/Niri cleanup, secret-scan fail-open).
- NixOS config unchanged, `flake.lock` unchanged, no build/switch/commit/push performed in the repair session.
- `/home/aesc/nixos-config` `main` == `origin/main` at `2bdb63a`, with reviewed UNCOMMITTED changes: script repairs, obsolete `toggle-desktop-look` files removed, one live Niri theme-state snapshot. That's the expected 1 warning in the health check.
- Full detail: `~/baby-step/state/audit-2026-08-31.txt` (permanent) and `~/baby-step/state/last-maintenance.txt` (latest action, overwritten per run). Logs: `~/baby-step/logs`.

## DEFERRED / KNOWN

- Chromium runs `--password-store=basic` (possible unencrypted saved passwords). Owner unsure if the feature is used; needs keyring migration before changing.
- SMART data needs sudo; not checked.
- Harmless boot noise: ACPI warnings, duplicate DBus names, greeter DRM retries. Ignore unless symptoms appear.

## NEXT STEPS FOR A FUTURE SESSION

1. `~/baby-step/check-system.sh` → expect "Failed checks: 0; warnings: 1" (uncommitted Git).
2. With user approval, commit + push pending repo changes via `~/baby-step/update-and-push.sh` (it shows the diff and requires typing PUSH).
3. Then normal update via `~/baby-step/update-system.sh`.
- Repaired scripts were live-tested in `--check-only`, snapshot, and lock paths. NOT yet end-to-end tested after repairs: real flake update, build, switch, commit, push.

## COMMANDS

- `~/baby-step/check-system.sh` — health (exit 0 clean / 1 warnings / 2 failures)
- `~/baby-step/update-system.sh` — update; `update-and-push.sh` — update + Git
- `~/baby-step/rebuild-system.sh` — rebuild only; `backup-config.sh` — local snapshot
- Beginner card: `~/baby-step/system-summary.txt`
