{
  description = "Acer laptop NixOS 26.05 with Mango and Noctalia v5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Keep the base system on the supported 26.05 channel while tracking the
    # newer Codex CLI independently. This avoids a broad system upgrade just
    # to receive Codex fixes.
    codex-nixpkgs.url = "github:NixOS/nixpkgs/master";
    mango.url = "github:mangowm/mango";
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
    lotus.url = "github:LotusInputMethod/fcitx5-lotus";
    niri.url = "github:epireyn/niri-flake";          # NEW - Phase 5
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    }; 
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = inputs@{ nixpkgs, mango, noctalia, ... }:
    let
      lib = nixpkgs.lib;
      hostRoot = ./hosts;
      hostEntries = builtins.readDir hostRoot;

      # A host becomes a flake configuration when its directory contains both
      # host.nix (small metadata) and hardware-configuration.nix (generated on
      # that physical machine). Templates and documentation are ignored.
      hostKeys = builtins.attrNames (lib.filterAttrs
        (name: type:
          type == "directory"
          && builtins.pathExists (hostRoot + "/${name}/host.nix")
          && builtins.pathExists
            (hostRoot + "/${name}/hardware-configuration.nix"))
        hostEntries);

      mkHost = hostKey:
        let
          hostPath = hostRoot + "/${hostKey}";
          host = import (hostPath + "/host.nix");
          codexPackage = inputs.codex-nixpkgs.legacyPackages.${host.system}.codex;
          hostModule = hostPath + "/default.nix";
          extraModules = host.extraModules or [ ];
        in
        lib.nameValuePair hostKey (lib.nixosSystem {
          system = host.system;
          specialArgs = { inherit inputs host; };
          modules = [
            (hostPath + "/hardware-configuration.nix")
            hostModule
            ({ ... }: {
              # Codex is intentionally sourced from the dedicated pinned
              # input above instead of upgrading all NixOS packages.
              nixpkgs.overlays = [
                (_final: _prev: { codex = codexPackage; })
              ];
            })
            mango.nixosModules.mango
            ./comic-mono.nix
            noctalia.nixosModules.default
            inputs.noctalia-greeter.nixosModules.default
            inputs.lotus.nixosModules.fcitx5-lotus
            ./apps-and-lotus.nix
            ./claude-code.nix
            ./desktop/plasma.nix      # KDE Plasma 6 second session
            ./desktop/niri.nix        # Niri third session
            ./desktop/sway.nix        # Sway + Noctalia v5 fourth session
            ./configuration.nix
            ({ ... }: {
              networking.hostName = host.hostName;
            })
          ] ++ extraModules;
        });
    in
    {
      nixosConfigurations = builtins.listToAttrs (map mkHost hostKeys);
    };

  nixConfig = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };
}
