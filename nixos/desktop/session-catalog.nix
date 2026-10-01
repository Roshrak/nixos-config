{ config, lib, pkgs, ... }:

let
  waylandNames = [ "mango" "niri" "sway" "plasma" "hyprland" "gnome" ];
  waylandPackages = lib.filter (
    package: lib.any (name: builtins.elem name waylandNames) (package.providedSessions or [ ])
  ) config.services.displayManager.sessionPackages;
  packagePaths = lib.concatStringsSep " " (map toString waylandPackages);
  xfceSessionPackages = lib.filter (
    package: builtins.pathExists "${package}/share/xsessions/xfce.desktop"
  ) config.services.displayManager.sessionPackages;
  xfcePackagePaths = lib.concatStringsSep " " (map toString xfceSessionPackages);

  dmSessionsShare = pkgs.runCommand "tonelico-curated-desktop-sessions" {
    meta.priority = 1;
  } ''
    mkdir -p "$out/share/wayland-sessions" "$out/share/xsessions"

    for name in mango niri sway plasma hyprland gnome; do
      source=""
      for package in ${packagePaths}; do
        candidate="$package/share/wayland-sessions/$name.desktop"
        if [ -f "$candidate" ]; then
          source="$candidate"
          break
        fi
      done
      if [ -z "$source" ]; then
        echo "Required Wayland session $name.desktop was not provided by pinned nixpkgs/modules" >&2
        exit 1
      fi

      case "$name" in
        mango)
          sed 's|^Exec=.*|Exec=/run/current-system/sw/bin/mango-session-guarded|' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
        niri)
          sed 's|^Exec=.*|Exec=/run/current-system/sw/bin/niri-session-guarded|' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
        sway)
          sed 's|^Exec=.*|Exec=/run/current-system/sw/bin/sway-session-guarded|' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
        plasma)
          sed 's|^Exec=.*|Exec=/run/current-system/sw/bin/plasma-session-guarded|' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
        hyprland)
          sed 's|^Exec=.*|Exec=/run/current-system/sw/bin/hyprland-session-guarded|' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
        gnome)
          sed 's|^Exec=|Exec=/run/current-system/sw/bin/desktop-session-client GNOME wayland -- |' "$source" \
            > "$out/share/wayland-sessions/$name.desktop"
          ;;
      esac
    done

    hide_session() {
      kind="$1"
      name="$2"
      case "$kind" in
        wayland) directory="$out/share/wayland-sessions" ;;
        x11) directory="$out/share/xsessions" ;;
        *) exit 2 ;;
      esac
      cat > "$directory/$name.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=Hidden session ($name)
    Exec=false
    Hidden=true
    NoDisplay=true
    EOF
    }

    # Keep alternate sessions out of Noctalia Greeter even when their package
    # is linked into the system profile alongside the selected session.
    for name in hyprland-uwsm xfce-wayland; do
      hide_session wayland "$name"
    done

    xfce_source=""
    for package in ${xfcePackagePaths}; do
      candidate="$package/share/xsessions/xfce.desktop"
      if [ -f "$candidate" ]; then
        xfce_source="$candidate"
        break
      fi
    done
    if [ -z "$xfce_source" ]; then
      echo "The evaluated XFCE session package did not provide xsessions/xfce.desktop" >&2
      exit 1
    fi
    cp "$xfce_source" "$out/share/xsessions/xfce.desktop"
  '';
in
{
  environment.systemPackages = [ dmSessionsShare ];

  assertions = [
    {
      assertion = builtins.length waylandNames == 6;
      message = "The curated Noctalia Greeter Wayland session allowlist must contain exactly six sessions.";
    }
    {
      assertion = xfceSessionPackages != [ ];
      message = "The evaluated XFCE session package must provide the native NixOS X11 session entry.";
    }
    {
      assertion = !config.services.displayManager.gdm.enable
        && !config.services.displayManager.sddm.enable
        && !config.services.xserver.displayManager.lightdm.enable;
      message = "greetd + Noctalia Greeter is the only permitted display-manager stack for this host.";
    }
    {
      assertion = !config.programs.hyprland.withUWSM;
      message = "Only the plain Hyprland session is permitted; UWSM must remain disabled.";
    }
  ];
}
