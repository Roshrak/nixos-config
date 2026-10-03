{ config, lib, pkgs, ... }:

let
  sessionLeaseGuard = ''
    if [ "''${THEME_SESSION_LEASE_HELD:-0}" != 1 ]; then
      [ -n "''${XDG_RUNTIME_DIR:-}" ] || {
        echo "graphical session has no XDG_RUNTIME_DIR; refusing shared session changes" >&2
        exit 1
      }
      exec ${pkgs.coreutils}/bin/env THEME_SESSION_LEASE_HELD=1 \
        /run/current-system/sw/bin/theme-session-lease "$0" "$@"
    fi
    unset THEME_SESSION_LEASE_HELD
  '';

  noctaliaProfile = pkgs.writeShellScriptBin "noctalia-profile" ''
    set -euo pipefail
    profile="''${1:-''${THEME_PROFILE:-}}"
    case "$profile" in
      niri|sway|mango|hyprland) ;;
      *)
        echo "Usage: noctalia-profile <niri|sway|mango|hyprland>" >&2
        exit 2
        ;;
    esac
    if [ "$#" -ge 1 ] && [ "$1" = "$profile" ]; then
      shift
    fi
    export THEME_PROFILE="$profile"
    export NOCTALIA_CONFIG_HOME="$HOME/.config/theme-profiles/$profile/config-home"
    export NOCTALIA_STATE_HOME="$HOME/.local/state/theme-profiles/$profile"
    export NOCTALIA_DATA_HOME="$HOME/.local/share"
    export QT_QPA_PLATFORMTHEME="qt6ct"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/$profile"
    exec /run/current-system/sw/bin/noctalia "$@"
  '';

  # The systemd user manager and its D-Bus activation environment are shared
  # by every login for one UID. Refuse to run session transitions while a
  # second same-UID graphical login exists; unknown logind state fails closed.
  themeSessionAdmit = pkgs.writeShellScriptBin "theme-session-admit" ''
    set -euo pipefail

    LOGINCTL=/run/current-system/sw/bin/loginctl
    ID_BIN=${pkgs.coreutils}/bin/id
    session_id="''${XDG_SESSION_ID:-}"

    refuse() {
      echo "theme-session-admit: $*; refusing shared session changes" >&2
      exit 1
    }

    [[ "$session_id" =~ ^[[:alnum:]_.-]+$ ]] || refuse 'XDG_SESSION_ID is missing or invalid'
    uid="$("$ID_BIN" -u)" || refuse 'could not resolve the current UID'
    sessions="$("$LOGINCTL" list-sessions --no-legend --no-pager)" || refuse 'could not enumerate logind sessions'

    current_seen=0
    current_type=""
    current_scope=""
    while read -r candidate_id candidate_uid _; do
      [ -n "''${candidate_id:-}" ] || continue
      [ "''${candidate_uid:-}" = "$uid" ] || continue
      [[ "$candidate_id" =~ ^[[:alnum:]_.-]+$ ]] || refuse 'logind returned an invalid same-UID session ID'

      candidate_type="$("$LOGINCTL" show-session "$candidate_id" --property=Type --value --no-pager)" || \
        refuse "could not inspect same-UID session $candidate_id"
      candidate_class="$("$LOGINCTL" show-session "$candidate_id" --property=Class --value --no-pager)" || \
        refuse "could not inspect same-UID session class $candidate_id"
      case "$candidate_type" in
        x11|wayland|mir)
          if [ "$candidate_id" = "$session_id" ]; then
            current_seen=1
            current_type="$candidate_type"
            [ "$candidate_class" = user ] || refuse 'current session is not a user login'
            current_scope="$("$LOGINCTL" show-session "$candidate_id" --property=Scope --value --no-pager)" || \
              refuse 'could not inspect the current session scope'
          else
            refuse "another graphical session for this UID is present (session $candidate_id, type $candidate_type)"
          fi
          ;;
        tty) ;;
        unspecified|none)
          [ "$candidate_class" = manager ] || \
            refuse "same-UID session $candidate_id has ambiguous non-graphical type '$candidate_type'"
          ;;
        *) refuse "same-UID session $candidate_id has unknown type '$candidate_type'" ;;
      esac
    done <<< "$sessions"

    [ "$current_seen" -eq 1 ] || refuse 'current graphical session is absent from logind'
    case "$current_type" in x11|wayland|mir) ;; *) refuse 'current logind session is not graphical' ;; esac
    [ "$current_scope" = "session-$session_id.scope" ] || refuse 'current session scope does not match its logind ID'
  '';

  themeSessionCleanup = pkgs.writeShellScriptBin "theme-session-cleanup" ''
    set -uo pipefail
    /run/current-system/sw/bin/theme-session-admit || exit $?
    /run/current-system/sw/bin/systemctl --user stop niri.service 2>/dev/null || true
    /run/current-system/sw/bin/systemctl --user stop geoclue-agent.service 2>/dev/null || true
    # Stop compositor-bound portal processes before clearing their inherited
    # display environment; they will be activated again by the next session.
    /run/current-system/sw/bin/systemctl --user stop \
      xdg-desktop-portal.service \
      xdg-desktop-portal-gtk.service \
      xdg-desktop-portal-wlr.service \
      xdg-desktop-portal-gnome.service \
      xdg-desktop-portal-xapp.service \
      xdg-desktop-portal-hyprland.service \
      plasma-xdg-desktop-portal-kde.service \
      xfce4-notifyd.service 2>/dev/null || true
    /run/current-system/sw/bin/systemctl --user unset-environment \
      THEME_PROFILE \
      NOCTALIA_STATE_HOME \
      NOCTALIA_CONFIG_HOME \
      KITTY_CONFIG_DIRECTORY \
      QT_QPA_PLATFORMTHEME \
      DESKTOP_SESSION \
      XDG_CURRENT_DESKTOP \
      XDG_SESSION_DESKTOP \
      XDG_SESSION_TYPE \
      XDG_SESSION_CLASS \
      WAYLAND_DISPLAY \
      NIRI_SOCKET \
      SWAYSOCK \
      MANGO_INSTANCE_SIGNATURE \
      HYPRLAND_INSTANCE_SIGNATURE \
      KDE_FULL_SESSION \
      KDE_SESSION_VERSION \
      KDE_SESSION_UID \
      KDE_SESSION_VT \
      KDE_APPLICATIONS_AS_SCOPE \
      GNOME_DESKTOP_SESSION_ID \
      GNOME_SETUP_DISPLAY \
      MATE_DESKTOP_SESSION_ID \
      CINNAMON_VERSION \
      LXQT_SESSION_CONFIG \
      LXQT_SESSION_ID \
      AWESOME_CONF \
      NIX_GSETTINGS_OVERRIDES_DIR \
      DISPLAY \
      XAUTHORITY \
      TONELICO_XAPP_PORTAL \
      TONELICO_X11_WINDOW_PLACEMENT 2>/dev/null || true
    # This D-Bus helper cannot remove entries (--unset is unsupported). Set
    # the old session values to empty in the D-Bus activation environment;
    # the next session imports its actual values. Do not pass --systemd here:
    # systemd's stale values were removed by unset-environment above.
    /run/current-system/sw/bin/dbus-update-activation-environment \
      THEME_PROFILE= \
      NOCTALIA_STATE_HOME= \
      NOCTALIA_CONFIG_HOME= \
      KITTY_CONFIG_DIRECTORY= \
      QT_QPA_PLATFORMTHEME= \
      DESKTOP_SESSION= \
      XDG_CURRENT_DESKTOP= \
      XDG_SESSION_DESKTOP= \
      XDG_SESSION_TYPE= \
      XDG_SESSION_CLASS= \
      WAYLAND_DISPLAY= \
      NIRI_SOCKET= \
      SWAYSOCK= \
      MANGO_INSTANCE_SIGNATURE= \
      HYPRLAND_INSTANCE_SIGNATURE= \
      KDE_FULL_SESSION= \
      KDE_SESSION_VERSION= \
      KDE_SESSION_UID= \
      KDE_SESSION_VT= \
      KDE_APPLICATIONS_AS_SCOPE= \
      GNOME_DESKTOP_SESSION_ID= \
      GNOME_SETUP_DISPLAY= \
      MATE_DESKTOP_SESSION_ID= \
      CINNAMON_VERSION= \
      LXQT_SESSION_CONFIG= \
      LXQT_SESSION_ID= \
      AWESOME_CONF= \
      NIX_GSETTINGS_OVERRIDES_DIR= \
      DISPLAY= \
      XAUTHORITY= \
      TONELICO_XAPP_PORTAL= \
      TONELICO_X11_WINDOW_PLACEMENT= 2>/dev/null || true
  '';

  # Plasma launches its compositor through user units that can outlive the
  # greetd login scope. Stop Plasma's session targets and wait for its own KWin
  # unit to finish before starting an X11 desktop. Never kill every Xwayland
  # process for this UID: a different active graphical session may own it.
  plasmaSessionCleanup = pkgs.writeShellScriptBin "plasma-session-cleanup" ''
    set -uo pipefail

    /run/current-system/sw/bin/theme-session-admit || exit $?

    SYSTEMCTL=/run/current-system/sw/bin/systemctl
    KWIN_UNIT=plasma-kwin_wayland.service

    "$SYSTEMCTL" --user stop \
      plasma-workspace-wayland.target \
      plasma-workspace.target \
      "$KWIN_UNIT" 2>/dev/null || true

    kwin_inactive() {
      local properties load="" state="" key value
      properties="$("$SYSTEMCTL" --user show --property=LoadState --property=ActiveState "$KWIN_UNIT" 2>/dev/null)" || return 1
      while IFS='=' read -r key value; do
        case "$key" in LoadState) load="$value";; ActiveState) state="$value";; esac
      done <<< "$properties"
      case "$load:$state" in
        loaded:inactive|loaded:failed|not-found:inactive) return 0 ;;
        *) return 1 ;;
      esac
    }

    attempt=0
    while ! kwin_inactive && [ "$attempt" -lt 50 ]; do
      ${pkgs.coreutils}/bin/sleep 0.1
      attempt=$((attempt + 1))
    done

    if ! kwin_inactive; then
      echo "plasma-session-cleanup: $KWIN_UNIT did not stop" >&2
      exit 1
    fi
  '';

  themeProfileActivate = pkgs.writeShellScriptBin "theme-profile-activate" ''
    set -euo pipefail

    usage() {
      echo "Usage: theme-profile-activate <niri|sway|mango|hyprland|kde>" >&2
      exit 2
    }

    [ $# -ge 1 ] || usage
    PROFILE="$1"

    case "$PROFILE" in
      niri|sway|mango|hyprland|kde) ;;
      *) usage ;;
    esac

    /run/current-system/sw/bin/theme-session-admit || exit $?

    UID_ME="$(id -u)"
    STATE_ROOT="$HOME/.local/state/theme-profiles"
    CONFIG_ROOT="$HOME/.config/theme-profiles"

    mkdir -p "$STATE_ROOT/$PROFILE/generated/gtk3" \
             "$STATE_ROOT/$PROFILE/generated/gtk4" \
             "$STATE_ROOT/$PROFILE/generated/qt" \
             "$CONFIG_ROOT/$PROFILE/gtk-3.0" \
             "$CONFIG_ROOT/$PROFILE/gtk-4.0" \
             "$HOME/.config/kitty/profiles/$PROFILE" \
             "$HOME/.config/gtk-3.0" \
             "$HOME/.config/gtk-4.0" \
             "$HOME/.config/qt5ct/colors" \
             "$HOME/.config/qt6ct/colors"

    atomic_copy() {
      local from="$1" to="$2" tmpdir tmp
      [ -f "$from" ] || return 0
      tmpdir="$(dirname "$to")"
      mkdir -p "$tmpdir"
      tmp="$(mktemp "$tmpdir/.act.XXXXXX")"
      cp -a "$from" "$tmp"
      mv -f "$tmp" "$to"
    }

    # 1. Kitty configuration
    cat > "$HOME/.config/kitty/profiles/$PROFILE/kitty.conf" << 'KEOF'
include /home/aesc/.config/kitty/common.conf
include theme.conf
KEOF

    # Ensure canonical ~/.config/kitty/kitty.conf is a stable fallback
    if [ ! -f "$HOME/.config/kitty/kitty.conf" ] || grep -q "THEME_PROFILE" "$HOME/.config/kitty/kitty.conf"; then
      cat > "$HOME/.config/kitty/kitty.conf" << 'KEOF'
include /home/aesc/.config/kitty/common.conf
include /home/aesc/.config/kitty/themes/default.conf
KEOF
    fi

    mkdir -p "$HOME/.config/kitty/themes"
    if [ ! -f "$HOME/.config/kitty/themes/default.conf" ]; then
      if [ -f "$HOME/.config/kitty/profiles/niri/theme.conf" ]; then
        cp -a "$HOME/.config/kitty/profiles/niri/theme.conf" "$HOME/.config/kitty/themes/default.conf"
      fi
    fi

    # 2. GTK Setup
    for v in 3.0 4.0; do
      gtk_dir="$HOME/.config/gtk-$v"
      if [ -f "$CONFIG_ROOT/$PROFILE/gtk-$v/settings.ini" ]; then
        atomic_copy "$CONFIG_ROOT/$PROFILE/gtk-$v/settings.ini" "$gtk_dir/settings.ini"
      fi

      # Password fields and search boxes use GTK's error bell independently
      # from desktop event sounds. Reassert these after every theme-profile
      # copy so switching desktops can never restore an audible bell.
      for key in \
        gtk-error-bell \
        gtk-enable-event-sounds \
        gtk-enable-input-feedback-sounds; do
        if grep -q "^$key=" "$gtk_dir/settings.ini"; then
          ${pkgs.gnused}/bin/sed -i "s/^$key=.*/$key=false/" "$gtk_dir/settings.ini"
        else
          printf '%s=false\n' "$key" >> "$gtk_dir/settings.ini"
        fi
      done

      gtk_css="$gtk_dir/gtk.css"
      if [ ! -f "$gtk_css" ] || ! grep -q "theme-active.css" "$gtk_css"; then
        printf "@import 'colors.css';\n@import 'theme-active.css';\n" > "$gtk_css"
      fi
    done

    # Plasma and KDE applications keep a separate bell preference. This also
    # covers KScreenLocker and survives later theme/profile activation.
    ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 \
      --file "$HOME/.config/kdeglobals" \
      --group General --key UseSystemBell false
    ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 \
      --file "$HOME/.config/kaccessrc" \
      --group Bell --key SystemBell false
    ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 \
      --file "$HOME/.config/kaccessrc" \
      --group Bell --key ArtsBell false

    if [ "$PROFILE" != "kde" ]; then
      if [ -f "$STATE_ROOT/$PROFILE/generated/gtk3/noctalia.css" ]; then
        atomic_copy "$STATE_ROOT/$PROFILE/generated/gtk3/noctalia.css" "$HOME/.config/gtk-3.0/theme-active.css"
      elif [ -f "$CONFIG_ROOT/$PROFILE/gtk-3.0/noctalia.css" ]; then
        atomic_copy "$CONFIG_ROOT/$PROFILE/gtk-3.0/noctalia.css" "$HOME/.config/gtk-3.0/theme-active.css"
      else
        printf "/* $PROFILE GTK 3 active */\n" > "$HOME/.config/gtk-3.0/theme-active.css"
      fi

      if [ -f "$STATE_ROOT/$PROFILE/generated/gtk4/noctalia.css" ]; then
        atomic_copy "$STATE_ROOT/$PROFILE/generated/gtk4/noctalia.css" "$HOME/.config/gtk-4.0/theme-active.css"
      elif [ -f "$CONFIG_ROOT/$PROFILE/gtk-4.0/noctalia.css" ]; then
        atomic_copy "$CONFIG_ROOT/$PROFILE/gtk-4.0/noctalia.css" "$HOME/.config/gtk-4.0/theme-active.css"
      else
        printf "/* $PROFILE GTK 4 active */\n" > "$HOME/.config/gtk-4.0/theme-active.css"
      fi

      if [ -f "$CONFIG_ROOT/$PROFILE/gtkrc-2.0" ]; then
        atomic_copy "$CONFIG_ROOT/$PROFILE/gtkrc-2.0" "$HOME/.gtkrc-2.0"
      fi

      if [ -f "$STATE_ROOT/$PROFILE/generated/qt/noctalia.conf" ]; then
        atomic_copy "$STATE_ROOT/$PROFILE/generated/qt/noctalia.conf" "$HOME/.config/qt5ct/colors/noctalia.conf"
        atomic_copy "$STATE_ROOT/$PROFILE/generated/qt/noctalia.conf" "$HOME/.config/qt6ct/colors/noctalia.conf"
      elif [ -f "$CONFIG_ROOT/$PROFILE/qt6ct/colors/noctalia.conf" ]; then
        atomic_copy "$CONFIG_ROOT/$PROFILE/qt6ct/colors/noctalia.conf" "$HOME/.config/qt5ct/colors/noctalia.conf"
        atomic_copy "$CONFIG_ROOT/$PROFILE/qt6ct/colors/noctalia.conf" "$HOME/.config/qt6ct/colors/noctalia.conf"
      fi

      if [ ! -f "$HOME/.config/qt6ct/qt6ct.conf" ] || [ ! -s "$HOME/.config/qt6ct/qt6ct.conf" ]; then
        cat > "$HOME/.config/qt6ct/qt6ct.conf" << 'QTEOF'
[Appearance]
color_scheme_path=/home/aesc/.config/qt6ct/colors/noctalia.conf
custom_palette=true
style=Fusion
QTEOF
      fi

      case "$PROFILE" in
        niri)
          if [ -f "$STATE_ROOT/niri/generated/niri/colors.kdl" ]; then
            atomic_copy "$STATE_ROOT/niri/generated/niri/colors.kdl" "$HOME/.config/niri/colors.kdl"
          elif [ -f "$CONFIG_ROOT/niri/colors.kdl" ]; then
            atomic_copy "$CONFIG_ROOT/niri/colors.kdl" "$HOME/.config/niri/colors.kdl"
          fi
          ;;
        sway)
          if [ -f "$STATE_ROOT/sway/generated/sway/colors" ]; then
            atomic_copy "$STATE_ROOT/sway/generated/sway/colors" "$HOME/.config/sway/colors"
          elif [ -f "$CONFIG_ROOT/sway/colors" ]; then
            atomic_copy "$CONFIG_ROOT/sway/colors" "$HOME/.config/sway/colors"
          fi
          ;;
        mango)
          if [ -f "$STATE_ROOT/mango/generated/mango/colors.conf" ]; then
            atomic_copy "$STATE_ROOT/mango/generated/mango/colors.conf" "$HOME/.config/mango/noctalia.conf"
          elif [ -f "$CONFIG_ROOT/mango/colors.conf" ]; then
            atomic_copy "$CONFIG_ROOT/mango/colors.conf" "$HOME/.config/mango/noctalia.conf"
          fi
          ;;
      esac

      systemctl --user set-environment \
        THEME_PROFILE="$PROFILE" \
        KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/$PROFILE" \
        NOCTALIA_STATE_HOME="$STATE_ROOT/$PROFILE" \
        NOCTALIA_CONFIG_HOME="$CONFIG_ROOT/$PROFILE/config-home" \
        QT_QPA_PLATFORMTHEME="qt6ct" 2>/dev/null || true

      if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd \
          THEME_PROFILE="$PROFILE" \
          KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/$PROFILE" \
          NOCTALIA_STATE_HOME="$STATE_ROOT/$PROFILE" \
          NOCTALIA_CONFIG_HOME="$CONFIG_ROOT/$PROFILE/config-home" \
          QT_QPA_PLATFORMTHEME="qt6ct" 2>/dev/null || true
      fi

    else
      printf "/* KDE session: Noctalia CSS inactive */\n" > "$HOME/.config/gtk-3.0/theme-active.css"
      printf "/* KDE session: Noctalia CSS inactive */\n" > "$HOME/.config/gtk-4.0/theme-active.css"

      systemctl --user set-environment \
        THEME_PROFILE="kde" \
        KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/kde" 2>/dev/null || true

      systemctl --user unset-environment \
        NOCTALIA_STATE_HOME \
        NOCTALIA_CONFIG_HOME \
        QT_QPA_PLATFORMTHEME 2>/dev/null || true

      if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd \
          THEME_PROFILE="kde" \
          KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/kde" 2>/dev/null || true
      fi
    fi

    pkill -SIGUSR1 -u "$UID_ME" -x kitty 2>/dev/null || true
    echo "Theme profile activated: $PROFILE"
  '';

  themeProfileSync = pkgs.writeShellScriptBin "theme-profile-sync" ''
    set -euo pipefail

    /run/current-system/sw/bin/theme-session-admit || exit $?

    PROFILE="''${THEME_PROFILE:-}"
    if [ -z "$PROFILE" ]; then
      case "''${XDG_CURRENT_DESKTOP:-}" in
        *niri*|*Niri*) PROFILE="niri" ;;
        *sway*|*Sway*) PROFILE="sway" ;;
        *mango*|*Mango*) PROFILE="mango" ;;
        *hyprland*|*Hyprland*) PROFILE="hyprland" ;;
        *KDE*|*kde*|*plasma*) PROFILE="kde" ;;
      esac
    fi

    case "$PROFILE" in
      niri|sway|mango|hyprland) ;;
      *) exit 0 ;;
    esac

    # Debounce: coalesce rapid hook invocations (e.g. browsing wallpapers or multi-monitor events)
    # The debounce files must never fall back to shared /tmp or follow links.
    runtime_uid="$(${pkgs.coreutils}/bin/id -u)"
    runtime_dir="''${XDG_RUNTIME_DIR:-}"
    refuse_runtime() { echo "noctalia-theme-sync: unsafe runtime debounce path" >&2; exit 1; }
    [ "$runtime_dir" = "/run/user/$runtime_uid" ] && [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || refuse_runtime
    [ "$(${pkgs.coreutils}/bin/stat -c '%u:%a' -- "$runtime_dir")" = "$runtime_uid:700" ] || refuse_runtime
    umask 077
    STAMP_DIR="$runtime_dir/theme-sync"
    if [ -e "$STAMP_DIR" ] || [ -L "$STAMP_DIR" ]; then
      [ -d "$STAMP_DIR" ] && [ ! -L "$STAMP_DIR" ] || refuse_runtime
    else
      mkdir -m 0700 -- "$STAMP_DIR" || {
        [ -d "$STAMP_DIR" ] && [ ! -L "$STAMP_DIR" ] || refuse_runtime
      }
    fi
    [ -d "$STAMP_DIR" ] && [ ! -L "$STAMP_DIR" ] || refuse_runtime
    [ "$(${pkgs.coreutils}/bin/stat -c '%u' -- "$STAMP_DIR")" = "$runtime_uid" ] || refuse_runtime
    stamp_mode="$(${pkgs.coreutils}/bin/stat -c '%a' -- "$STAMP_DIR")"
    (( (8#$stamp_mode & 0022) == 0 )) || refuse_runtime
    STAMP_FILE="$STAMP_DIR/req-$PROFILE"
    LOCK_FILE="$STAMP_DIR/lock-$PROFILE"
    for marker in "$STAMP_FILE" "$LOCK_FILE"; do
      [ ! -L "$marker" ] || refuse_runtime
      if [ -e "$marker" ]; then
        [ -f "$marker" ] || refuse_runtime
        [ "$(${pkgs.coreutils}/bin/stat -c '%u:%h' -- "$marker")" = "$runtime_uid:1" ] || refuse_runtime
        marker_mode="$(${pkgs.coreutils}/bin/stat -c '%a' -- "$marker")"
        (( (8#$marker_mode & 0022) == 0 )) || refuse_runtime
      fi
    done

    date +%s%N > "$STAMP_FILE"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      # Another instance is already queued or processing, exit immediately
      exit 0
    fi

    # Trailing debounce window: wait for rapid bursts to settle
    while true; do
      LAST_REQ="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
      sleep 0.35
      CURRENT_REQ="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
      if [ "$LAST_REQ" = "$CURRENT_REQ" ]; then
        break
      fi
    done

    /run/current-system/sw/bin/theme-profile-activate "$PROFILE"

    case "$PROFILE" in
      niri)
        if command -v niri >/dev/null 2>&1; then
          niri msg action reload-config 2>/dev/null || true
        fi
        ;;
      sway)
        if command -v swaymsg >/dev/null 2>&1; then
          swaymsg reload 2>/dev/null || true
        fi
        ;;
      mango)
        if command -v mmsg >/dev/null 2>&1; then
          mmsg dispatch reload_config 2>/dev/null || true
        fi
        ;;
      hyprland)
        if command -v hyprctl >/dev/null 2>&1; then
          hyprctl reload 2>/dev/null || true
        fi
        ;;
    esac
  '';

  niriSessionGuarded = pkgs.writeShellScriptBin "niri-session-guarded" ''
    set -u
    ${sessionLeaseGuard}

    /run/current-system/sw/bin/theme-session-admit || exit $?

    SYSTEMCTL=/run/current-system/sw/bin/systemctl

    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true

    export THEME_PROFILE="niri"
    export NOCTALIA_CONFIG_HOME="$HOME/.config/theme-profiles/niri/config-home"
    export NOCTALIA_STATE_HOME="$HOME/.local/state/theme-profiles/niri"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/niri"
    export QT_QPA_PLATFORMTHEME="qt6ct"

    /run/current-system/sw/bin/theme-profile-activate niri >/dev/null 2>&1 || true
    /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true

    on_exit() {
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    }
    trap on_exit EXIT TERM INT HUP

    state() { "$SYSTEMCTL" --user is-active niri.service 2>/dev/null || true; }

    wait_inactive() {
      local i=0
      while [ $i -lt "$1" ]; do
        case "$(state)" in inactive|unknown|failed) return 0 ;; esac
        sleep 0.1; i=$((i+1))
      done
      return 1
    }

    force_cleanup() {
      echo "niri-guard: leftover niri state detected (state=$(state)), cleaning"
      "$SYSTEMCTL" --user --no-block stop niri.service 2>/dev/null || true
      wait_inactive 30 || true

      jobs="$("$SYSTEMCTL" --user list-jobs --no-legend 2>/dev/null || true)"
      while read -r job_id job_unit _; do
        [ "$job_unit" = "niri.service" ] || continue
        case "$job_id" in
          ""|*[!0-9]*) continue ;;
        esac
        "$SYSTEMCTL" --user cancel "$job_id" 2>/dev/null || true
      done <<< "$jobs"

      "$SYSTEMCTL" --user reset-failed niri.service 2>/dev/null || true
      sleep 0.3
    }

    attempt=0
    until [ "$(state)" = inactive ]; do
      attempt=$((attempt+1))
      [ $attempt -gt 3 ] && {
        echo "niri-guard: FATAL: niri.service never reached inactive; aborting." >&2
        exit 1
      }
      force_cleanup
    done

    /run/current-system/sw/bin/niri-session "$@"
    rc=$?

    trap - EXIT
    on_exit
    exit "$rc"
  '';

  # Invoked by Sway after its own IPC/display sockets exist. Never start or
  # stop the shared graphical-session target from this readiness hook.
  swaySessionReady = pkgs.writeShellScriptBin "sway-session-ready" ''
    set -euo pipefail
    [ "''${XDG_CURRENT_DESKTOP:-}" = sway ] &&
      [ "''${XDG_SESSION_DESKTOP:-}" = sway ] &&
      [ "''${XDG_SESSION_TYPE:-}" = wayland ] &&
      [ "''${XDG_SESSION_CLASS:-}" = user ] || {
        echo "sway-session-ready: incomplete Sway identity; refusing publication" >&2
        exit 1
      }
    /run/current-system/sw/bin/theme-session-admit
    uid="$(${pkgs.coreutils}/bin/id -u)"
    [ "''${XDG_RUNTIME_DIR:-}" = "/run/user/$uid" ] &&
      [ -d "$XDG_RUNTIME_DIR" ] && [ ! -L "$XDG_RUNTIME_DIR" ] &&
      [ "$(${pkgs.coreutils}/bin/stat -c %u -- "$XDG_RUNTIME_DIR")" = "$uid" ] || exit 1
    case "''${SWAYSOCK:-}" in "$XDG_RUNTIME_DIR/"*) ;; *) exit 1 ;; esac
    [[ "''${SWAYSOCK#"$XDG_RUNTIME_DIR/"}" =~ ^[[:alnum:]_.-]+$ ]] || exit 1
    [[ "''${WAYLAND_DISPLAY:-}" =~ ^[[:alnum:]_.-]+$ ]] || exit 1
    for socket in "$SWAYSOCK" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"; do
      [ -S "$socket" ] && [ ! -L "$socket" ] &&
        [ "$(${pkgs.coreutils}/bin/stat -c %u -- "$socket")" = "$uid" ] || exit 1
    done
    /run/current-system/sw/bin/swaymsg -s "$SWAYSOCK" -t get_version >/dev/null
    /run/current-system/sw/bin/systemctl --user import-environment \
      WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP \
      XDG_SESSION_TYPE XDG_SESSION_CLASS XDG_SESSION_ID KITTY_CONFIG_DIRECTORY \
      THEME_PROFILE NOCTALIA_STATE_HOME NOCTALIA_CONFIG_HOME QT_QPA_PLATFORMTHEME
    /run/current-system/sw/bin/dbus-update-activation-environment --systemd \
      WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP \
      XDG_SESSION_TYPE XDG_SESSION_CLASS XDG_SESSION_ID KITTY_CONFIG_DIRECTORY \
      THEME_PROFILE NOCTALIA_STATE_HOME NOCTALIA_CONFIG_HOME QT_QPA_PLATFORMTHEME
    /run/current-system/sw/bin/systemctl --user restart xdg-desktop-portal-wlr.service xdg-desktop-portal.service
    # Noctalia starts alongside this compositor-ready hook. Retry a bounded
    # time and leave an explicit failure if the saved policy remains unapplied.
    for attempt in {1..20}; do
      if /run/current-system/sw/bin/autosleep apply; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.25
    done
    echo "sway-session-ready: saved autosleep policy remains unapplied" >&2
    exit 1
  '';

  swaySessionGuarded = pkgs.writeShellScriptBin "sway-session-guarded" ''
    set -u
    ${sessionLeaseGuard}
    /run/current-system/sw/bin/theme-session-admit || exit $?
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true

    # Clean up leftover compositors from previous sessions
    /run/current-system/sw/bin/systemctl --user stop niri.service 2>/dev/null || true
    export XDG_CURRENT_DESKTOP="sway"
    export XDG_SESSION_DESKTOP="sway"
    export XDG_SESSION_TYPE="wayland"
    export XDG_SESSION_CLASS="user"
    export THEME_PROFILE="sway"
    export NOCTALIA_CONFIG_HOME="$HOME/.config/theme-profiles/sway/config-home"
    export NOCTALIA_STATE_HOME="$HOME/.local/state/theme-profiles/sway"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/sway"
    export QT_QPA_PLATFORMTHEME="qt6ct"

    /run/current-system/sw/bin/theme-profile-activate sway >/dev/null 2>&1 || true
    /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true

    on_exit() {
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    }
    trap on_exit EXIT TERM INT HUP

    /run/current-system/sw/bin/desktop-main-pointer sway >/dev/null 2>&1 &
    pointer_pid=$!
    /run/current-system/sw/bin/sway "$@"
    rc=$?
    kill -TERM "$pointer_pid" 2>/dev/null || true
    wait "$pointer_pid" 2>/dev/null || true

    trap - EXIT
    on_exit
    exit "$rc"
  '';

  mangoSessionGuarded = pkgs.writeShellScriptBin "mango-session-guarded" ''
    set -u
    ${sessionLeaseGuard}
    /run/current-system/sw/bin/theme-session-admit || exit $?
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true

    # Clean up leftover compositors from previous sessions
    /run/current-system/sw/bin/systemctl --user stop niri.service 2>/dev/null || true
    export THEME_PROFILE="mango"
    export NOCTALIA_CONFIG_HOME="$HOME/.config/theme-profiles/mango/config-home"
    export NOCTALIA_STATE_HOME="$HOME/.local/state/theme-profiles/mango"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/mango"
    export QT_QPA_PLATFORMTHEME="qt6ct"

    /run/current-system/sw/bin/theme-profile-activate mango >/dev/null 2>&1 || true
    /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true

    on_exit() {
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    }
    trap on_exit EXIT TERM INT HUP

    /run/current-system/sw/bin/desktop-main-pointer mango >/dev/null 2>&1 &
    pointer_pid=$!
    /run/current-system/sw/bin/mango "$@"
    rc=$?
    kill -TERM "$pointer_pid" 2>/dev/null || true
    wait "$pointer_pid" 2>/dev/null || true

    trap - EXIT
    on_exit
    exit "$rc"
  '';

  plasmaSessionGuarded = pkgs.writeShellScriptBin "plasma-session-guarded" ''
    set -u
    ${sessionLeaseGuard}
    /run/current-system/sw/bin/theme-session-admit || exit $?
    /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true

    # Clean up leftover compositors from previous sessions
    /run/current-system/sw/bin/systemctl --user stop niri.service 2>/dev/null || true
    export THEME_PROFILE="kde"
    export KITTY_CONFIG_DIRECTORY="$HOME/.config/kitty/profiles/kde"

    /run/current-system/sw/bin/theme-profile-activate kde >/dev/null 2>&1 || true
    /run/current-system/sw/bin/systemctl --user start geoclue-agent.service 2>/dev/null || true

    on_exit() {
      /run/current-system/sw/bin/plasma-session-cleanup >/dev/null 2>&1 || true
      /run/current-system/sw/bin/theme-session-cleanup >/dev/null 2>&1 || true
    }
    trap on_exit EXIT TERM INT HUP

    STARTPLASMA=/run/current-system/sw/bin/startplasma-wayland
    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      dbus-run-session "$STARTPLASMA" "$@"
      rc=$?
    else
      "$STARTPLASMA" "$@"
      rc=$?
    fi

    trap - EXIT
    on_exit
    exit "$rc"
  '';
in
{
  environment.systemPackages = with pkgs; [
    kdePackages.qt6ct
    libsForQt5.qt5ct
    noctaliaProfile
    themeSessionAdmit
    themeProfileActivate
    themeProfileSync
    themeSessionCleanup
    plasmaSessionCleanup
    niriSessionGuarded
    swaySessionReady
    swaySessionGuarded
    mangoSessionGuarded
    plasmaSessionGuarded
  ];
}
