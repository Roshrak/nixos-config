# Sway Wayland compositor + Noctalia v5 shell as an independent session.
# Strictly additive: preserves existing Mango, Niri, Plasma, and GNOME sessions.
{ pkgs, ... }:

{
  # ---- Sway Compositor -----------------------------------------------------
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraPackages = with pkgs; [
      xwayland-satellite
    ];
  };

}
