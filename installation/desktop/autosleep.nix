{ config, lib, pkgs, ... }:

let
  hypridle = pkgs.hypridle;
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  autosleepLockSession = pkgs.writeShellApplication {
    name = "autosleep-lock-session";
    runtimeInputs = [ autosleep ];
    text = ''
      set -euo pipefail
      if [ -n "''${AUTOSLEEP_REAL_XDG_CONFIG_HOME:-}" ]; then
        export XDG_CONFIG_HOME="$AUTOSLEEP_REAL_XDG_CONFIG_HOME"
      fi
      exec ${autosleep}/bin/autosleep __idle-lock
    '';
  };
  autosleepDisplayOff = pkgs.writeShellApplication {
    name = "autosleep-display-off";
    runtimeInputs = [ autosleep ];
    text = ''
      set -euo pipefail
      if [ -n "''${AUTOSLEEP_REAL_XDG_CONFIG_HOME:-}" ]; then
        export XDG_CONFIG_HOME="$AUTOSLEEP_REAL_XDG_CONFIG_HOME"
      fi
      exec ${autosleep}/bin/autosleep __idle-display-off
    '';
  };
  autosleepDisplayOn = pkgs.writeShellApplication {
    name = "autosleep-display-on";
    runtimeInputs = [ config.programs.noctalia.package ];
    text = ''
      set -euo pipefail
      if [ -n "''${AUTOSLEEP_REAL_XDG_CONFIG_HOME:-}" ]; then
        export XDG_CONFIG_HOME="$AUTOSLEEP_REAL_XDG_CONFIG_HOME"
      fi
      exec noctalia msg dpms-on
    '';
  };
  autosleepIdleDaemon = pkgs.writeShellApplication {
    name = "autosleep-idle-daemon";
    runtimeInputs = [ pkgs.coreutils pkgs.jq config.programs.noctalia.package ];
    text = ''
      set -euo pipefail
      case "''${THEME_PROFILE:-}" in
        hyprland|niri|sway|mango) ;;
        *) exit 0 ;;
      esac
      config_home="''${XDG_CONFIG_HOME:-$HOME/.config}"
      policy="$config_home/autosleep/policy.json"
      [ -f "$policy" ] && [ ! -L "$policy" ] || exit 0
      mode="$(jq -er '.mode | select(. == "on" or . == "off")' "$policy")"
      [ "$mode" = on ] || exit 0
      config="$config_home/autosleep/hypridle.conf"
      [ -f "$config" ] && [ ! -L "$config" ] || {
        echo "autosleep-idle-daemon: managed Hypridle configuration is missing or linked" >&2
        exit 1
      }
      runtime_dir="''${XDG_RUNTIME_DIR:-}"
      [ -n "$runtime_dir" ] && [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || {
        echo "autosleep-idle-daemon: XDG_RUNTIME_DIR is missing or unsafe" >&2
        exit 1
      }
      runtime_owner="$(stat -c '%u:%a' -- "$runtime_dir")"
      [ "$runtime_owner" = "$(id -u):700" ] || {
        echo "autosleep-idle-daemon: XDG_RUNTIME_DIR owner/mode is unsafe" >&2
        exit 1
      }

      # Hypridle 0.1.7 requires its standard config path to exist even when
      # --config names another file. Give it a private XDG config tree whose
      # default file points at this managed config; never touch ~/.config/hypr.
      real_config_home="$config_home"
      private_config_home="$(mktemp -d "$runtime_dir/autosleep-xdg.XXXXXXXX")"
      chmod 0700 "$private_config_home"
      mkdir -m 0700 -- "$private_config_home/hypr"
      ln -s -- "$config" "$private_config_home/hypr/hypridle.conf"
      export AUTOSLEEP_REAL_XDG_CONFIG_HOME="$real_config_home"
      export XDG_CONFIG_HOME="$private_config_home"

      hypridle_pid=""
      cleanup() {
        rc=$?
        trap - EXIT TERM INT HUP
        if [ -n "$hypridle_pid" ] && kill -0 "$hypridle_pid" 2>/dev/null; then
          kill -TERM "$hypridle_pid" 2>/dev/null || true
          wait "$hypridle_pid" 2>/dev/null || true
        fi
        if [ -L "$private_config_home/hypr/hypridle.conf" ] \
          && [ "$(readlink -- "$private_config_home/hypr/hypridle.conf")" = "$config" ]; then
          rm -- "$private_config_home/hypr/hypridle.conf"
        fi
        rmdir -- "$private_config_home/hypr" 2>/dev/null || true
        rmdir -- "$private_config_home" 2>/dev/null || true
        exit "$rc"
      }
      stop_hypridle() {
        if [ -n "$hypridle_pid" ] && kill -0 "$hypridle_pid" 2>/dev/null; then
          kill -TERM "$hypridle_pid" 2>/dev/null || true
          wait "$hypridle_pid" 2>/dev/null || true
        fi
        exit 143
      }
      trap cleanup EXIT
      trap stop_hypridle TERM INT HUP
      ${hypridle}/bin/hypridle --config "$config" &
      hypridle_pid=$!
      wait "$hypridle_pid"
    '';
  };
  autosleep = pkgs.writeShellApplication {
    name = "autosleep";
    runtimeInputs = [
      python
      pkgs.glib
      pkgs.kdePackages.kconfig
      pkgs.qt6.qttools
      pkgs.xfconf
      pkgs.xset
      pkgs.systemd
      pkgs.xprintidle
      config.programs.noctalia.package
    ];
    text = ''
      exec ${python}/bin/python3 ${./autosleep.py} "$@"
    '';
  };
in
{
  # Machine inactivity and lid events must never put running work to sleep.
  # Manual power requests and the battery critical-action policy remain separate.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    IdleActionSec = "0";
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Keep the requested executable available from every enabled graphical session.
  environment.systemPackages = [
    autosleep
    autosleepLockSession
    autosleepDisplayOff
    autosleepDisplayOn
    autosleepIdleDaemon
  ];

  # Reconcile the persisted mode only when a graphical session starts. This is
  # a short oneshot; it does not own or stop applications in the session.
  systemd.user.services.autosleep-policy = {
    description = "Apply the persisted autosleep display policy";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${autosleep}/bin/autosleep apply";
    };
  };

  # Wayland idle timing is owned by Hypridle for all four Noctalia sessions.
  # Its generic ext-idle-notify listener ignores application inhibitors; the
  # guarded power-off callback checks that logind sees the session locked.
  # No suspend listener is configured.
  systemd.user.services.autosleep-idle = {
    description = "Enforce the persisted Wayland autosleep idle policy";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "THEME_PROFILE";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${autosleepIdleDaemon}/bin/autosleep-idle-daemon";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  # X11 uses its own input-idle watcher so a fixed DPMS timer cannot turn off
  # an unlocked screen. The watcher requests the native locker at 300 seconds,
  # verifies logind's LockedHint, then powers off at 305 seconds.
  systemd.user.services.autosleep-idle-x11 = {
    description = "Enforce lock-confirmed X11 autosleep display policy";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_SESSION_TYPE=x11";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${autosleep}/bin/autosleep __x11-idle-daemon";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  # Keep GNOME's native power manager from issuing its own inactivity or lid
  # suspend requests. autosleep owns only the session blank/lock delay.
  services.desktopManager.gnome.extraGSettingsOverrides = lib.mkAfter ''
    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-timeout=0
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-timeout=0
    sleep-inactive-battery-type='nothing'
  '';
}
