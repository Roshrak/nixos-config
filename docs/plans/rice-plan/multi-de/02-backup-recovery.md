# Phase 1 — Backup & Recovery

## What exists now

| Layer | Artifact | Created |
|---|---|---|
| File config | `backups/backup-baseline-2026-08-26.tar.gz` (2.6G) | 2026-08-26 |
| System config | git repo at `/etc/nixos` (already had 2 commits from KDE addition) | — |
| OS-level | NixOS generations (boot menu: pick previous generation) | continuous |
| Log | `backups/BACKUPS.log` (append per backup) | 2026-08-26 |

Tarball contents: `~/.config`, `~/.local/share` (**excl. Steam, PrismLauncher**),
`~/.local/bin`, `/etc/nixos`. Caches (Chromium/Code/GPU) excluded.

## How to restore

### User configs
```sh
tar -xzf ~/rice\ plan/multi-de/backups/backup-baseline-2026-08-26.tar.gz \
    -C / --absolute-names --transform 's|^etc/nixos|tmp/restored-nixos|' \
    home/aesc/.config /home/aesc/.local/share home/aesc/.local/bin
```
Simpler targeted restore of one file/dir:
```sh
tar -tzf <backup> | grep '<name>'          # find it
tar -xzf <backup> -C / home/aesc/.config/<path>
```

### System (NixOS)
- Previous generation: select older entry in boot menu, or
  `sudo nixos-rebuild switch --rollback`
- Config source rollback: `cd /etc/nixos && git checkout <commit>` then rebuild

## ⚠️ Pending manual step (needs your sudo password)

The `/etc/nixos` repo is root-owned; I cannot commit as `aesc`. Run once:

```sh
sudo sh -c 'cd /etc/nixos && \
  printf "result\n*.bak*\n*.before-*\n" > .gitignore && \
  git add -A && git commit -m "baseline before multi-DE integration (portal split, plasma+greetd fixes)"'
```

Do this **before** the niri phase lands its first system change.

## Before each future phase

```sh
~/rice\ plan/multi-de/make-backup.sh pre-phase-N   # replace N with phase number
sudo sh -c 'cd /etc/nixos && git add -A && git commit -m "checkpoint before phase N"'
```

## Post-change regression gate (every phase)

1. Log out of current session → login greeter appears
2. Mango+Noctalia: bar renders, launcher opens (SUPER+space), notification test
   (`notify-send test`), screenshot works, wallpaper intact
3. KDE: login OK, lock/unlock (META+L), open file dialog in Kate/KWrite (portal OK)
4. Any failure → fix = revert generation or restore tarball file(s); retest 2–4;
   never continue while a fallback is broken
