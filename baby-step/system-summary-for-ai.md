# Tonelico NixOS — Current AI Context

Updated: 2026-09-28 19:59 (Asia/Ho_Chi_Minh). No passwords, keys, tokens, cookies,
or machine identifiers are intentionally recorded here.

## System

- Host: `tonelico-nix`; NixOS flake attribute: `tonelico`; use `/etc/nixos#tonelico`.
- NixOS 26.05.20260910.d58a46e (Yarara), kernel 7.2.4, x86_64.
- Hardware: Acer Swift SFG16-72, Intel Core Ultra 5 125U, 15 GiB RAM.
- Root filesystem: 468 GiB total, 92 GiB used, 352 GiB available. `/boot`: 1 GiB,
  55 MiB used, 968 MiB free. The EFI partition is shared; never reformat it.
- Locale/timezone: en_US.UTF-8 / Asia/Ho_Chi_Minh.
- Login manager: greetd + Noctalia Greeter; SDDM is intentionally off.
- Audio/input: PipeWire + WirePlumber; Fcitx5 with Vietnamese input configured.

## Current and fallback generations

- Active runtime/system profile: generation 116, store path
  `/nix/store/jv3mfc1hhsj4c7778ly1n4fpl4zsf4rk-nixos-system-tonelico-nix-26.05.20260910.d58a46e`.
- Immediate previous system generation: 115, store path
  `/nix/store/7c60alkvrr9al3r0nw1938v1vg47g7nq-nixos-system-tonelico-nix-26.05.20260910.d58a46e`.
- Generation 114 remains because it is the booted system and the named fallback;
  store path `/nix/store/hwc4q227zz30k1b4i8hc3518f82s3b5r-nixos-system-tonelico-nix-26.05.20260910.d58a46e`.
- Systemd-boot default is `nixos-generation-116.conf`. The separate fallback
  profile is `/nix/var/nix/profiles/system-profiles/fallback` (generation 1); its
  entry is `/boot/loader/entries/nixos-fallback-generation-1.conf`, and its GC
  root is `/nix/var/nix/gcroots/nixos-fallback-generation`. Both still target 114.
- `/run/booted-system` is still generation 114; `/run/current-system` is 116.
  Generation 116 has not been reboot/cold-boot tested yet. Generation 113 and its
  boot entry were removed after verifying it was not current, booted, or fallback.
- The obsolete `pre-multisession` profile/root/entry had already been replaced
  with the named fallback in the previous maintenance run.

## System packages and Nix profiles

- VLC 3.0.23 is installed declaratively as a system package. Its Nix runtime
  closure includes FFmpeg, VLC plugins, `live555`, and libva. The Intel iHD
  VA-API driver initializes successfully and reports H.264, HEVC, and VP9 profiles.
- `agy` (Antigravity CLI 1.2.12) and `opencode` (1.18.30) are system packages.
  The system pins the exact Antigravity flake revision used by the prior user
  package, avoiding a silent downgrade to the other input's version 1.2.0.
- `nix profile list --json` reports an empty active Nix user profile. The old
  profile history generations were removed after confirming the system package
  resolves to the same Antigravity CLI store path/version.

## Desktop/session state

- Available sessions in the configuration: Mango, Niri, Sway, KDE Plasma, XFCE.
- Current session: Niri / Wayland (`XDG_CURRENT_DESKTOP=niri`).
- Latest observed session variables: `XDG_CURRENT_DESKTOP=niri` and
  `DESKTOP_SESSION` empty.
- The audit remediation refreshed Niri portal services and added XFCE session
  scoping for XApp/notification units. Screenshot, ScreenCast, Secret and all
  cross-desktop portal response tests remain deferred/unverified.
- At the post-switch health check, greetd was active and no failed system or user
  units were listed. Idle `libvirtd.service` is stopped; its sockets remain active
  so the daemon is socket-activated when virtualization is used.

## Update/push tool and repository state

- `~/baby-step/update-system.sh --check-only` passed its command, disk-space, and
  flake-target preflight.
- `~/baby-step/update-and-push.sh --check-only` now passes all checks. It shows
  the one local commit ahead of origin (`1dcf6c8`) and asks for `CONTINUE` before
  running the system update; its separate `PUSH` confirmation still gates commit
  and push. No update, commit, or push was run during this task.
- `/home/aesc/nixos-config` still has uncommitted work. Detailed audit reports
  and logs remain in `~/baby-step` and are intentionally excluded from the
  repository snapshot; selected summaries and tools are copied by the backup.

## Cleanup and memory snapshot 2026-09-28

- Earlier cleanup removed system generations 83–112 and retained 114/113; this
  run pruned only obsolete generation 113, keeping 116 current, 115 previous,
  and 114 booted/fallback. Active profile generations are 114–116.
- This run's Nix GC removed 117 unreferenced store paths and freed 1.7 GiB.
  Regenerated Nix Git/tarball/fetch caches (~112 MiB) were verified as exact
  Trash targets and permanently removed; no other Trash entries were touched.
  Active Nix cache is 712 KiB (eval cache and flake registry). No Downloads,
  VM/ISO assets, or general application caches were cleaned.
- Final disk reading: `/` 92 GiB used / 352 GiB available; `/boot` 55 MiB used /
  968 MiB free.
- RAM reading: 15 GiB total, 2.5 GiB used, 12 GiB available; zram swap unused.
  The libvirt daemon is inactive while activation sockets remain listening; no
  other service was disabled because remaining large services are in active use.

## Remaining observations

- Generation 116 has not yet been reboot/cold-boot tested; `/run/booted-system`
  remains generation 114 until reboot. Generation 115 and the named generation
  114 fallback remain selectable.
- Portal tests and hardware/security policy work are deferred. The older audit
  record also documents microphone command exit status and USB4/ACPI/NVMe follow-up.
- Three five-desktop audit/remediation records are under `~/baby-step/reports/`.
  The current full snapshot is `~/baby-step/system-audit.md`.

## Safe operating notes

- Live config is `/etc/nixos`; repo backup is `/home/aesc/nixos-config`.
- Build and verify before activating future changes. If needed, use the boot menu
  for generation 115 or the named generation 114 fallback.
- Keep Mango's Fcitx integration (`QT_IM_MODULES`, `XMODIFIERS`, and its Fcitx
  startup) unless intentionally changing input-method behavior.
- Follow `~/baby-step/AGENTS.md` and `~/baby-step/AI-MAINTENANCE-RULES.md`.
- Commands: `check-system.sh`, `update-system.sh`, `update-and-push.sh`,
  `rebuild-system.sh`, and `backup-config.sh` are in `~/baby-step/`.
