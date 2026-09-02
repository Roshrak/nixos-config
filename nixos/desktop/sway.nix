# Sway Wayland compositor + Noctalia v5 shell as an independent session.
# Strictly additive: preserves existing Mango, Niri, Plasma, and GNOME sessions.
{ pkgs, ... }:

{
  # ---- Sway Compositor -----------------------------------------------------
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraPackages = with pkgs; [
      lxqt.lxqt-policykit       # session-local polkit agent
      xwayland-satellite
    ];
  };

  # ---- Session-specific Portals --------------------------------------------
  # XDG_CURRENT_DESKTOP=sway uses GTK default and WLR for ScreenCast/Screenshot.
  environment.etc."xdg/xdg-desktop-portal/sway-portals.conf".text = ''
    [preferred]
    default=gtk
    org.freedesktop.impl.portal.ScreenCast=wlr
    org.freedesktop.impl.portal.Screenshot=wlr
    org.freedesktop.impl.portal.Secret=gnome-keyring
  '';
}
