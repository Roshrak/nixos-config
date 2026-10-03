# Exact overview chord, handled within each session's native input boundary.
{ pkgs, ... }:
let
  xfceMouseConfig = pkgs.writeText "xfce-overview-mouse.conf" ''
    "${pkgs.xfdashboard}/bin/xfdashboard --toggle"
      Shift + Mod4 + b:2
  '';
  xfceMouseAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-overview-mouse.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Overview mouse shortcut
    Comment=Super+Shift+middle click opens the XFCE overview
    Exec=${pkgs.xbindkeys}/bin/xbindkeys -n -f ${xfceMouseConfig}
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  xfceOverviewAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-overview.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=XFCE window overview
    Comment=Keep the overview ready for its keyboard and mouse shortcuts
    Exec=${pkgs.xfdashboard}/bin/xfdashboard --daemonize
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
in {
  # KWin's script API only registers keyboard shortcuts; use its native
  # pointer shortcut to invoke the same existing Overview QAction.
  nixpkgs.overlays = [ (final: prev: {
    kdePackages = prev.kdePackages.overrideScope (_kfinal: kprev: {
      kwin = kprev.kwin.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/plugins/overview/overvieweffect.cpp \
            --replace-fail 'overviewAction->setAutoRepeat(false);' \
            'overviewAction->setAutoRepeat(false); effects->registerPointerShortcut(Qt::MetaModifier | Qt::ShiftModifier, Qt::MiddleButton, overviewAction);'
        '';
      });
    });
    # Mutter filters Wayland client events before Shell stage callbacks. Reuse
    # the real toggle-overview handler there, including lock/mode and inhibitor
    # checks, rather than pretending a stage-only extension is a global grab.
    mutter = prev.mutter.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./overview/gnome-overview-pointer.patch ];
    });
  }) ];
  environment.systemPackages = [ pkgs.xfdashboard pkgs.xbindkeys xfceMouseAutostart xfceOverviewAutostart ];
}
