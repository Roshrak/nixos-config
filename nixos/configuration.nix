{ config, pkgs, inputs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
};
  nix.registry.nixpkgs.flake = inputs.nixpkgs;
  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;

  # Reuse the existing 1 GiB EFI partition shared with Arch.
  # Two NixOS boot generations keeps the shared ESP from filling too quickly.
  boot.loader.systemd-boot = {
    enable = true;
    editor = false;
    configurationLimit = 5;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  time.timeZone = "Asia/Ho_Chi_Minh";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  users.users.aesc = {
    isNormalUser = true;
    uid = 1000;
    description = "Aesc";
    extraGroups = [ "wheel" "networkmanager" "video" "render" "audio" "input" ];
  };
  security.sudo.wheelNeedsPassword = true;

  # Mango compositor and a graphical login screen.
  programs.mango.enable = true;
  services.displayManager.sddm.enable = false;

programs.noctalia-greeter = {
  enable = true;

  settings = {
    appearance.hide_logo = true;
    cursor = {
      theme = "Bibata-Modern-Ice";
      size = 24;
      path = "${pkgs.bibata-cursors}/share/icons";
    };

    keyboard.layout = "us";
    idle.timeout = 300;
  };
};
  services.xserver.desktopManager.runXdgAutostartIfNone = true;

  services.udev.extraRules = ''
    # RDMCTMZT 36b0:3002 — prevent fake gamepad detection.
    SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="36b0", ATTRS{idProduct}=="3002", ENV{ID_INPUT_JOYSTICK}=="1", ENV{ID_INPUT_JOYSTICK}=""
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="36b0", ATTRS{idProduct}=="3009", MODE="0660", GROUP="users", TAG+="uaccess"
  '';

  # Noctalia supplies the bar, launcher, notifications, control center,
  # wallpaper, lock screen, OSD, tray, and clipboard history.
  programs.noctalia = {
    enable = true;
    recommendedServices.enable = true;
    systemd.enable = false; # Started once by Mango instead.
  };

  # Portable graphics and firmware defaults. CPU/GPU vendor-specific settings
  # live under hosts/<flake-attribute>/default.nix.
  hardware.enableRedistributableFirmware = true;
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    TERMINAL = "kitty";
  };

  # Laptop services.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
  services.fwupd.enable = true;
  services.fstrim.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.upower.enable = true;
  services.power-profiles-daemon.enable = true;

  # Audio.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # File manager integration, removable drives, and encrypted Secret Service.
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.accounts-daemon.enable = true;
  programs.dconf.enable = true;

  # Vietnamese input with Fcitx5 + Unikey. XDG autostart above starts it in Mango.
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [ qt6Packages.fcitx5-unikey fcitx5-gtk ];
    };
  };
  programs.gdk-pixbuf.modulePackages = [ pkgs.librsvg ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  programs.nix-ld.enable = true;
  xdg.portal.enable = true;
  services.flatpak.enable = true;

  # Chromium policy: never nag about being the default browser.
  # Declarative (was a manual /etc/chromium/... copy) so reinstalls keep it.
  environment.etc."chromium/policies/managed/default-browser.json".text = ''
    {
      "DefaultBrowserSettingEnabled": false
    }
  '';

  environment.systemPackages = with pkgs; [
    # Main desktop apps
    kitty
    nautilus
    file-roller
    seahorse
    gnome-disk-utility
    gparted
    mpv

    # Desktop controls and Wayland tools
    pavucontrol
    playerctl
    brightnessctl
    wl-clipboard
    grim
    slurp
    swappy
    wlr-randr
    wev
    wayland-utils
    libnotify
    kdePackages.fcitx5-configtool

    # Driver verification
    mesa-demos
    vulkan-tools
    libva-utils

    # Everyday CLI tools
    git
    curl
    wget
    unzip
    zip
    python3
    nodejs
    nano
    neovim
    fastfetch
    btop
    ripgrep
    fd
    jq
    tree
    pciutils
    usbutils
    smartmontools
    nvme-cli
    xdg-utils
    codex

    # Icons
    adwaita-icon-theme
    papirus-icon-theme
  ];

  system.stateVersion = "26.05";
  services.cloudflare-warp.enable = true;
}
