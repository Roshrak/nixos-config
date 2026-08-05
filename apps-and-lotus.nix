{ pkgs, inputs, ... }:

{
  environment.sessionVariables = {
    BROWSER = "chromium";
    XCURSOR_THEME = "Bibata-Modern-Ice";
    XCURSOR_SIZE = "24";
  };

  environment.systemPackages = with pkgs; [
    chromium
    bibata-cursors
    xdg-user-dirs

    # Minecraft
    prismlauncher
    jdk8
    jdk17
    jdk21
    mangohud

    # Requested applications
    obs-studio
    discord
    obsidian
    pkgs.libreoffice

    # Breeze cursor and the gsettings command
    glib
  ];

  programs.steam.enable = true;
  programs.gamemode.enable = true;

  services.fcitx5-lotus = {
    enable = true;
    users = [ "aesc" ];
    package =
      inputs.lotus.packages.${pkgs.stdenv.hostPlatform.system}.fcitx5-lotus;
  };
}
