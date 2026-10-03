# Host profiles

Each immediate subdirectory represents one `nixosConfigurations` flake
attribute. For example, `hosts/tonelico/` produces `/etc/nixos#tonelico`.

Every real host directory contains:

- `host.nix`: hostname, architecture, primary-user deployment metadata, and
  optional extra modules.
- `hardware-configuration.nix`: generated on that physical installation with
  `nixos-generate-config`. This file is host-specific and should not be copied
  from a different computer.
- `default.nix`: optional CPU, GPU, disk, peripheral, or service tuning that is
  specific to this host. A new host starts with an empty module.

The flake discovers complete host directories automatically. Adding a directory
through `scripts/bootstrap-nixos.sh --create-host` is enough to create a new
flake attribute; no manual flake edit is required.

Hardware configuration files commonly contain filesystem UUIDs. Those UUIDs
are machine identifiers, not authentication secrets, and are required for a
reproducible reinstall. Never put passwords, tokens, private keys, Wi-Fi
credentials, or disk-encryption recovery keys in a host profile.
