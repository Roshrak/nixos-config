# XFCE on native Xorg/X11 as an additive fallback desktop.
# greetd + Noctalia Greeter remain the login stack; all Wayland sessions stay enabled.
{ config, lib, pkgs, ... }:

let
  greeter = config.services.displayManager.noctalia-greeter;
  # Noctalia's upstream X11 helper gives startx explicit server arguments.
  # That makes startx bypass NixOS's xserverrc and, with it, the generated
  # xserver.conf containing the packaged input/video driver ModulePaths.
  # Keep the helper's VT/seat handling, but launch Xorg through a small server
  # wrapper carrying the evaluated NixOS X server arguments.
  nixosXserverArgs = lib.filter (
    arg: !lib.hasPrefix ":" arg
  ) config.services.xserver.displayManager.xserverArgs;
  nixosXserver = pkgs.writeShellScript "noctalia-nixos-xserver" ''
    exec ${config.services.xserver.displayManager.xserverBin} \
      ${lib.concatStringsSep " " nixosXserverArgs} "$@"
  '';
  xfceSessionClient = pkgs.writeShellScriptBin "xfce-session-client" ''
    set -u
    if [ "''${THEME_SESSION_LEASE_HELD:-0}" != 1 ]; then
      [ -n "''${XDG_RUNTIME_DIR:-}" ] || {
        echo "graphical session has no XDG_RUNTIME_DIR; refusing shared session changes" >&2
        exit 1
      }
      exec ${pkgs.coreutils}/bin/env THEME_SESSION_LEASE_HELD=1 \
        /run/current-system/sw/bin/theme-session-lease "$0" "$@"
    fi
    unset THEME_SESSION_LEASE_HELD
    /run/current-system/sw/bin/theme-session-admit || exit $?
    unset WAYLAND_DISPLAY NIRI_SOCKET SWAYSOCK \
      MANGO_INSTANCE_SIGNATURE HYPRLAND_INSTANCE_SIGNATURE \
      KDE_FULL_SESSION KDE_SESSION_VERSION KDE_SESSION_UID KDE_SESSION_VT \
      KDE_APPLICATIONS_AS_SCOPE GNOME_DESKTOP_SESSION_ID GNOME_SETUP_DISPLAY \
      MATE_DESKTOP_SESSION_ID CINNAMON_VERSION LXQT_SESSION_CONFIG \
      LXQT_SESSION_ID AWESOME_CONF THEME_PROFILE NOCTALIA_STATE_HOME \
      NOCTALIA_CONFIG_HOME KITTY_CONFIG_DIRECTORY QT_QPA_PLATFORMTHEME \
      NIX_GSETTINGS_OVERRIDES_DIR
    export XDG_CURRENT_DESKTOP="XFCE"
    export XDG_SESSION_DESKTOP="XFCE"
    export XDG_SESSION_TYPE="x11"
    export TONELICO_XAPP_PORTAL="1"

    session_vars=(XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE TONELICO_XAPP_PORTAL)
    [ -n "''${DISPLAY:-}" ] && session_vars+=(DISPLAY)
    [ -n "''${XAUTHORITY:-}" ] && session_vars+=(XAUTHORITY)
    /run/current-system/sw/bin/systemctl --user import-environment \
      "''${session_vars[@]}" 2>/dev/null || true
    /run/current-system/sw/bin/dbus-update-activation-environment --systemd \
      "''${session_vars[@]}" 2>/dev/null || true

    rc=0
    "$@" || rc=$?
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    exit "$rc"
  '';
  noctaliaXsession = pkgs.writeShellApplication {
    name = "noctalia-greeter-xsession";
    runtimeInputs = [ pkgs.xinit pkgs.coreutils ];
    text = ''
      if [ "$#" -lt 1 ]; then
        echo "usage: noctalia-greeter-xsession <session-command> [args...]" >&2
        exit 1
      fi

      # A Plasma logout ends greetd's login scope before KDE's systemd-user
      # services necessarily finish.  Do not start Xorg while stale KWin and
      # its Xwayland still own DRM/display :0; that produced a black XFCE
      # handoff on display :1.  This is a no-op after non-Plasma sessions.
      if ! /run/current-system/sw/bin/plasma-session-cleanup; then
        echo "Cannot start X11: the previous Plasma compositor is still running." >&2
        exit 1
      fi

      client="$1"
      shift
      resolved_client="$(command -v -- "$client" 2>/dev/null || true)"
      if [ -n "$resolved_client" ]; then
        client="$resolved_client"
      fi

      seat="''${XDG_SEAT:-seat0}"
      log_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/tonelico-session-startup"
      log_file="$log_dir/xfce.log"
      mkdir -p -- "$log_dir"
      {
        printf '\n[%s] XFCE X11 client start\n' "$(date --iso-8601=seconds)"
        printf 'client='
        printf '%q ' "$client" "$@"
        printf '\nDISPLAY=%s XAUTHORITY=%s\n' \
          "''${DISPLAY:+set}" "''${XAUTHORITY:+set}"
      } > "$log_file"

      set +e
      if [ -n "''${XDG_VTNR:-}" ]; then
        startx ${xfceSessionClient}/bin/xfce-session-client "$client" "$@" -- ${nixosXserver} \
          -seat "$seat" -keeptty "vt$XDG_VTNR" >> "$log_file" 2>&1
        rc=$?
      else
        startx ${xfceSessionClient}/bin/xfce-session-client "$client" "$@" -- ${nixosXserver} \
          -seat "$seat" -keeptty >> "$log_file" 2>&1
        rc=$?
      fi
      set -e
      printf 'startx exit=%s\n' "$rc" >> "$log_file"
      size="$(wc -c < "$log_file")"
      if [ "$size" -gt 262144 ]; then
        tail -c 262144 "$log_file" > "$log_file.tmp"
        mv "$log_file.tmp" "$log_file"
      fi
      exit "$rc"
    '';
  };
  preferredNoctaliaXsession = noctaliaXsession.overrideAttrs (_: {
    # Shadow the helper shipped by Noctalia Greeter in the merged system PATH.
    meta.priority = 0;
  });
  xfceToggleMaximize = pkgs.writeShellApplication {
    name = "xfce-toggle-maximize";
    runtimeInputs = [ pkgs.wmctrl ];
    text = ''
      exec wmctrl -r :ACTIVE: -b toggle,maximized_vert,maximized_horz
    '';
  };
  xfceLauncherTheme = pkgs.writeText "xfce-launcher.rasi" ''
    configuration {
      show-icons: true;
      drun-display-format: "{name}";
      drun-match-fields: "name,generic,keywords,categories";
      drun-reload-desktop-cache: true;
      matching: "fuzzy";
      sort: true;
      sorting-method: "fzf";
    }

    * {
      background: #1b1d23;
      background-alt: #292c34;
      foreground: #f2f2f3;
      muted: #a8abb3;
      accent: #858b98;
      selected: #3b3f4a;
      selected-foreground: #ffffff;
      font: "Comic Mono 11";
    }

    window {
      width: 620px;
      location: center;
      anchor: center;
      background-color: @background;
      border: 2px;
      border-color: @accent;
      border-radius: 14px;
      padding: 14px;
    }

    mainbox {
      background-color: @background;
      spacing: 12px;
      children: [ inputbar, listview ];
    }

    inputbar {
      background-color: @background-alt;
      border-radius: 10px;
      padding: 9px 12px;
      children: [ prompt, entry ];
    }

    prompt {
      background-color: transparent;
      text-color: @accent;
      padding: 0px 10px 0px 0px;
    }

    entry {
      background-color: transparent;
      text-color: @foreground;
      placeholder: "Search applications…";
      placeholder-color: @muted;
    }

    listview {
      background-color: transparent;
      columns: 2;
      lines: 5;
      fixed-height: true;
      fixed-columns: true;
      flow: vertical;
      spacing: 7px;
      scrollbar: false;
    }

    element {
      orientation: horizontal;
      background-color: transparent;
      text-color: @foreground;
      border-radius: 9px;
      padding: 8px;
      spacing: 10px;
      children: [ element-icon, element-text ];
    }

    element-icon {
      background-color: transparent;
      size: 30px;
    }

    element-text {
      background-color: transparent;
      vertical-align: 0.5;
      text-color: inherit;
    }

    element selected {
      background-color: @selected;
      text-color: @selected-foreground;
    }
  '';
  xfceLauncher = pkgs.writeShellApplication {
    name = "xfce-launcher";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.rofi
      pkgs.xdotool
    ];
    text = ''
      rofi \
        -no-config \
        -normal-window \
        -show drun \
        -display-drun Apps \
        -show-icons \
        -monitor -5 \
        -replace \
        -hover-select \
        -me-select-entry "" \
        -me-accept-entry MousePrimary \
        -theme ${xfceLauncherTheme} &
      rofi_pid=$!

      # A normal Rofi window stays mapped when XFWM transfers focus after an
      # outside click. Once this launcher has received focus, close only this
      # instance if another window becomes active. The brief recheck lets a
      # normal application selection finish before the launcher is dismissed.
      rofi_window=""
      attempts=0
      while [ "$attempts" -lt 100 ] && kill -0 "$rofi_pid" 2>/dev/null; do
        rofi_window="$(
          xdotool search --pid "$rofi_pid" --class '^Rofi$' 2>/dev/null \
            | head -n 1 || true
        )"
        [ -n "$rofi_window" ] && break
        attempts=$((attempts + 1))
        sleep 0.02
      done

      watcher_pid=""
      if [ -n "$rofi_window" ]; then
        (
          had_focus=false
          while kill -0 "$rofi_pid" 2>/dev/null; do
            active_window="$(xdotool getactivewindow 2>/dev/null || true)"
            if [ "$active_window" = "$rofi_window" ]; then
              had_focus=true
            elif [ "$had_focus" = true ]; then
              sleep 0.15
              active_window="$(xdotool getactivewindow 2>/dev/null || true)"
              visible_window="$(
                xdotool search --onlyvisible --pid "$rofi_pid" \
                  --class '^Rofi$' 2>/dev/null | head -n 1 || true
              )"
              if [ "$active_window" != "$rofi_window" ] \
                && [ "$visible_window" = "$rofi_window" ]; then
                kill "$rofi_pid" 2>/dev/null || true
                break
              fi
            fi
            sleep 0.05
          done
        ) &
        watcher_pid=$!
      fi

      rofi_status=0
      wait "$rofi_pid" || rofi_status=$?
      if [ -n "$watcher_pid" ]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
      fi
      exit "$rofi_status"
    '';
  };
  xfcePicom = pkgs.writeShellApplication {
    name = "xfce-picom";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.picom
      pkgs.xfconf
    ];
    text = ''
      # XFWM and Picom cannot own the X11 compositor selection together.
      # Disable only XFWM's XFCE-session compositor before Picom takes over.
      xfconf-query -c xfwm4 -p /general/use_compositing -s false
      sleep 0.3
      exec picom \
        --config /dev/null \
        --backend glx \
        --vsync \
        --corner-radius 14 \
        --detect-rounded-corners \
        --rounded-corners-exclude 'window_type = "dock"' \
        --rounded-corners-exclude 'window_type = "desktop"' \
        --unredir-if-possible
    '';
  };
  xfcePicomAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-picom.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=XFCE rounded-window compositor
    Comment=Provide consistent rounded application windows in XFCE only
    Exec=${xfcePicom}/bin/xfce-picom
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  xfceWindowGeometry = pkgs.writeShellApplication {
    name = "xfce-window-geometry";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.xdotool
      pkgs.xprop
      pkgs.xrandr
    ];
    text = ''
      if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
        echo "usage: xfce-window-geometry <window-id> <width> <height> [pointer|monitor-center]" >&2
        exit 1
      fi

      window_id="$1"
      requested_width="$2"
      requested_height="$3"
      placement_mode="''${4:-pointer}"

      pointer="$(xdotool getmouselocation --shell)"
      pointer_x="$(printf '%s\n' "$pointer" | sed -n 's/^X=\(-\?[0-9][0-9]*\)$/\1/p')"
      pointer_y="$(printf '%s\n' "$pointer" | sed -n 's/^Y=\(-\?[0-9][0-9]*\)$/\1/p')"

      monitor_width=""
      monitor_height=""
      monitor_x=""
      monitor_y=""
      while read -r width height offset_x offset_y; do
        if (( pointer_x >= offset_x && pointer_x < offset_x + width
              && pointer_y >= offset_y && pointer_y < offset_y + height )); then
          monitor_width="$width"
          monitor_height="$height"
          monitor_x="$offset_x"
          monitor_y="$offset_y"
          break
        fi
      done < <(
        xrandr --listmonitors | sed -nE \
          's|^[[:space:]]*[0-9]+:[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)/[0-9]+x([0-9]+)/[0-9]+([+-][0-9]+)([+-][0-9]+).*|\1 \2 \3 \4|p'
      )

      if [ -z "$monitor_width" ]; then
        exit 2
      fi

      # Intersect the pointer's monitor with XFCE's current EWMH work area so
      # the initial geometry already avoids panels and never needs correction.
      desktop="$(xprop -root _NET_CURRENT_DESKTOP | sed -n 's/.*= *\([0-9][0-9]*\).*/\1/p')"
      workareas="$(xprop -root _NET_WORKAREA)"
      workareas="''${workareas#*=}"
      workareas="''${workareas//,/ }"
      read -r -a area <<< "$workareas"
      area_index=$((desktop * 4))
      work_x="''${area[$area_index]}"
      work_y="''${area[$((area_index + 1))]}"
      work_width="''${area[$((area_index + 2))]}"
      work_height="''${area[$((area_index + 3))]}"

      left="$monitor_x"
      top="$monitor_y"
      right=$((monitor_x + monitor_width))
      bottom=$((monitor_y + monitor_height))
      (( work_x > left )) && left="$work_x"
      (( work_y > top )) && top="$work_y"
      (( work_x + work_width < right )) && right=$((work_x + work_width))
      (( work_y + work_height < bottom )) && bottom=$((work_y + work_height))

      width="$requested_width"
      height="$requested_height"
      (( width > right - left )) && width=$((right - left))
      (( height > bottom - top )) && height=$((bottom - top))

      if [ "$placement_mode" = monitor-center ]; then
        # Launchers are centered on the physical monitor containing the
        # pointer. Unlike normal application windows, they do not follow the
        # pointer itself and are small enough not to collide with the panel.
        target_x=$((monitor_x + (monitor_width - width) / 2))
        target_y=$((monitor_y + (monitor_height - height) / 2))
      else
        target_x=$((pointer_x - width / 2))
        target_y=$((pointer_y - height / 2))
        (( target_x < left )) && target_x="$left"
        (( target_y < top )) && target_y="$top"
        (( target_x + width > right )) && target_x=$((right - width))
        (( target_y + height > bottom )) && target_y=$((bottom - height))
      fi

      frame="$(xprop -id "$window_id" _NET_FRAME_EXTENTS 2>/dev/null || true)"
      frame="''${frame#*=}"
      frame="''${frame//,/ }"
      read -r frame_left _ frame_top _ <<< "$frame"
      frame_left="''${frame_left:-0}"
      frame_top="''${frame_top:-0}"

      # libwnck treats negative geometry coordinates as offsets from the far
      # root edge. Keep the decoration-adjusted client coordinates nonnegative
      # so a window near the left/top edge cannot jump to another monitor or
      # the bottom of the desktop.
      (( target_x < frame_left )) && target_x="$frame_left"
      (( target_y < frame_top )) && target_y="$frame_top"

      printf '%s %s %s %s\n' \
        "$((target_x - frame_left))" \
        "$((target_y - frame_top))" \
        "$width" \
        "$height"
    '';
  };
  xfceSharedKeybindings = pkgs.writeShellApplication {
    name = "xfce-apply-shared-keybindings";
    runtimeInputs = [ pkgs.xfconf pkgs.xset ];
    text = ''
      set_property() {
        local channel="$1"
        local property="$2"
        local type="$3"
        local value="$4"

        if xfconf-query -c "$channel" -p "$property" >/dev/null 2>&1; then
          xfconf-query -c "$channel" -p "$property" -s "$value"
        else
          xfconf-query -c "$channel" -p "$property" -n -t "$type" -s "$value"
        fi
      }

      set_command() {
        set_property xfce4-keyboard-shortcuts "/commands/custom/$1" string "$2"
      }

      set_wm() {
        set_property xfce4-keyboard-shortcuts "/xfwm4/custom/$1" string "$2"
      }

      # Applications and session actions shared by Sway, Niri, Mango and KDE.
      set_command '<Super>Return' 'kitty'
      # Compact X11-native launcher styled after the Noctalia palette. It opens
      # on the pointer's monitor and supports both clicking and optional search.
      set_command '<Super>space' '${xfceLauncher}/bin/xfce-launcher'
      set_command '<Super>s' 'xfce4-settings-manager'
      set_command '<Super>comma' 'xfce4-settings-manager'
      set_command '<Super>e' 'thunar'
      set_command '<Super>z' 'chromium'
      set_command '<Super>Escape' 'xflock4'
      set_command '<Super>l' 'xflock4'
      set_command '<Super><Shift>e' 'xfce4-session-logout'
      set_command '<Super><Shift><Alt>m' 'xfce4-session-logout'
      set_command '<Super>v' 'xfce4-clipman-history'
      set_command '<Super>o' '${pkgs.xfdashboard}/bin/xfdashboard --toggle'
      set_command '<Alt>z' 'fcitx5-remote -t'

      # Disable the X server bell as well as GTK event/input sounds for this
      # XFCE session. This covers key-limit feedback such as held Backspace.
      xset b off
      set_property xsettings /Net/EnableEventSounds bool false
      set_property xsettings /Net/EnableInputFeedbackSounds bool false

      # XFWM does not reliably grab Super+M on this system even though its
      # maximize_window_key property is present. Route this one shortcut
      # through xfsettingsd's command handler, which does receive Super+M.
      xfconf-query -c xfce4-keyboard-shortcuts \
        -p '/xfwm4/custom/<Super>m' -r -R 2>/dev/null || true
      set_command '<Super>m' '${xfceToggleMaximize}/bin/xfce-toggle-maximize'

      # Let XFWM select the pointer's monitor before the window rule constrains
      # the final geometry to that monitor's usable work area.
      set_property xfwm4 /general/placement_mode string mouse

      # Match the compositor sessions' pointer-focus behavior without raising
      # windows merely because the pointer crossed them.
      set_property xfwm4 /general/click_to_focus bool false
      set_property xfwm4 /general/focus_delay int 0
      set_property xfwm4 /general/raise_on_focus bool false

      # Picom provides consistent whole-window corner clipping in XFCE. It is
      # started by an XFCE-only autostart entry below, so Wayland is unaffected.
      set_property xfwm4 /general/use_compositing bool false

      # Keep both panels on the laptop when a monitor is hot-plugged. The
      # external display remains available for windows to the left of eDP-1.
      set_property xfce4-panel /panels/panel-1/output-name string eDP-1
      set_property xfce4-panel /panels/panel-2/output-name string eDP-1

      # Match the compositor sessions' region-first screenshot convention.
      set_command 'Print' 'xfce4-screenshooter --region'
      set_command '<Super>Print' 'xfce4-screenshooter --fullscreen'
      set_command '<Primary>Print' 'xfce4-screenshooter --window'

      # Hardware and media keys use desktop-independent PipeWire/player tools.
      set_command 'XF86AudioRaiseVolume' 'wpctl set-volume @DEFAULT_SINK@ 5%+'
      set_command 'XF86AudioLowerVolume' 'wpctl set-volume @DEFAULT_SINK@ 5%-'
      set_command 'XF86AudioMute' 'wpctl set-mute @DEFAULT_SINK@ toggle'
      set_command 'XF86AudioMicMute' 'wpctl set-mute @DEFAULT_SOURCE@ toggle'
      set_command 'XF86MonBrightnessUp' 'brightnessctl set 5%+'
      set_command 'XF86MonBrightnessDown' 'brightnessctl set 5%-'
      set_command 'XF86AudioPlay' 'playerctl play-pause'
      set_command 'XF86AudioNext' 'playerctl next'
      set_command 'XF86AudioPrev' 'playerctl previous'

      # Native XFWM equivalents for the portable window-management actions.
      set_wm '<Super>q' close_window_key
      set_wm '<Super>f' fullscreen_key
      set_wm '<Super>d' show_desktop_key
      set_wm '<Super>Tab' cycle_windows_key
      set_wm '<Super><Shift>Tab' cycle_reverse_windows_key
      set_wm '<Super>Left' tile_left_key
      set_wm '<Super>Right' tile_right_key
      set_wm '<Super>Up' tile_up_key
      set_wm '<Super>Down' tile_down_key
      set_wm '<Super>Page_Up' maximize_window_key
      set_wm '<Super>Page_Down' hide_window_key

      # Preserve the nine-workspace number row used by all compositor sessions.
      set_property xfwm4 /general/workspace_count int 9
      for workspace in {1..9}; do
        set_wm "<Super>$workspace" "workspace_''${workspace}_key"
        set_wm "<Super><Shift>$workspace" "move_window_workspace_''${workspace}_key"
        # KDE uses Super+Alt+number for the same move-to-workspace action.
        set_wm "<Super><Alt>$workspace" "move_window_workspace_''${workspace}_key"
      done

      set_wm '<Super><Primary>Left' left_workspace_key
      set_wm '<Super><Primary>Right' right_workspace_key
      set_wm '<Super><Primary>Up' up_workspace_key
      set_wm '<Super><Primary>Down' down_workspace_key
      set_wm '<Super><Primary><Shift>Left' move_window_left_key
      set_wm '<Super><Primary><Shift>Right' move_window_right_key
      set_wm '<Super><Primary><Shift>Up' move_window_up_key
      set_wm '<Super><Primary><Shift>Down' move_window_down_key

      # Super+R means compositor reload elsewhere, which XFWM does not need.
      # Remove XFCE's conflicting default app-finder assignment.
      xfconf-query -c xfce4-keyboard-shortcuts \
        -p '/commands/custom/<Super>r' -r -R 2>/dev/null || true
    '';
  };
  xfceSharedKeybindingsAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-shared-keybindings.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Apply shared desktop keybindings
    Exec=${xfceSharedKeybindings}/bin/xfce-apply-shared-keybindings
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  xfceClipmanAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-clipman-enabled.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Clipman
    Exec=xfce4-clipman
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  # KWin has an "Apply initially" rule for all normal windows at 1400x850.
  # XFWM has no native general-purpose window rule engine, so use a tiny
  # XFCE-only Devilspie2 rule for size and pointer-aware placement. Geometry is
  # clamped inside the pointer monitor's usable area before it is applied, so
  # XFWM does not move the window across monitors or away from a panel later.
  xfceWindowSizeRules = pkgs.writeTextDir "share/devilspie2/xfce-window-size.lua" ''
    if get_window_class() == "Rofi" then
      set_skip_tasklist(true)
      set_skip_pager(true)
      make_always_on_top()
      local _, _, width, height = get_window_geometry()
      local geometry = io.popen(
        "${xfceWindowGeometry}/bin/xfce-window-geometry "
          .. get_window_xid() .. " " .. width .. " " .. height
          .. " monitor-center"
      )
      if geometry then
        local placement = geometry:read("*a")
        geometry:close()
        local x, y = string.match(placement, "(%-?%d+) +(%-?%d+)")
        if x and y then
          set_adjust_for_decoration(false)
          set_window_geometry(
            tonumber(x),
            tonumber(y),
            tonumber(width),
            tonumber(height)
          )
        end
      end
    elseif get_window_type() == "WINDOW_TYPE_NORMAL"
      and not get_window_fullscreen()
    then
      local geometry = io.popen(
        "${xfceWindowGeometry}/bin/xfce-window-geometry "
          .. get_window_xid() .. " 1400 850"
      )
      if geometry then
        local placement = geometry:read("*a")
        geometry:close()
        local x, y, width, height = string.match(
          placement,
          "(%-?%d+) +(%-?%d+) +(%d+) +(%d+)"
        )
        if x and y and width and height then
          unmaximize()
          set_adjust_for_decoration(false)
          set_window_geometry(
            tonumber(x),
            tonumber(y),
            tonumber(width),
            tonumber(height)
          )
        end
      end
    end
  '';
  xfceWindowSizeAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-window-size.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Apply KDE-equivalent initial window size
    Comment=Open normal XFCE windows at 1400x850 within the pointer monitor
    Exec=${pkgs.devilspie2}/bin/devilspie2 --folder ${xfceWindowSizeRules}/share/devilspie2
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  xfcePreferLaptopDisplay = pkgs.writeShellApplication {
    name = "xfce-prefer-laptop-display";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.xdotool
      pkgs.xrandr
      pkgs.xev
    ];
    text = ''
      apply_layout_and_pointer() {
        if ! xrandr --query | grep -q '^eDP-1 connected'; then
          return 0
        fi
        xrandr --output eDP-1 --auto --primary || true
        external_outputs="$(
          xrandr --query \
            | sed -nE '/ connected/ { s/^([^ ]+) connected.*/\1/; /^eDP-/!p; }'
        )"
        left_of="eDP-1"
        while IFS= read -r output; do
          [ -n "$output" ] || continue
          xrandr --output "$output" --auto --left-of "$left_of" || true
          left_of="$output"
        done <<< "$external_outputs"

        geometry="$(
          xrandr --query \
            | sed -n 's/^eDP-1 connected primary \([0-9][0-9]*\)x\([0-9][0-9]*\)+\([0-9][0-9]*\)+\([0-9][0-9]*\).*/\1 \2 \3 \4/p'
        )"
        if [ -n "$geometry" ]; then
          read -r width height offset_x offset_y <<< "$geometry"
          pointer_x=$((offset_x + width / 2))
          pointer_y=$((offset_y + height / 2))
          xdotool mousemove --sync "$pointer_x" "$pointer_y"
        fi
      }

      # Let XFCE's display daemon settle, then apply the desired left/right
      # layout. Reapply and recenter after RandR hotplug notifications.
      sleep 2
      apply_layout_and_pointer
      coproc RANDR_EVENTS { xev -root -event randr 2>/dev/null; }
      event_pid="$RANDR_EVENTS_PID"
      cleanup() {
        kill -TERM "$event_pid" 2>/dev/null || true
        wait "$event_pid" 2>/dev/null || true
      }
      trap cleanup EXIT TERM INT HUP

      while IFS= read -r -u "''${RANDR_EVENTS[0]}" event; do
        case "$event" in
          *RRScreenChangeNotify*|*RRNotify*)
            sleep 0.7
            apply_layout_and_pointer
            ;;
        esac
      done
    '';
  };
  xfcePreferLaptopDisplayAutostart = pkgs.writeTextDir "etc/xdg/autostart/xfce-prefer-laptop-display.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Prefer laptop display in XFCE
    Comment=Make eDP-1 primary and place the startup pointer on it
    Exec=${xfcePreferLaptopDisplay}/bin/xfce-prefer-laptop-display
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  hideXfceWaylandSession = pkgs.writeTextDir "share/wayland-sessions/xfce-wayland.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Xfce Session (Wayland)
    Exec=false
    Hidden=true
    NoDisplay=true
  '';
  preferredXfceWaylandMask = hideXfceWaylandSession.overrideAttrs (_: {
    meta.priority = 0;
  });
  xfceNetworkAppletAutostart = pkgs.writeTextDir "etc/xdg/autostart/nm-applet.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=NetworkManager Applet
    Exec=nm-applet
    OnlyShowIn=XFCE;
    NoDisplay=true
  '';
  preferredXfceNetworkAppletAutostart = xfceNetworkAppletAutostart.overrideAttrs (_: {
    meta.priority = 0;
  });
in

{
  services.xserver = {
    enable = true;
    # A user-started Xorg writes its own per-user log. Keeping /dev/null here
    # would hide future startup diagnostics from Noctalia's startx chain.
    logFile = null;
    desktopManager.xfce = {
      enable = true;
      enableWaylandSession = false;
    };
  };

  # Noctalia Greeter runs xsessions through noctalia-greeter-xsession, which
  # uses startx to create the native Xorg server on greetd's active VT. Export
  # only XFCE from the X11 registry so enabling Xorg does not also add the
  # pre-existing but intentionally hidden Plasma X11 entry to the picker.
  environment.systemPackages = [
    pkgs.devilspie2
    pkgs.xinit
    pkgs.xfce4-clipman-plugin
    preferredNoctaliaXsession
    xfceSharedKeybindingsAutostart
    xfceClipmanAutostart
    xfcePicomAutostart
    xfceWindowSizeAutostart
    xfcePreferLaptopDisplayAutostart
    preferredXfceWaylandMask
    preferredXfceNetworkAppletAutostart
  ];

  # XApp is routed only for XFCE, and its system-visible D-Bus activation is
  # guarded by a marker imported by the native NixOS XFCE session wrapper.
  # XFCE's notification daemon is similarly restricted to XFCE so it cannot
  # compete with native notification owners in the Wayland sessions.
  systemd.user.services = {
    xdg-desktop-portal-xapp = {
      overrideStrategy = "asDropin";
      unitConfig = {
        # The backend is launched only by explicit XFCE portal routing. The
        # marker is imported by xfce-session-client, so XApp stays off in the
        # other desktops.
        ConditionEnvironment = "TONELICO_XAPP_PORTAL=1";
        PartOf = "graphical-session.target";
        After = "graphical-session.target";
      };
    };
    xfce4-notifyd = {
      overrideStrategy = "asDropin";
      unitConfig = {
        ConditionEnvironment = "XDG_CURRENT_DESKTOP=XFCE";
        PartOf = "graphical-session.target";
        After = "graphical-session.target";
      };
    };
  };

  # The upstream module exposes the entire NixOS session registry through
  # XDG_DATA_DIRS. The system profile already exports the four guarded Wayland
  # entries; omit that broad path so the greeter sees only the XFCE X11 entry
  # above in addition to those existing sessions.
  services.greetd.settings.default_session.command = lib.mkForce (
    "${pkgs.coreutils}/bin/env XDG_DATA_DIRS=/run/current-system/sw/share "
    + "${greeter.package}/bin/noctalia-greeter-session -- ${greeter.greeter-args}"
  );
}
