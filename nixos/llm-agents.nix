{ pkgs, inputs, ... }: {
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [
    pkgs.aider-chat
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.antigravity-cli
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
  ];
}
