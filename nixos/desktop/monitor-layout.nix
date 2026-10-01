{ pkgs, ... }:

let
  mkKanshiConfig = desktop: pkgs.writeText "tonelico-kanshi-${desktop}.conf" ''
    # Keep the internal laptop panel to the right and place the external panel
    # to its left.  The dual-output profile must precede the internal-only one.
    profile {
      output HDMI-A-1 enable position 0,60
      output eDP-1 enable position 1920,0
      exec /run/current-system/sw/bin/desktop-main-pointer ${desktop}
    }

    profile {
      output eDP-1 enable position 0,0
      exec /run/current-system/sw/bin/desktop-main-pointer ${desktop}
    }
  '';
in
{
  # Kanshi uses the Wayland output-management protocol and reacts only to
  # output changes; it does not poll.  Start it explicitly from each compatible
  # compositor with a session-specific config path.
  environment.systemPackages = [ pkgs.kanshi ];

  environment.etc."kanshi/mango.conf".source = mkKanshiConfig "mango";
  environment.etc."kanshi/niri.conf".source = mkKanshiConfig "niri";
  environment.etc."kanshi/sway.conf".source = mkKanshiConfig "sway";
  environment.etc."kanshi/hyprland.conf".source = mkKanshiConfig "hyprland";
}
