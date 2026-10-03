{ pkgs, inputs, lib, ... }:
let
  system = pkgs.stdenv.hostPlatform.system;
  hermesEnv = inputs.hermes-agent.packages.${system}.messaging.passthru.hermesVenv;
  gatewayPath = lib.makeBinPath [
    hermesEnv
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.util-linux
    pkgs.git
    pkgs.nodejs
    pkgs.python3
    pkgs.curl
  ] + ":/run/current-system/sw/bin:/home/aesc/.nix-profile/bin:/home/aesc/.local/bin";
in {
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.antigravity-cli
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
    inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.messaging
  ];

  # The upstream user unit points to /bin/kill, which does not exist on NixOS.
  # Emit only an ExecReload drop-in and retain the user's existing gateway unit.
  systemd.user.services.hermes-gateway = {
    overrideStrategy = "asDropin";
    # ExecReload is list-valued in systemd. Reset the home unit's invalid
    # /bin/kill entry before installing the Nix store executable.
    serviceConfig.ExecReload = [
      ""
      "${pkgs.util-linux}/bin/kill -USR1 $MAINPID"
    ];
  };
}
