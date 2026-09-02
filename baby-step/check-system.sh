#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

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
TOTAL=14

ok() {
    show_ok
}

warn() {
    show_warning
    warnings=$((warnings + 1))
    printf 'WARNING: %s\n' "$*" >> "$LOG_FILE"
}

fail_check() {
    show_failed
    failures=$((failures + 1))
    printf 'FAILED: %s\n' "$*" >> "$LOG_FILE"
}

if ! require_commands \
    nix jq hostname nixos-rebuild systemctl nmcli getent timeout mango niri \
    noctalia busctl rg fcitx5-remote wpctl udevadm df awk git; then
    printf 'ERROR: A command required by the health check is missing.\n' >&2
    printf 'See the detailed log: %s\n' "$LOG_FILE" >&2
    write_maintenance_state \
        "Read-only health check" "Health check could not run" \
        "Required-command preflight" "Only the health log and maintenance state" \
        "One or more required commands are missing; see $LOG_FILE"
    exit 2
fi

printf 'Checking this computer. This does not change system settings.\n\n'

show_step 1 "$TOTAL" "Checking NixOS configuration"
if detect_flake_target &&
   nix eval --raw \
       "$NIXOS_DIR#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.drvPath" \
       >> "$LOG_FILE" 2>&1; then
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
if [ -f "$HOME/.config/mango/config.conf" ] &&
   timeout 15 mango -c "$HOME/.config/mango/config.conf" -p \
       >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "Mango configuration parser reported an error"
fi

show_step 8 "$TOTAL" "Checking Niri configuration"
if timeout 15 niri validate >> "$LOG_FILE" 2>&1; then
    ok
else
    fail_check "Niri configuration validation failed"
fi

show_step 9 "$TOTAL" "Checking Noctalia & Sway configuration"
if timeout 15 noctalia config validate >> "$LOG_FILE" 2>&1 && \
   ([ ! -f "$HOME/.config/sway/config" ] || ! command -v sway >/dev/null 2>&1 || \
    timeout 15 sway -C -c "$HOME/.config/sway/config" >> "$LOG_FILE" 2>&1); then
    ok
else
    fail_check "Noctalia or Sway configuration validation failed"
fi

show_step 10 "$TOTAL" "Checking Fcitx5"
if busctl --user --list 2>> "$LOG_FILE" | rg -q 'org\.fcitx\.Fcitx5'; then
    fcitx_state="$(timeout 5 fcitx5-remote 2>> "$LOG_FILE" || true)"
    printf 'Fcitx state: %s\n' "${fcitx_state:-unknown}" >> "$LOG_FILE"
    ok
else
    warn "Fcitx5 is not running in this desktop session"
fi

show_step 11 "$TOTAL" "Checking keyboard receiver classification"
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
    printf 'NOT CONNECTED\n'
    printf 'Keyboard receiver was not connected; rule remains configured.\n' >> "$LOG_FILE"
fi

show_step 12 "$TOTAL" "Checking disk space"
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

show_step 13 "$TOTAL" "Checking important commands"
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

show_step 14 "$TOTAL" "Checking Git configuration backup"
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
        warn "the Git backup has changes that are not yet committed"
    else
        ok
    fi
fi

printf '\n'
if [ "$failures" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf 'SYSTEM LOOKS HEALTHY\n'
    result="Healthy"
    warning_text="None"
    exit_status=0
elif [ "$failures" -eq 0 ]; then
    printf 'SYSTEM NEEDS ATTENTION\n'
    printf 'Failed checks: %s; warnings: %s\n' "$failures" "$warnings"
    result="Healthy with warnings"
    warning_text="$failures failed checks; $warnings warnings. See $LOG_FILE"
    exit_status=1
else
    printf 'SYSTEM NEEDS ATTENTION\n'
    printf 'Failed checks: %s; warnings: %s\n' "$failures" "$warnings"
    result="Failed checks require attention"
    warning_text="$failures failed checks; $warnings warnings. See $LOG_FILE"
    exit_status=2
fi

printf 'Detailed log: %s\n' "$LOG_FILE"
write_maintenance_state \
    "Read-only health check" "$result" \
    "NixOS, services, network, DNS, Bluetooth, audio, desktops, input, disk, commands, Git" \
    "Only the health log and maintenance state" "$warning_text"

exit "$exit_status"
