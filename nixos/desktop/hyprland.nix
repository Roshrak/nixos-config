{ pkgs, ... }:

{
  # Exactly one plain Hyprland session.  UWSM is intentionally not used.
  programs.hyprland = {
    enable = true;
    withUWSM = false;
    xwayland.enable = true;
  };

  # The guarded session selects this declarative Hyprland Lua source.
  environment.etc."xdg/hypr/hyprland.lua".source = ./hyprland/hyprland.lua;

  # Use the existing Noctalia compositor shell and its own polkit agent.
  # programs.hyprland supplies the matching portal backend in this nixpkgs.
  environment.systemPackages = with pkgs; [
    xwayland-satellite
    wl-clipboard
    grim
    slurp
    satty
  ];
}
