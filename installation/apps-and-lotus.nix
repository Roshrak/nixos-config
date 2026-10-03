{ pkgs, inputs, ... }:

{
  environment.sessionVariables = {
    BROWSER = "chromium";
    XCURSOR_THEME = "Bibata-Modern-Ice";
    XCURSOR_SIZE = "24";
    LV2_PATH = "/run/current-system/sw/lib/lv2";
  };

  environment.systemPackages = with pkgs; [
    zenity
    gh
    fzf
    gcc
    tree-sitter
    lazygit
                        (chromium.override {
  commandLineArgs = [
    "--password-store=basic"
  ];
})
    bibata-cursors
    xdg-user-dirs

    # Audio processing & DSP
    easyeffects
    lsp-plugins
    calf
    zam-plugins
    mda_lv2

    # Minecraft
    prismlauncher
    jdk8
    jdk17
    jdk21
    mangohud

    # Requested applications
    obs-studio
    (discord.override {
      commandLineArgs = "--ozone-platform=x11";
    })
    obsidian
    pkgs.libreoffice
    telegram-desktop

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
