{ pkgs, inputs, ... }: {
  # Allow unfree packages for Claude Code
  nixpkgs.config.allowUnfree = true;

  # Install the package from the flake input
  environment.systemPackages = [
    inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
