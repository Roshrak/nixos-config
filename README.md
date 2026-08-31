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
  desktop/                      shared Mango, Plasma, and Niri integration
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
