{ pkgs, inputs, ... }: {
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
