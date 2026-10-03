# KDE Plasma 6 (Wayland) as a second session beside MangoWC + Noctalia.
# Strictly additive: no existing Mango/Noctalia/greetd behaviour is altered.
{ pkgs, ... }:

{
  # ---- Plasma 6 desktop (Wayland session) ---------------------------------
  services.desktopManager.plasma6.enable = true;
  # SDDM deliberately NOT enabled: greetd + noctalia-greeter stays the login screen.

  # Plasma's lock screen authenticates via PAM service "kde", which only
  # exists when SDDM is enabled. Provide it so kscreenlocker works under greetd.
  security.pam.services.kde = { };

  # DrKonqi's package socket is available to the lingering user manager even
  # at the greeter. Its GUI launcher otherwise crashes while reporting a
  # non-Plasma crash before a display exists, recursively creating new dumps.
  # Keep systemd-coredump itself active; launch only Plasma's GUI reporter in
  # a Plasma session.
  systemd.user.services."drkonqi-coredump-launcher@" = {
    description = "Launch DrKonqi for a systemd-coredump crash in Plasma";
    unitConfig = {
      PartOf = "graphical-session.target";
      ConditionUser = "!@system";
      ConditionEnvironment = "THEME_PROFILE=kde";
    };
    serviceConfig = {
      WorkingDirectory = "%T";
      ExecStart = "${pkgs.kdePackages.drkonqi}/libexec/drkonqi-coredump-launcher";
      Slice = "app.slice";
      Restart = "no";
    };
  };

  # Noctalia Greeter session catalogue now lives in desktop/session-catalog.nix
  # and is an explicit 11-session allowlist.

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

  # Portal ownership is declared centrally in desktop/portals.nix using the
  # NixOS typed xdg.portal.config option. The evaluated Plasma config selects
  # KDE for desktop interfaces and KWallet for Secret; it does not own the
  # login manager and cannot override the per-session routes of other desktops.

  # Graphics, audio, networking, input method, keyring: intentionally absent -
  # all already configured system-wide in configuration.nix and shared by both
  # sessions (PipeWire, NetworkManager, BlueZ, iHD VA-API, fcitx5, gvfs, dconf).
  # File extraction does not need a display connection after session handoff.
  # Scope the platform to Baloo and its children; retain indexing policy.
  systemd.user.services.kde-baloo = {
    overrideStrategy = "asDropin";
    environment.QT_QPA_PLATFORM = "offscreen";
  };

}
