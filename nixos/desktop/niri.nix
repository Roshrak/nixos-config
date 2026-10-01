# Niri Wayland compositor — third independent session (Phase 5).
#
# Scope: adds niri + its session-specific pieces. Touches nothing owned by
# Mango/Noctalia-v5 or KDE:
#   * polkit agent that niri-flake would register user-wide is disabled here;
#     the existing Noctalia shell is the sole polkit agent in this session.
#   * portals are selected centrally per-session in desktop/portals.nix.
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
    adw-gtk3                  # GTK identity of the niri session
    papirus-icon-theme        # icon identity of the niri session
    xdg-desktop-portal-gnome  # screencast portal for niri sessions
  ];

  # The session-catalog module curates Niri's greeter entry alongside the
  # other ten sessions; do not add a second entry here.
}
