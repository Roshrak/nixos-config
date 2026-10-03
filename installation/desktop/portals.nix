{ lib, ... }:

{
  # Use the NixOS portal module's typed config so these files replace the
  # upstream per-DE defaults cleanly instead of concatenating duplicate
  # [preferred] sections into /etc.
  xdg.portal.config = {
    mango = {
      default = [ "gtk" ];
      "org.freedesktop.impl.portal.ScreenCast" = "wlr";
      "org.freedesktop.impl.portal.Screenshot" = "wlr";
      "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
    };

    niri = {
      # The pinned Niri module defaults to GNOME then GTK. Keep GTK as the
      # general UI backend and choose GNOME specifically for capture.
      default = lib.mkForce [ "gtk" ];
      "org.freedesktop.impl.portal.Access" = "gtk";
      "org.freedesktop.impl.portal.FileChooser" = lib.mkForce "gtk";
      "org.freedesktop.impl.portal.Notification" = "gtk";
      "org.freedesktop.impl.portal.ScreenCast" = "gnome";
      "org.freedesktop.impl.portal.Screenshot" = "gnome";
      "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
    };

    sway = {
      # Keep the upstream Sway GTK + wlroots routing and add the shared
      # Secret Service portal explicitly.
      "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
    };

    hyprland = {
      default = [ "gtk" ];
      "org.freedesktop.impl.portal.GlobalShortcuts" = "hyprland";
      "org.freedesktop.impl.portal.ScreenCast" = "hyprland";
      "org.freedesktop.impl.portal.Screenshot" = "hyprland";
      "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
    };

    kde = {
      default = [ "kde" ];
      "org.freedesktop.impl.portal.Secret" = "kwallet";
    };

    gnome = {
      default = [ "gnome" "gtk" ];
      "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
    };

    xfce = {
      default = [ "gtk" ];
      "org.freedesktop.impl.portal.Settings" = "xapp";
      "org.freedesktop.impl.portal.Screenshot" = "xapp";
      "org.freedesktop.impl.portal.Secret" = "xapp-gnome-keyring";
    };

  };
}
