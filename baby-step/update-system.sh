#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

check_only=0
case "${1:-}" in
    "") ;;
    --check-only) check_only=1 ;;
    -h|--help)
        printf 'Update NixOS safely: back up, update, evaluate, build, then switch.\n'
        printf 'Run: %s\n' "$HOME/baby-step/update-system.sh"
        printf 'Safety checks only: %s --check-only\n' "$HOME/baby-step/update-system.sh"
        exit 0
        ;;
    *)
        printf 'ERROR: Unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    printf 'ERROR: Run this as your normal user, not with sudo.\n' >&2
    exit 1
fi

start_log "update"
TOTAL=8
BUILD_WORK=""
lock_backup=""
lock_updated=0

cleanup() {
    if [ -n "$BUILD_WORK" ]; then
        case "$BUILD_WORK" in
            "$STATE_DIR"/update-build.*) rm -rf -- "$BUILD_WORK" ;;
        esac
    fi
}
trap cleanup EXIT

restore_lock() {
    [ "$lock_updated" -eq 1 ] || return 0
    [ -n "$lock_backup" ] || return 0
    [ -f "$lock_backup" ] || return 0

    printf 'Restoring the previous flake.lock after the failed update.\n' >> "$LOG_FILE"
    if cp -a "$lock_backup" "$NIXOS_DIR/flake.lock" >> "$LOG_FILE" 2>&1; then
        lock_updated=0
        return 0
    fi
    if sudo cp -a "$lock_backup" "$NIXOS_DIR/flake.lock" >> "$LOG_FILE" 2>&1; then
        lock_updated=0
        return 0
    fi
    printf 'WARNING: Could not restore the previous flake.lock automatically.\n' \
        >> "$LOG_FILE"
    return 1
}

printf 'Starting a safe system update.\n\n'

show_step 1 "$TOTAL" "Checking commands, disk space, and flake target"
free_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"
if require_commands nix jq hostname df nixos-rebuild systemctl sudo &&
   [ "$free_kib" -ge 5242880 ] &&
   detect_flake_target; then
    show_ok
    printf '  Using: %s\n' "$FLAKE_TARGET"
else
    show_failed
    fatal "Prerequisite check failed; at least 5 GiB free space is required"
fi

if [ "$check_only" -eq 1 ]; then
    printf '\nSUCCESS: Update safety checks passed. Nothing was changed.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    write_maintenance_state "Update safety check" "Passed; no update performed" \
        "Commands, disk space, flake detection" "Only log and state files" "None"
    exit 0
fi

printf '\nYour password may be requested now. Type it in this Terminal and press Enter.\n'
printf 'The password will not be displayed while you type.\n\n'
if ! sudo -v; then
    fatal "sudo authentication failed. Nothing was updated."
fi

show_step 2 "$TOTAL" "Creating a safety backup of flake.lock"
if [ -f "$NIXOS_DIR/flake.lock" ]; then
    lock_backup="$BACKUP_DIR/flake.lock.before-update-$(date +%F-%H%M%S)"
    if cp -a "$NIXOS_DIR/flake.lock" "$lock_backup" >> "$LOG_FILE" 2>&1; then
        show_ok
    else
        show_failed
        fatal "Could not back up flake.lock"
    fi
else
    show_warning
    printf 'No existing flake.lock was found.\n' >> "$LOG_FILE"
fi

show_step 3 "$TOTAL" "Updating Nix flake inputs"
lock_updated=1
if run_logged "Nix flake update" nix flake update --flake "$NIXOS_DIR"; then
    show_ok
else
    show_failed
    restore_lock || true
    write_maintenance_state "System update" "Flake update failed; nothing activated" \
        "Prerequisites and lock backup" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "Nix flake update failed. Your running system was not changed."
fi

show_step 4 "$TOTAL" "Evaluating the updated configuration"
if run_logged "Updated NixOS evaluation" nix eval --raw \
       "$NIXOS_DIR#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.drvPath"; then
    show_ok
else
    show_failed
    restore_lock || true
    write_maintenance_state "System update" "Evaluation failed; nothing activated" \
        "Flake update and evaluation" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "The updated configuration did not evaluate. Nothing was activated."
fi

BUILD_WORK="$(mktemp -d "$STATE_DIR/update-build.XXXXXX")"
show_step 5 "$TOTAL" "Building the updated system"
if (
    cd "$BUILD_WORK" || exit 1
    nixos-rebuild build --flake "$FLAKE_TARGET"
) >> "$LOG_FILE" 2>&1; then
    built_system="$(readlink -f "$BUILD_WORK/result" 2>/dev/null || true)"
    show_ok
    record_success build "$FLAKE_TARGET -> ${built_system:-build completed}"
else
    show_failed
    restore_lock || true
    write_maintenance_state "System update" "Build failed; nothing activated" \
        "Flake update, evaluation, candidate build" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "The build failed. Your running NixOS generation is unchanged."
fi

show_step 6 "$TOTAL" "Activating the successfully built system"
if run_logged "NixOS switch" sudo nixos-rebuild switch --flake "$FLAKE_TARGET"; then
    show_ok
    active_system="$(readlink -f /run/current-system)"
    record_success switch "$FLAKE_TARGET -> $active_system"
else
    show_failed
    write_maintenance_state "System update" "Build succeeded, switch failed" \
        "Flake update, evaluation, build, attempted switch" \
        "Updated flake.lock remains in place" "See $LOG_FILE"
    fatal "The build succeeded, but activation failed. Do not retry randomly."
fi

show_step 7 "$TOTAL" "Updating safe non-Nix items"
non_nix_warning=0
if command -v flatpak >/dev/null 2>&1; then
    run_logged "Flatpak update" timeout 900 flatpak update -y || non_nix_warning=1
fi
if command -v fwupdmgr >/dev/null 2>&1; then
    run_logged "Firmware metadata refresh" timeout 180 fwupdmgr refresh --force || \
        non_nix_warning=1
    run_logged "Firmware update check (no installation)" timeout 120 fwupdmgr get-updates || true
fi
if [ "$non_nix_warning" -eq 0 ]; then
    show_ok
else
    show_warning
fi

show_step 8 "$TOTAL" "Running the final health check"
if "$SCRIPT_DIR/check-system.sh" >> "$LOG_FILE" 2>&1; then
    show_ok
    health_warning="None"
else
    show_warning
    health_warning="The update switched successfully, but the health check has warnings; see $LOG_FILE"
fi

write_maintenance_state "System update" "Update, build, and switch succeeded" \
    "Flake update, evaluation, build, switch, non-Nix updates, health check" \
    "flake.lock, Nix store, active generation, Flatpak metadata/apps when available" \
    "$health_warning"

printf '\nSUCCESS: Your system update completed correctly.\n'
if [ "$non_nix_warning" -ne 0 ] || [ "$health_warning" != "None" ]; then
    printf 'The main NixOS update succeeded, with a non-fatal warning in the log.\n'
fi
printf 'Detailed log: %s\n' "$LOG_FILE"
