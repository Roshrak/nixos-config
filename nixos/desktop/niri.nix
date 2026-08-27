# Niri Wayland compositor — third independent session (Phase 5).
#
# Scope: adds niri + its session-specific pieces. Touches nothing owned by
# Mango/Noctalia-v5 or KDE:
#   * polkit agent that niri-flake would register user-wide is disabled here;
#     the niri session spawns lxqt-policykit itself via config.kdl.
#   * portals are selected per-session via /etc/xdg/xdg-desktop-portal/
#     niri-portals.conf (XDG_CURRENT_DESKTOP=niri); Mango/KDE confs untouched.
#
# Two-step install (per upstream binary-cache recommendation):
#   rebuild 1: programs.niri.enable = false   -> cache wired, nothing new runs
#   rebuild 2: programs.niri.enable = true    -> session appears in greeter
{ inputs, lib, pkgs, ... }:

{
  imports = [ inputs.niri.nixosModules.niri ];

  # Two-step install completed; session active.
  programs.niri.enable = true;

  # No generated config here: ~/.config/niri/config.kdl is hand-maintained
  # and read directly by niri at session start (hot-reload).

  # Upstream escape hatch: stop the flake's globally-reachable KDE polkit agent.
  systemd.user.services.niri-flake-polkit.enable = lib.mkForce false;

  environment.systemPackages = with pkgs; [
    xwayland-satellite        # X11 bridge; auto-used by niri >= 25.08
    lxqt.lxqt-policykit       # polkit agent owned by the niri session only
    adw-gtk3                  # GTK identity of the niri session
    papirus-icon-theme        # icon identity of the niri session
    xdg-desktop-portal-gnome  # screencast portal for niri sessions
  ];

  # Per-session portal selection (overrides the global portals.conf only when
  # XDG_CURRENT_DESKTOP=niri). FileChooser left on default -> nautilus.
  environment.etc."xdg/xdg-desktop-portal/niri-portals.conf".text = ''
    [preferred]
    default=gtk;
    org.freedesktop.impl.portal.ScreenCast=gnome;
    org.freedesktop.impl.portal.Screenshot=gnome;
    org.freedesktop.impl.portal.Secret=gnome-keyring;
  '';

  # Session registration for noctalia-greeter is automatic: the module adds
  # niri.desktop to services.displayManager.sessionPackages, which the
  # existing dm-sessions-share package in desktop/plasma.nix links into the
  # greeter's scan path.
}
