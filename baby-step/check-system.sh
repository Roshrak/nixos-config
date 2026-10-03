#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

[ "$#" -le 1 ] || { printf 'ERROR: Use one option at a time.\n' >&2; exit 2; }
case "${1:-}" in
    "") ;;
    -h|--help)
        printf 'Run a read-only health check and save its log and result.\n'
        printf 'Run: %s\n' "$HOME/baby-step/check-system.sh"
        exit 0
        ;;
    *)
        printf 'ERROR: Unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac

start_log "check"
acquire_maintenance_lock

warnings=0
failures=0
skips=0
TOTAL=17

ok() {
    show_ok
}

warn() {
    show_warning "$*"
    warnings=$((warnings + 1))
    printf 'WARNING: %s\n' "$*" >> "$LOG_FILE"
}

fail_check() {
    show_failed "$*"
    failures=$((failures + 1))
    printf 'FAILED: %s\n' "$*" >> "$LOG_FILE"
}

show_banner 'System health check' 'Configuration and runtime checks; logs and state only'
if ! require_commands nix jq hostname nixos-rebuild systemctl timeout rg df awk git; then
    warnings=$((warnings + 1))
    show_detail 'Some base commands are missing; independent checks will continue and report their own results.'
fi
printf 'Command environment: %s / %s\n\n' \
    "${XDG_CURRENT_DESKTOP:-unknown}" "${XDG_SESSION_TYPE:-unknown}"

show_step 1 "$TOTAL" "Checking NixOS configuration"
if detect_flake_target &&
   run_logged 'Complete NixOS system evaluation' nix eval --no-write-lock-file --raw \
       "path:$NIXOS_DIR#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.drvPath"; then
    ok
    printf '  Target: %s\n' "$FLAKE_TARGET"
else
    fail_check "NixOS flake evaluation failed"
fi

show_step 2 "$TOTAL" "Checking failed system services"
if system_failed="$(systemctl --failed --no-legend --plain 2>> "$LOG_FILE")"; then
    if [ -z "$system_failed" ]; then
        ok
    else
        printf '%s\n' "$system_failed" >> "$LOG_FILE"
        fail_check "one or more system services failed"
        printf '%s\n' "$system_failed" | head -12 | redact_output
    fi
else
    fail_check "could not query system services"
fi

show_step 3 "$TOTAL" "Checking failed user services"
if user_failed="$(systemctl --user --failed --no-legend --plain 2>> "$LOG_FILE")"; then
    if [ -z "$user_failed" ]; then
        ok
    else
        printf '%s\n' "$user_failed" >> "$LOG_FILE"
        fail_check "one or more user services failed"
        printf '%s\n' "$user_failed" | head -12 | redact_output
    fi
else
    fail_check "could not query user services"
fi

show_step 4 "$TOTAL" "Checking network and DNS"
connectivity="$(nmcli -t -f CONNECTIVITY general 2>> "$LOG_FILE" || true)"
if [ "$connectivity" = "full" ] &&
   getent ahostsv4 nixos.org >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "network or DNS resolution is not fully working"
fi

show_step 5 "$TOTAL" "Checking Bluetooth"
if systemctl is-active --quiet bluetooth.service; then
    ok
else
    warn "Bluetooth service is not active"
fi

show_step 6 "$TOTAL" "Checking audio"
if systemctl --user is-active --quiet pipewire.service &&
   systemctl --user is-active --quiet wireplumber.service &&
   wpctl get-volume @DEFAULT_AUDIO_SINK@ >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "PipeWire, WirePlumber, or the default audio output is unavailable"
fi

show_step 7 "$TOTAL" "Checking Mango configuration"
if [ -s "$HOME/.config/mango/config.conf" ]; then
    warn "Mango configuration exists; standalone parser validation unavailable. No compositor was launched."
else
    fail_check "Mango configuration is missing or empty"
fi

show_step 8 "$TOTAL" "Checking Niri configuration"
if timeout 15 niri validate >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "Niri configuration validation failed"
fi

show_step 9 "$TOTAL" "Checking Noctalia & Sway configuration"
if noctalia_settings_syntax_check >> "$LOG_FILE" 2>&1 && \
    ([ ! -f "$HOME/.config/sway/config" ] || ! command -v sway >/dev/null 2>&1 || \
     WLR_BACKENDS=headless timeout 15 sway -C -c "$HOME/.config/sway/config" >> "$LOG_FILE" 2>&1); then
    warn "Selected Noctalia TOML/JSON and Sway parser checked; shell behavior requires runtime acceptance."
else
    fail_check "Noctalia or Sway configuration validation failed"
fi

show_step 10 "$TOTAL" "Checking Hyprland configuration"
if [ -f "$HOME/.config/hypr/hyprland.lua" ] &&
   timeout 15 Hyprland --verify-config --config "$HOME/.config/hypr/hyprland.lua" \
       >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "Hyprland Lua configuration validation failed"
fi

show_step 11 "$TOTAL" "Checking the seven visible greetd sessions"
wayland_dir="/run/current-system/sw/share/wayland-sessions"
x11_dir="/run/current-system/sw/share/xsessions"
catalog_ok=1
visible_wayland=0
visible_x11=0
for session_name in gnome hyprland mango niri plasma sway; do
    session_file="$wayland_dir/$session_name.desktop"
    if [ ! -f "$session_file" ] ||
       rg -q '^(Hidden|NoDisplay)=true$' "$session_file" ||
       ! rg -q '^Exec=.+$' "$session_file"; then
        printf 'Missing or hidden Wayland session: %s\n' "$session_name" >> "$LOG_FILE"
        catalog_ok=0
    fi
done
for session_file in "$wayland_dir"/*.desktop; do
    [ -f "$session_file" ] || continue
    if ! rg -q '^(Hidden|NoDisplay)=true$' "$session_file"; then
        visible_wayland=$((visible_wayland + 1))
    fi
done
if [ ! -f "$x11_dir/xfce.desktop" ] ||
   rg -q '^(Hidden|NoDisplay)=true$' "$x11_dir/xfce.desktop" ||
   ! rg -q '^Exec=.+$' "$x11_dir/xfce.desktop"; then
    printf 'Missing or hidden X11 session: xfce\n' >> "$LOG_FILE"
    catalog_ok=0
fi
for session_file in "$x11_dir"/*.desktop; do
    [ -f "$session_file" ] || continue
    if ! rg -q '^(Hidden|NoDisplay)=true$' "$session_file"; then
        visible_x11=$((visible_x11 + 1))
    fi
done
if [ "$visible_wayland" -ne 6 ] || [ "$visible_x11" -ne 1 ]; then
    printf 'Unexpected visible session counts: Wayland=%s X11=%s\n' \
        "$visible_wayland" "$visible_x11" >> "$LOG_FILE"
    catalog_ok=0
fi
if [ "$catalog_ok" -eq 1 ]; then
    printf 'Visible entries: GNOME, Hyprland, Mango, Niri, Plasma, Sway, XFCE\n'
    ok
else
    fail_check "the visible session catalogue is not exactly six Wayland sessions plus XFCE X11"
fi

show_step 12 "$TOTAL" "Checking Fcitx5"
if busctl --user --list 2>> "$LOG_FILE" | rg -q 'org\.fcitx\.Fcitx5'; then
    fcitx_state="$(timeout 5 fcitx5-remote 2>> "$LOG_FILE" || true)"
    printf 'Fcitx state: %s\n' "${fcitx_state:-unknown}" >> "$LOG_FILE"
    ok
else
    warn "Fcitx5 is not running in this desktop session"
fi

show_step 13 "$TOTAL" "Checking keyboard receiver classification"
receiver_seen=0
joystick_seen=0
for event_path in /dev/input/event*; do
    [ -e "$event_path" ] || continue
    properties="$(udevadm info -q property -n "$event_path" 2>/dev/null || true)"
    if printf '%s\n' "$properties" | rg -q \
           '^(ID_VENDOR_ID|ID_USB_VENDOR_ID)=36b0$' &&
       printf '%s\n' "$properties" | rg -q \
           '^(ID_MODEL_ID|ID_USB_MODEL_ID)=3002$'; then
        receiver_seen=1
        printf 'Receiver interface: %s\n' "$event_path" >> "$LOG_FILE"
        printf '%s\n' "$properties" | rg '^ID_INPUT' >> "$LOG_FILE" || true
        if printf '%s\n' "$properties" | rg -q '^ID_INPUT_JOYSTICK=1$'; then
            joystick_seen=1
        fi
    fi
done
if [ "$joystick_seen" -eq 1 ]; then
    fail_check "the 36b0:3002 keyboard receiver is still marked as a joystick"
elif [ "$receiver_seen" -eq 1 ]; then
    ok
else
    skips=$((skips + 1))
    show_skipped 'Keyboard receiver is not connected; runtime classification cannot be tested.'
fi

show_step 14 "$TOTAL" "Checking disk space"
root_used="$(df -P / 2>> "$LOG_FILE" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
printf 'Root filesystem used: %s%%\n' "${root_used:-unknown}" >> "$LOG_FILE"
if [[ "$root_used" =~ ^[0-9]+$ ]] && [ "$root_used" -lt 85 ]; then
    ok
elif [[ "$root_used" =~ ^[0-9]+$ ]] && [ "$root_used" -lt 95 ]; then
    warn "root filesystem usage is ${root_used}%"
elif [[ "$root_used" =~ ^[0-9]+$ ]]; then
    fail_check "root filesystem usage is critically high at ${root_used}%"
else
    fail_check "could not determine root filesystem usage"
fi

show_step 15 "$TOTAL" "Checking important commands"
missing_commands=()
for command_name in \
    codex claude python3 git gh chromium kitty nvim flatpak steam obs; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands+=("$command_name")
    fi
done
if [ "${#missing_commands[@]}" -eq 0 ]; then
    ok
else
    warn "missing commands: ${missing_commands[*]}"
fi

show_step 16 "$TOTAL" "Checking Git configuration backup"
if [ ! -d "$BACKUP_REPO/.git" ]; then
    fail_check "Git backup repository is missing: $BACKUP_REPO"
else
    git_name="$(git -C "$BACKUP_REPO" config --get user.name || true)"
    git_email="$(git -C "$BACKUP_REPO" config --get user.email || true)"
    if ! git_changes="$(git -C "$BACKUP_REPO" status --porcelain 2>> "$LOG_FILE")"; then
        fail_check "could not query the Git backup repository"
    elif [ -z "$git_name" ] || [ -z "$git_email" ]; then
        warn "Git author identity is not configured"
    elif [ -n "$git_changes" ]; then
        show_ok 'Local Git work is present and preserved; a dirty tree is not a health failure.'
    else
        ok
    fi
fi

show_step 17 "$TOTAL" 'Comparing running, booted and staged system paths'
if running_system="$(readlink -f /run/current-system)" &&
   booted_system="$(readlink -f /run/booted-system)" &&
   staged_system="$(readlink -f /nix/var/nix/profiles/system)"; then
    show_ok
    show_detail "Running: $running_system"
    show_detail "Booted:  $booted_system"
    show_detail "Profile: $staged_system"
    if [ "$running_system" != "$staged_system" ]; then
        show_detail 'The profile differs from the live system; this can be an intentional next-boot staging state.'
    fi
else
    fail_check 'Could not resolve one or more system paths'
fi

printf '\n'
if [ "$failures" -eq 0 ] && [ "$warnings" -eq 0 ] && [ "$skips" -eq 0 ]; then
    printf 'AUTOMATED CONFIGURATION AND RUNTIME CHECKS PASSED\n'
    result="Healthy"
    warning_text="None"
    exit_status=0
elif [ "$failures" -eq 0 ]; then
    printf 'SYSTEM NEEDS ATTENTION\n'
    printf 'Failed checks: %s; warnings: %s; skipped: %s\n' "$failures" "$warnings" "$skips"
    result="Healthy with warnings"
    warning_text="$failures failed checks; $warnings warnings. See $LOG_FILE"
    exit_status=1
else
    printf 'SYSTEM NEEDS ATTENTION\n'
    printf 'Failed checks: %s; warnings: %s; skipped: %s\n' "$failures" "$warnings" "$skips"
    result="Failed checks require attention"
    warning_text="$failures failed checks; $warnings warnings. See $LOG_FILE"
    exit_status=2
fi

printf 'Detailed log: %s\n' "$LOG_FILE"
show_detail 'Configuration parsing does not verify interactive desktop behavior, audible quality, or physical hardware tests.'
write_maintenance_state \
    "Read-only health check" "$result" \
    "NixOS, services, network, DNS, Bluetooth, audio, desktop configs and session catalogue, input, disk, commands, Git" \
    "Only the health log and maintenance state" "$warning_text"

exit "$exit_status"
