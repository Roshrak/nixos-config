{ lib, pkgs, ... }:

let
  workspaceBindings = lib.concatMapStringsSep "\n" (n: ''
    switch-to-workspace-${n}=['<Super>${n}']
    move-to-workspace-${n}=['<Super><Shift>${n}']
  '') (map toString (lib.range 1 9));
  customCommands = [
    { name = "Terminal"; command = "kitty"; binding = "<Super>Return"; }
    { name = "Launcher"; command = "rofi -show drun"; binding = "<Super>space"; }
    { name = "Files"; command = "nautilus"; binding = "<Super>e"; }
    { name = "Browser"; command = "chromium"; binding = "<Super>z"; }
    { name = "Settings"; command = "cinnamon-settings"; binding = "<Super>s"; }
  ];
  customPaths = lib.genList (i: "/org/cinnamon/desktop/keybindings/custom-keybindings/custom${toString i}/") (builtins.length customCommands);
  customOverrides = lib.concatStringsSep "\n" (lib.imap0 (i: item: ''
    [org.cinnamon.desktop.keybindings.custom-keybinding:${builtins.elemAt customPaths i}]
    name='${item.name}'
    command='${item.command}'
    binding=['${item.binding}']
  '') customCommands);
in

{
  services.xserver.desktopManager.cinnamon.enable = true;
  services.cinnamon.apps.enable = false;

  # Pinned Cinnamon 6.6 is intentionally X11. Use Muffin's native pointer
  # placement and desktop-specific declarative GSettings defaults.
  services.xserver.desktopManager.cinnamon.extraGSettingsOverridePackages = [
    pkgs.cinnamon
    pkgs.cinnamon-desktop
    pkgs.muffin
    pkgs.gsettings-desktop-schemas
  ];
  services.xserver.desktopManager.cinnamon.extraGSettingsOverrides = ''
    [org.cinnamon.muffin]
    placement-mode='pointer'

    [org.cinnamon.desktop.wm.preferences]
    num-workspaces=9

    [org.cinnamon.desktop.interface]
    gtk-theme='Adwaita-dark'
    icon-theme='Adwaita'
    cursor-theme='Bibata-Modern-Ice'
    cursor-size=24
    font-name='Noto Sans 10'

    [org.gnome.desktop.interface]
    monospace-font-name='Comic Mono 11.5'

    [org.cinnamon.desktop.background]
    picture-uri='file:///home/aesc/Pictures/Wallpapers/wallpaperflare.com_wallpaper.jpg'
    picture-options='zoom'

    [org.cinnamon.desktop.keybindings.wm]
    close=['<Super>q']
    toggle-fullscreen=['<Super>f']
    toggle-maximized=['<Super>m']
    switch-to-workspace-left=['<Super><Control>Left']
    switch-to-workspace-right=['<Super><Control>Right']
    ${workspaceBindings}

    [org.cinnamon.desktop.keybindings]
    custom-list=${builtins.toJSON customPaths}
    ${customOverrides}
  '';

  # Cinnamon's module defaults a Slick greeter package, but does not need to
  # own the login manager. greetd remains the only enabled display manager.
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;
}
