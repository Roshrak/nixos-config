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

  # Fix for PixArt PIXA3848 I2C Touchpad boot race condition.
  # On cold boot, the touchpad power/controller takes a moment to stabilize,
  # causing the initial i2c_hid_acpi descriptor probe to fail with error -22
  # ("unexpected long global item"). Reloading i2c_hid_acpi if missing fixes it.
  systemd.services.pixart-touchpad-fix = {
    description = "Fix PixArt PIXA3848 I2C Touchpad Initialization";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = pkgs.writeShellScript "pixart-touchpad-fix" ''
        if ! grep -q "PIXA3848.*Touchpad" /proc/bus/input/devices; then
          echo "PIXA3848 touchpad not detected in input devices. Reloading i2c_hid_acpi..."
          ${pkgs.kmod}/bin/modprobe -r i2c_hid_acpi || true
          sleep 0.5
          ${pkgs.kmod}/bin/modprobe i2c_hid_acpi
        else
          echo "PIXA3848 touchpad is already initialized."
        fi
      '';
    };
  };

  # Ensure the touchpad is re-checked upon resuming from sleep/suspend
  powerManagement.resumeCommands = ''
    if ! grep -q "PIXA3848.*Touchpad" /proc/bus/input/devices; then
      ${pkgs.kmod}/bin/modprobe -r i2c_hid_acpi || true
      sleep 0.5
      ${pkgs.kmod}/bin/modprobe i2c_hid_acpi
    fi
  '';
}
