{ pkgs, ... }:

{
  services.xserver.desktopManager.mate = {
    enable = true;
    enableWaylandSession = false;
  };

  # Keep Marco, panel, control center, Caja, native screensaver, notification
  # daemon and mate-polkit. Drop only duplicate end-user applications.
  environment.mate.excludePackages = with pkgs; [
    atril
    engrampa
    eom
    mate-calc
    mate-terminal
    pluma
    mate-user-guide
  ];
}
