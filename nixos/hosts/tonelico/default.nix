{ pkgs, ... }:

{
  # Acer Swift SFG16-72 / Intel Core Ultra 5 125U-specific tuning.
  # Keep vendor-specific settings here instead of in shared configuration.nix.
  hardware.cpu.intel.updateMicrocode = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    vpl-gpu-rt
    intel-compute-runtime
  ];
  services.xserver.videoDrivers = [ "modesetting" ];
  services.thermald.enable = true;

  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
}
