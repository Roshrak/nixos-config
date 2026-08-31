{
  description = "Acer laptop NixOS 26.05 with Mango and Noctalia v5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
          hostModule = hostPath + "/default.nix";
          extraModules = host.extraModules or [ ];
        in
        lib.nameValuePair hostKey (lib.nixosSystem {
          system = host.system;
          specialArgs = { inherit inputs host; };
          modules = [
            (hostPath + "/hardware-configuration.nix")
            hostModule
            mango.nixosModules.mango
            ./comic-mono.nix
            noctalia.nixosModules.default
            inputs.noctalia-greeter.nixosModules.default
            inputs.lotus.nixosModules.fcitx5-lotus
            ./apps-and-lotus.nix
            ./claude-code.nix
            ./desktop/plasma.nix      # KDE Plasma 6 second session
            ./desktop/niri.nix        # Niri third session
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
