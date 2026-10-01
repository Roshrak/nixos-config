{ lib, pkgs, ... }:

let
  clipboardIndicatorUuid = "clipboard-indicator@tudmotu.com";
  windowRulesUuid = "tonelico-window-rules@aesc";
  workspaceBindings = lib.concatMapStringsSep "\n" (n: ''
    switch-to-workspace-${n}=['<Super>${n}']
    move-to-workspace-${n}=['<Shift><Super>${n}']
  '') (map toString (lib.range 1 9));
  favoriteAppBindings = lib.concatMapStringsSep "\n" (n: ''
    switch-to-application-${n}=[]
  '') (map toString (lib.range 1 9));
  customCommands = [
    { name = "Terminal"; command = "kitty"; binding = "<Super>Return"; }
    { name = "Files"; command = "nautilus"; binding = "<Super>e"; }
    { name = "Browser"; command = "chromium"; binding = "<Super>z"; }
    { name = "Settings"; command = "gnome-control-center"; binding = "<Super>comma"; }
    { name = "Fcitx toggle"; command = "fcitx5-remote -t"; binding = "<Alt>z"; }
    { name = "Logout menu"; command = "gnome-session-quit --logout-dialog"; binding = "<Super><Shift>e"; }
  ];
  customPaths = lib.genList (i: "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${toString i}/") (builtins.length customCommands);
  customCommandDconfSettings = lib.listToAttrs (lib.imap0 (i: item: {
    name = "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${toString i}";
    value = {
      inherit (item) name command binding;
    };
  }) customCommands);
  windowRules = pkgs.stdenvNoCC.mkDerivation {
    pname = "tonelico-gnome-window-rules";
    version = "1";
    src = ./gnome-window-rules;
    nativeBuildInputs = [ pkgs.glib ];
    dontBuild = true;
    installPhase = ''
      extensionDir="$out/share/gnome-shell/extensions/${windowRulesUuid}"
      mkdir -p "$extensionDir/schemas"
      install -m 644 metadata.json "$extensionDir/metadata.json"
      install -m 644 extension.js "$extensionDir/extension.js"
      install -m 644 schemas/org.gnome.shell.extensions.tonelico-window-rules.gschema.xml "$extensionDir/schemas/"
      ${pkgs.glib.dev}/bin/glib-compile-schemas --strict "$extensionDir/schemas"
    '';
  };
in

{
  services.desktopManager.gnome.enable = true;
  # GNOME supplies a session package; greetd + Noctalia Greeter stay in charge.
  services.displayManager.gdm.enable = lib.mkForce false;

  # Use the existing shared applications instead of installing GNOME's full
  # duplicate application collection. The Shell, Settings and core session
  # services remain supplied by the GNOME desktop module.
  services.gnome.core-apps.enable = false;
  services.gnome.gnome-initial-setup.enable = false;

  # Native GNOME styling and nine fixed desktops. Super+Space is reserved for
  # the existing launcher muscle memory rather than GNOME's input-source
  # switcher; Fcitx keeps its own Alt+Z toggle.
  services.desktopManager.gnome.extraGSettingsOverridePackages = [
    pkgs.gsettings-desktop-schemas
    pkgs.gnome-shell
    pkgs.gnome-settings-daemon
  ];
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.desktop.interface]
    color-scheme='prefer-dark'
    gtk-theme='Adwaita-dark'
    icon-theme='Adwaita'
    cursor-theme='Bibata-Modern-Ice'
    cursor-size=24
    font-name='Noto Sans 10'
    monospace-font-name='Comic Mono 11.5'

    [org.gnome.desktop.background]
    picture-uri='file:///home/aesc/Pictures/Wallpapers/wallpaperflare.com_wallpaper.jpg'
    picture-uri-dark='file:///home/aesc/Pictures/Wallpapers/wallpaperflare.com_wallpaper.jpg'

    [org.gnome.desktop.wm.preferences]
    num-workspaces=9
    button-layout=':minimize,maximize,close'

    [org.gnome.mutter]
    center-new-windows=true
    auto-maximize=false

    # NixOS sets a GNOME-context default of dynamic workspaces; override that
    # context explicitly so Super+1..9 always maps to a fixed workspace set.
    [org.gnome.mutter:GNOME]
    dynamic-workspaces=false

    [org.gnome.mutter.keybindings]
    toggle-tiled-left=[]
    toggle-tiled-right=[]

    [org.gnome.desktop.wm.keybindings]
    close=['<Super>q']
    toggle-fullscreen=['<Super>f']
    toggle-maximized=['<Super>m']
    minimize=[]
    maximize=[]
    unmaximize=[]
    switch-input-source=[]
    switch-input-source-backward=[]
    switch-applications=['<Alt>Tab', '<Super>Tab']
    switch-applications-backward=['<Shift><Alt>Tab', '<Shift><Super>Tab']
    move-to-workspace-left=['<Shift><Super><Control>Left']
    move-to-workspace-right=['<Shift><Super><Control>Right']
    switch-to-workspace-left=['<Super><Control>Left']
    switch-to-workspace-right=['<Super><Control>Right']
    ${workspaceBindings}

    [org.gnome.settings-daemon.plugins.media-keys]
    screensaver=['<Super>Escape']
    custom-keybindings=${builtins.toJSON customPaths}

    [org.gnome.shell.keybindings]
    toggle-overview=['<Super>space', '<Super>o']
    toggle-message-tray=[]
    focus-active-notification=[]
    screenshot=['<Super>Print']
    screenshot-window=['<Control>Print']
    show-screenshot-ui=['Print']
    # Shell's default favorite-app bindings otherwise claim the same keys as
    # the numbered workspace bindings above.
    ${favoriteAppBindings}
  '';

  # Relocatable GSettings shortcuts need actual dconf values; schema default
  # overrides are not consumed by GNOME's media-keys service for these paths.
  # Keep the records system-declarative but editable by the user (no locks).
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = customPaths;
        };
        "org/gnome/shell" = {
          enabled-extensions = [ clipboardIndicatorUuid windowRulesUuid ];
        };
        "org/gnome/shell/extensions/clipboard-indicator" = {
          toggle-menu = [ "<Super>v" ];
          open-at-cursor = true;
        };
      } // customCommandDconfSettings;
    }
  ];

  # GNOME's module only defaults to IBus. Keep the already configured Lotus
  # engine and Fcitx5 input method authoritative.
  i18n.inputMethod.type = lib.mkForce "fcitx5";
  i18n.inputMethod.enable = lib.mkForce true;

  environment.gnome.excludePackages = with pkgs; [
    epiphany
    gnome-music
    gnome-weather
    gnome-maps
    gnome-contacts
    gnome-calendar
    gnome-clocks
    gnome-calculator
    gnome-console
    gnome-text-editor
    showtime
    yelp
  ];

  # Used by the shared slogout command for a reliable native GNOME logout.
  environment.systemPackages = [
    pkgs.gnome-session
    pkgs.gnomeExtensions.clipboard-indicator
    windowRules
  ];
}
