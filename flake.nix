{
  description = "One-command Tonelico installation from the NixOS live USB";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      tools = with pkgs; [
        python3 git nix nixos-install-tools util-linux parted dosfstools
        e2fsprogs coreutils bash jq gnugrep gnused gawk findutils diffutils gnutar systemd
      ];
      installer = pkgs.writeShellApplication {
        name = "tonelico-install";
        runtimeInputs = tools;
        text = ''
          export PATH=${pkgs.lib.makeBinPath tools}:/run/current-system/sw/bin:/run/wrappers/bin
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
          if [[ "''${1:-}" == --plan ]] || [[ "''${1:-}" == --help ]] || [[ "$EUID" -eq 0 ]]; then
            exec ${pkgs.python3}/bin/python3 ${./scripts/install-everything.py} --revision ${pkgs.lib.escapeShellArg (self.rev or "")} "$@"
          fi
          exec /run/wrappers/bin/sudo -- ${pkgs.coreutils}/bin/env \
            PATH="$PATH" SSL_CERT_FILE="$SSL_CERT_FILE" NIX_SSL_CERT_FILE="$SSL_CERT_FILE" \
            ${pkgs.python3}/bin/python3 ${./scripts/install-everything.py} --revision ${pkgs.lib.escapeShellArg (self.rev or "")} "$@"
        '';
      };
    in {
      apps.${system}.install = { type = "app"; program = "${installer}/bin/tonelico-install"; };
      apps.${system}.default = self.apps.${system}.install;
      packages.${system}.default = installer;
    };
}
