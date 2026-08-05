{
  description = "Acer laptop NixOS 26.05 with Mango and Noctalia v5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    mango.url = "github:mangowm/mango";
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
    lotus.url = "github:LotusInputMethod/fcitx5-lotus";
  };

  outputs = inputs@{ nixpkgs, mango, noctalia, ... }: {
    nixosConfigurations.tonelico = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./hardware-configuration.nix
        mango.nixosModules.mango
        noctalia.nixosModules.default
        inputs.lotus.nixosModules.fcitx5-lotus
        ./apps-and-lotus.nix
        ./configuration.nix
      ];
    };
  };

  nixConfig = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };
}
