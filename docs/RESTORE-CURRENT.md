# RESTORE-CURRENT.md — what this repo snapshot contains (auto-generated)

Regenerated on every run of scripts/update-system-and-push-v3.3.sh.

## Snapshot contents

- nixos/                — full /etc/nixos set (*.nix + flake.lock + fonts),
                          hardware-configuration.nix excluded (machine-local)
- configuration.nix etc — root-level copies for convenience
- dotfiles/.config/     — mango, noctalia, kitty, fcitx5, nvim, fastfetch,
                          niri (config.kdl), theme-profiles (per-DE seeds),
                          plasma-workspace (KDE stale-session hook),
                          systemd/user (plasma gate drop-ins), kwinrc,
                          mimeapps.list
- dotfiles/.local/bin/  — apply-theme-profile, clean-stray-sessions,
                          niri-session-guarded, save-noctalia-profile,
                          noctalia-greeter-sync-smart, mango-animation,
                          steam, obs helpers
- docs/plans/rice-plan/ — the multi-DE isolation master plan + batteries
- scripts/              — this updater itself

## Restore outline (NEW machine, hardware may vary)

Hard requirements: NixOS, user named "aesc" (absolute /home/aesc paths are
baked into configs and seeds by design).

1. Install NixOS minimal on the target machine; create user aesc.
2. On the target, generate fresh hardware: `sudo nixos-generate-config`.
   KEEP that hardware-configuration.nix (never copy the old machine's).
3. Copy nixos/* -> /etc/nixos, root-level *.nix files into /etc/nixos,
   flake.lock included.
4. Adjust for the new hardware in /etc/nixos/configuration.nix:
   - Intel (default): keep hardware.cpu.intel.updateMicrocode,
     intel-media-driver, intel-compute-runtime, LIBVA_DRIVER_NAME = "iHD".
   - AMD: swap microcode for hardware.cpu.amd.updateMicrocode, replace
     intel-media-driver with amdvlk/libva-mesa-driver, set
     LIBVA_DRIVER_NAME = "radeontop"; remove intel-compute-runtime.
   - NVIDIA: add services.xserver.videoDrivers = [ "nvidia" ]; remove the
     iHD VA-API line (use nvidia-vaapi-driver instead).
   - videoDrivers is currently [ "modesetting" ].
5. Comment out machine-specific modules in flake.nix if absent on the
   target: ./windows-vm.nix (needs VFIO passthrough), ./wave75-via.nix
   (specific keyboard udev), ./comic-mono.nix (or keep fonts/, harmless).
6. Hostname: keep "tonelico" or sed it in flake.nix (nixosConfigurations.<name>).
7. Binary cache trust for the third-party flakes (noctalia cachix):
   sudo nixos-rebuild switch --flake /etc/nixos#tonelico --accept-flake-config
   (first switch only; or add the keys to nix.settings afterwards).
8. Copy dotfiles/.config/* -> ~/.config/ and dotfiles/.local/bin/* ->
   ~/.local/bin/ (chmod +x the bin helpers).
9. Wallpapers are NOT in this snapshot. Theme seeds reference
   ~/Pictures/Wallpapers/<3 files> — drop any wallpaper with those names
   (or re-pick wallpapers in-session; seeds stay isolated per DE via
   theme-profiles).
10. Chromium never nags about default browser: the policy is declarative in
    configuration.nix (environment.etc .../chromium/policies/managed/...).

## Session isolation invariants (must survive any restore)

- Theme seeds in ~/.config/theme-profiles/{mango,niri,kde}: wallpaper,
  kitty theme, gsettings, noctalia-state.toml; all auto_sync=false.
- apply-theme-profile is stamped at login: mango config.conf exec-once,
  niri config.kdl spawn-at-startup (absolute paths).
- niri.desktop Exec = /home/aesc/.local/bin/niri-session-guarded
  (patched by desktop/plasma.nix dm-sessions-share, meta.priority=1).
- Plasma user units gated by ~/.config/systemd/user/plasma-*.service.d/
  kde-gate.conf (ConditionEnvironment=XDG_CURRENT_DESKTOP=KDE).
- Chromium singleton cleanup via clean-stray-sessions in all 3 sessions.
