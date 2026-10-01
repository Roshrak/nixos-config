{ config, lib, pkgs, ... }:

let
  gnomeGSettingsOverrides = pkgs.gnome.nixos-gsettings-overrides.override {
    inherit (config.services.desktopManager.gnome)
      extraGSettingsOverrides
      extraGSettingsOverridePackages
      favoriteAppsOverride;
  };
  # Place the startup pointer on the laptop panel where compositor IPC allows
  # a safe one-shot warp. Niri centers the cursor on its focus-at-startup
  # output natively, and its Kanshi hook repeats that on hotplug. All four
  # Wayland compositors use their compositor IPC rather than input injection.
  desktopMainPointer = pkgs.writeShellScriptBin "desktop-main-pointer" ''
    set -u
    JQ=${pkgs.jq}/bin/jq
    SLEEP=${pkgs.coreutils}/bin/sleep
    mode="''${1:-}"

    case "$mode" in
      sway|hyprland)
        attempt=0
        while [ "$attempt" -lt 20 ]; do
          if [ "$mode" = sway ]; then
            json="$(/run/current-system/sw/bin/swaymsg -t get_outputs 2>/dev/null || true)"
            coords="$(printf '%s' "$json" | "$JQ" -r '
              .[] | select(.name == "eDP-1" and .active) |
              [.rect.x, .rect.y, .rect.width, .rect.height] | @tsv' 2>/dev/null || true)"
          else
            json="$(/run/current-system/sw/bin/hyprctl -j monitors 2>/dev/null || true)"
            coords="$(printf '%s' "$json" | "$JQ" -r '
              .[] | select(.name == "eDP-1" and ((.disabled // false) == false)) |
              [(.x + (.width / (.scale // 1)) / 2 | floor),
               (.y + (.height / (.scale // 1)) / 2 | floor)] | @tsv' 2>/dev/null || true)"
          fi
          if [ -n "$coords" ]; then
            if [ "$mode" = sway ]; then
              read -r x y width height <<< "$coords"
              /run/current-system/sw/bin/swaymsg \
                "seat seat0 cursor set $((x + width / 2)) $((y + height / 2))" \
                >/dev/null 2>&1 || true
            else
              read -r x y <<< "$coords"
              /run/current-system/sw/bin/hyprctl dispatch movecursor "$x" "$y" \
                >/dev/null 2>&1 || true
            fi
            exit 0
          fi
          attempt=$((attempt + 1))
          "$SLEEP" 0.15
        done
        ;;
      niri)
        # Niri's focus-monitor IPC moves the cursor onto the chosen output.
        # Retry briefly because Kanshi may invoke us while the compositor is
        # still initializing after login or a hotplug event.
        attempt=0
        while [ "$attempt" -lt 20 ]; do
          if /run/current-system/sw/bin/niri msg action focus-monitor eDP-1 >/dev/null 2>&1; then
            exit 0
          fi
          attempt=$((attempt + 1))
          "$SLEEP" 0.15
        done
        ;;
      mango)
        MMSG=/run/current-system/sw/bin/mmsg
        attempt=0
        while [ "$attempt" -lt 20 ]; do
          if "$MMSG" get monitor eDP-1 >/dev/null 2>&1; then
            # Moving to the external output and back forces Mango's native
            # warpcursor policy to center the pointer on eDP-1. If HDMI is not
            # connected the first dispatch is a harmless no-op.
            "$MMSG" dispatch focusmon,HDMI-A-1 >/dev/null 2>&1 || true
            "$MMSG" dispatch focusmon,eDP-1 >/dev/null 2>&1 || true
            exit 0
          fi
          attempt=$((attempt + 1))
          "$SLEEP" 0.15
        done
        ;;
      *)
        echo "usage: desktop-main-pointer <sway|hyprland|niri|mango>" >&2
        exit 2
        ;;
    esac
  '';

  desktopSessionClient = pkgs.writeShellScriptBin "desktop-session-client" ''
    set -u
    if [ "$#" -lt 4 ]; then
      echo "usage: desktop-session-client GNOME wayland [--] <command> [args...]" >&2
      exit 2
    fi

    desktop="$1"
    session_type="$2"
    shift 2
    # Wayland session entries use -- to separate the session wrapper from Exec.
    if [ "$1" = -- ]; then shift; fi
    [ "$#" -gt 0 ] || { echo "missing session command" >&2; exit 2; }

    case "$desktop" in
      GNOME) ;;
      *) echo "unsupported desktop session: $desktop" >&2; exit 2 ;;
    esac
    [ "$session_type" = wayland ] || exit 2

    # Remove only cross-session display and desktop markers. Preserve the
    # shared user D-Bus, runtime directory, audio, Fcitx and application state.
    unset WAYLAND_DISPLAY NIRI_SOCKET SWAYSOCK \
      MANGO_INSTANCE_SIGNATURE HYPRLAND_INSTANCE_SIGNATURE \
      KDE_FULL_SESSION KDE_SESSION_VERSION KDE_SESSION_UID KDE_SESSION_VT \
      KDE_APPLICATIONS_AS_SCOPE GNOME_DESKTOP_SESSION_ID GNOME_SETUP_DISPLAY \
      MATE_DESKTOP_SESSION_ID CINNAMON_VERSION LXQT_SESSION_CONFIG \
      LXQT_SESSION_ID AWESOME_CONF THEME_PROFILE NOCTALIA_STATE_HOME \
      NOCTALIA_CONFIG_HOME KITTY_CONFIG_DIRECTORY QT_QPA_PLATFORMTHEME
    unset DISPLAY XAUTHORITY NIXOS_OZONE_WL MOZ_ENABLE_WAYLAND

    export XDG_CURRENT_DESKTOP="$desktop"
    export XDG_SESSION_DESKTOP="$desktop"
    export XDG_SESSION_TYPE="$session_type"
    export DESKTOP_SESSION="$desktop"
    unset NIX_GSETTINGS_OVERRIDES_DIR
    case "$desktop" in
      GNOME)
        export NIX_GSETTINGS_OVERRIDES_DIR="${gnomeGSettingsOverrides}/share/gsettings-schemas/nixos-gsettings-overrides/glib-2.0/schemas"
        ;;
    esac

    session_vars=(XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION)
    [ -n "''${DISPLAY:-}" ] && session_vars+=(DISPLAY)
    [ -n "''${XAUTHORITY:-}" ] && session_vars+=(XAUTHORITY)
    [ -n "''${WAYLAND_DISPLAY:-}" ] && session_vars+=(WAYLAND_DISPLAY)
    [ -n "''${NIX_GSETTINGS_OVERRIDES_DIR:-}" ] && session_vars+=(NIX_GSETTINGS_OVERRIDES_DIR)

    # Clear display-bound state even if the previous compositor exited without
    # running its logout hook. Never restart the user manager or kill apps.
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    if [ "$desktop" = GNOME ]; then
      # GNOME 50 aborts when a previous desktop left these user targets
      # active. Stop only the graphical-session targets at this login
      # boundary; keep the shared user manager and unrelated apps running.
      /run/current-system/sw/bin/systemctl --user stop \
        graphical-session.target graphical-session-pre.target || exit 1
    fi
    /run/current-system/sw/bin/systemctl --user import-environment \
      "''${session_vars[@]}" 2>/dev/null || true
    /run/current-system/sw/bin/dbus-update-activation-environment --systemd \
      "''${session_vars[@]}" 2>/dev/null || true

    if [ "$desktop" != GNOME ]; then
      /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true
    fi
    on_exit() {
      rc=$?
      trap - EXIT TERM INT HUP
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
      exit "$rc"
    }
    trap on_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    "$@"
    exit $?
  '';

  hyprlandSessionGuarded = pkgs.writeShellScriptBin "hyprland-session-guarded" ''
    set -u
    for arg in "$@"; do
      case "$arg" in
        -c|--config|--config=*|--config-file|--config-file=*|-c?*)
          echo "hyprland-session-guarded uses the declarative config; rejected: $arg" >&2
          exit 2
          ;;
      esac
    done
    unset WAYLAND_DISPLAY DISPLAY XAUTHORITY NIRI_SOCKET SWAYSOCK \
      MANGO_INSTANCE_SIGNATURE HYPRLAND_INSTANCE_SIGNATURE \
      KDE_FULL_SESSION KDE_SESSION_VERSION KDE_SESSION_UID KDE_SESSION_VT \
      GNOME_DESKTOP_SESSION_ID GNOME_SETUP_DISPLAY MATE_DESKTOP_SESSION_ID \
      CINNAMON_VERSION LXQT_SESSION_CONFIG LXQT_SESSION_ID AWESOME_CONF \
      NIX_GSETTINGS_OVERRIDES_DIR
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    export XDG_CURRENT_DESKTOP=Hyprland
    export XDG_SESSION_DESKTOP=Hyprland
    export XDG_SESSION_TYPE=wayland
    export DESKTOP_SESSION=hyprland
    export THEME_PROFILE=hyprland
    export NOCTALIA_CONFIG_HOME="$HOME/.config/theme-profiles/hyprland/config-home"
    export NOCTALIA_STATE_HOME="$HOME/.local/state/theme-profiles/hyprland"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/hyprland"
    export QT_QPA_PLATFORMTHEME=qt6ct

    on_exit() {
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    }
    trap on_exit EXIT TERM INT HUP

    vars=(XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION
      THEME_PROFILE NOCTALIA_CONFIG_HOME NOCTALIA_STATE_HOME
      KITTY_CONFIG_DIRECTORY QT_QPA_PLATFORMTHEME)
    /run/current-system/sw/bin/systemctl --user import-environment "''${vars[@]}" 2>/dev/null || true
    /run/current-system/sw/bin/dbus-update-activation-environment --systemd "''${vars[@]}" 2>/dev/null || true

    /run/current-system/sw/bin/theme-profile-activate hyprland >/dev/null 2>&1 || true
    /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true
    /run/current-system/sw/bin/desktop-main-pointer hyprland >/dev/null 2>&1 &
    pointer_pid=$!
    /run/current-system/sw/bin/start-hyprland -- --config /etc/xdg/hypr/hyprland.lua "$@"
    rc=$?
    kill -TERM "$pointer_pid" 2>/dev/null || true
    wait "$pointer_pid" 2>/dev/null || true
    trap - EXIT
    on_exit
    exit "$rc"
  '';
in
{
  # GNOME's module disables NixOS's demo agent globally because GNOME Shell
  # supplies its own. The six other retained sessions keep the demo agent.
  services.geoclue2.enableDemoAgent = lib.mkForce true;
  systemd.user.services.geoclue-agent.wantedBy = lib.mkForce [ ];

  # GNOME's schema override is set only for the GNOME session by its bridge.
  environment.sessionVariables.NIX_GSETTINGS_OVERRIDES_DIR = lib.mkForce null;

  # Cloudflare WARP ships this tray helper as a default.target user service.
  # During an X11-to-Wayland handoff it may exit with the old DISPLAY before
  # the new compositor imports its display values; immediate retries exhaust
  # systemd's start limit before the new session is ready.
  systemd.user.services.warp-taskbar = {
    overrideStrategy = "asDropin";
    unitConfig = {
      StartLimitIntervalSec = "30s";
      StartLimitBurst = 4;
    };
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "5s";
    };
  };

  environment.systemPackages = [
    desktopSessionClient
    desktopMainPointer
    hyprlandSessionGuarded
  ];
}
