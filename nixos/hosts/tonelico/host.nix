{
  # The directory name is the flake attribute: /etc/nixos#tonelico.
  # The operating-system hostname is intentionally different.
  hostName = "tonelico-nix";
  system = "x86_64-linux";

  # The current desktop configuration contains intentional /home/aesc paths.
  primaryUser = "aesc";
  userUid = 1000;
  userGid = 100;

  # These modules are useful on this machine but are not forced onto every
  # future host. New hosts can opt in by adding paths to their own host.nix.
  extraModules = [
    ../../wave75-via.nix
    ../../windows-vm.nix
  ];
}
