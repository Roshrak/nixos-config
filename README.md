# Tonelico reproducible NixOS configuration

This repository backs up and deploys the NixOS system used by `aesc`. The
canonical deployable flake is in [`nixos/`](nixos/), not at repository root.

The repository is arranged for multiple machines:

```text
nixos/
  flake.nix                     shared flake and automatic host discovery
  flake.lock                    pinned input versions
  configuration.nix            portable system configuration
  apps-and-lotus.nix            shared applications and Fcitx5 Lotus
  desktop/                      Mango, Niri, Sway, Hyprland, Plasma, GNOME, and XFCE integration
  fonts/                        declarative local fonts
  hosts/
    tonelico/
      host.nix                  flake name, hostname, platform, user metadata
      hardware-configuration.nix generated for this physical installation
      default.nix               Tonelico-only Intel/hardware tuning
dotfiles/                       selected restorable user configuration
baby-step/                      beginner-safe maintenance tools
scripts/bootstrap-nixos.sh      safe deployment and installation helper
docs/MIGRATION-INSTALL.md       complete beginner migration guide
```

Start with [`docs/MIGRATION-INSTALL.md`](docs/MIGRATION-INSTALL.md). The intended
workflow is:

```text
clone repository
→ generate/import hardware-configuration.nix
→ run scripts/bootstrap-nixos.sh
→ build/switch or nixos-install
```

The current host remains intentionally unusual:

- hostname: `tonelico-nix`
- flake attribute: `tonelico`
- explicit target: `/etc/nixos#tonelico`

Never assume the hostname is also the flake attribute.

Maintain an installed machine using `~/baby-step/check-system.sh`,
`~/baby-step/rebuild-system.sh`, or `~/baby-step/update-system.sh`.
Use `~/baby-step/update-and-push.sh --backup-only` to publish the already-active
configuration without upgrading inputs or packages. The default invocation
updates the system first. Both publication modes request snapshot and push
review, reject existing staged work, and scan the complete staged tree.

The two older `scripts/update-system-and-push*.sh` entry points now forward to
the maintained baby-step tool; their old `--sync-only` option means
`--backup-only`. Historical rice/command guides are reference records and do
not supersede the current maintenance commands.

Clipboard history, catalog/cache metadata, maintenance logs, receipts, and
recovery copies are excluded from publication. Custom Hermes backup is limited
to the manifest-approved code and unit files; authentication state is excluded.
Read [`docs/CUSTOM-SERVICE-RESTORE.md`](docs/CUSTOM-SERVICE-RESTORE.md) for the
restore boundary and [`docs/PUBLICATION-REVIEW.md`](docs/PUBLICATION-REVIEW.md)
for the latest publication review. Automated build/parser checks do not prove
desktop, portal, microphone, or reboot behavior.
