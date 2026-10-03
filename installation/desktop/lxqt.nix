{ lib, pkgs, ... }:

let
  workspaceBindings = lib.concatMapStringsSep "\n" (n: ''
    <keybind key="W-${n}">
      <action name="GoToDesktop"><to>${n}</to></action>
    </keybind>
    <keybind key="W-S-${n}">
      <action name="SendToDesktop"><to>${n}</to><follow>yes</follow></action>
    </keybind>
  '') (map toString (lib.range 1 9));
  commonBindings = ''
    <keybind key="W-Return"><action name="Execute"><command>kitty</command></action></keybind>
    <keybind key="W-space"><action name="Execute"><command>rofi -show drun</command></action></keybind>
    <keybind key="W-e"><action name="Execute"><command>nautilus</command></action></keybind>
    <keybind key="W-z"><action name="Execute"><command>chromium</command></action></keybind>
    <keybind key="W-s"><action name="Execute"><command>lxqt-config</command></action></keybind>
    <keybind key="W-q"><action name="Close"/></keybind>
    <keybind key="W-f"><action name="ToggleFullscreen"/></keybind>
    <keybind key="W-m"><action name="ToggleMaximizeFull"/></keybind>
    <keybind key="W-Escape"><action name="Execute"><command>xfce4-screensaver-command --lock</command></action></keybind>
    <keybind key="W-S-e"><action name="Execute"><command>lxqt-leave</command></action></keybind>
    <keybind key="W-v"><action name="Execute"><command>xfce4-clipman-history</command></action></keybind>
    <keybind key="A-z"><action name="Execute"><command>fcitx5-remote -t</command></action></keybind>
    <keybind key="Print"><action name="Execute"><command>xfce4-screenshooter --region</command></action></keybind>
    <keybind key="W-Print"><action name="Execute"><command>xfce4-screenshooter --fullscreen</command></action></keybind>
    <keybind key="W-C-Left"><action name="GoToDesktop"><to>left</to><wrap>yes</wrap></action></keybind>
    <keybind key="W-C-Right"><action name="GoToDesktop"><to>right</to><wrap>yes</wrap></action></keybind>
  '';
  openboxBindings = pkgs.writeText "tonelico-lxqt-openbox-bindings.xml" ''
    ${workspaceBindings}
    ${commonBindings}
  '';
  openboxLxqtRc = pkgs.runCommand "openbox-lxqt-rc.xml" { } ''
    ${pkgs.gnused}/bin/sed \
      -e 's|<policy>Smart</policy>|<policy>UnderMouse</policy>|' \
      -e 's|<number>4</number>|<number>9</number>|' \
      -e '/^  <keybind key="W-e">$/,/^  <\/keybind>$/d' \
      ${pkgs.openbox}/etc/xdg/openbox/rc.xml > "$TMPDIR/openbox-base.xml"
    {
      ${pkgs.gnused}/bin/sed -n '/^<\/keyboard>/q;p' "$TMPDIR/openbox-base.xml"
      cat ${openboxBindings}
      ${pkgs.gnused}/bin/sed -n '/^<\/keyboard>/,$p' "$TMPDIR/openbox-base.xml"
    } > "$out"
  '';
in

{
  services.xserver.desktopManager.lxqt.enable = true;

  # LXQt 2.4 chooses its window manager through session.conf; explicitly use
  # Openbox with its native UnderMouse placement, rather than relying on the
  # package's dependency list to imply a runtime selection.
  environment.etc."xdg/lxqt/session.conf".text = ''
    [General]
    window_manager=openbox
    leave_confirmation=true

    [Mouse]
    cursor_theme=Bibata-Modern-Ice
    cursor_size=24
  '';
  environment.etc."xdg/openbox/rc.xml".source = openboxLxqtRc;

  # Keep PCManFM-Qt and lxqt-runner for desktop integration and muscle memory.
  environment.lxqt.excludePackages = with pkgs.lxqt; [
    qterminal
    lxqt-archiver
    lxqt-about
  ];

  environment.systemPackages = [ pkgs.openbox ];
}
