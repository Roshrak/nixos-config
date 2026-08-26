# KDE Plasma 6 (Wayland) as a second session beside MangoWC + Noctalia.
# Strictly additive: no existing Mango/Noctalia/greetd behaviour is altered.
{ config, lib, pkgs, ... }:

{
  # ---- Plasma 6 desktop (Wayland session) ---------------------------------
  services.desktopManager.plasma6.enable = true;
  # SDDM deliberately NOT enabled: greetd + noctalia-greeter stays the login screen.

  # Plasma's lock screen authenticates via PAM service "kde", which only
  # exists when SDDM is enabled. Provide it so kscreenlocker works under greetd.
  security.pam.services.kde = { };

  # ---- Expose registered sessions to noctalia-greeter ----------------------
  # The greeter scans /run/current-system/sw/share/wayland-sessions. Link every
  # session registered through services.displayManager.sessionPackages there,
  # so the picker lists BOTH Mango and Plasma instead of relying on the
  # greeter's implicit Mango fallback.
  environment.systemPackages = [
    (pkgs.runCommand "dm-sessions-share" { }
      ''
        mkdir -p $out/share/wayland-sessions
        for f in ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions/*.desktop; do
          ln -s "$f" $out/share/wayland-sessions/
        done
      '')
  ];

  # ---- Minimal application set ---------------------------------------------
  # Remove obvious duplicates; kitty / nautilus / file-roller / seahorse /
  # mpv remain the global tools. Core Plasma pieces (Dolphin, Spectacle,
  # KRunner, System Settings, Info Center) are kept.
  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    konsole      # terminal -> kitty
    kate         # editor   -> neovim / nano
    gwenview     # images   -> existing workflow
    okular       # PDFs     -> existing workflow
    elisa        # music    -> mpv
    ark          # archives -> file-roller
    khelpcenter  # docs     -> web
    discover     # store/updater not wanted
  ];

  # ---- Portals (documentation-in-config; no functional override) ------------
  # xdg.portal.enable is already true (configuration.nix) with gtk/wlr/
  # gnome-keyring portals, and services.desktopManager.plasma6.enable adds
  # kdePackages.xdg-desktop-portal-kde automatically. Backend choice is made
  # per session via XDG_CURRENT_DESKTOP:
  #   Mango  ("mango:wlroots") -> /etc/xdg/xdg-desktop-portal/mango-portals.conf
  #                               (default=gtk, ScreenCast/Screenshot=wlr) - untouched
  #   Plasma ("KDE")           -> kde-portals.conf shipped by xdg-desktop-portal-kde
  # No generic portals.conf exists, so neither session can grab the other's backends.

  # Graphics, audio, networking, input method, keyring: intentionally absent -
  # all already configured system-wide in configuration.nix and shared by both
  # sessions (PipeWire, NetworkManager, BlueZ, iHD VA-API, fcitx5, gvfs, dconf).
}
