#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

build_only=0
case "${1:-}" in
    "") ;;
    --build-only) build_only=1 ;;
    -h|--help)
        printf 'Build and safely activate the detected NixOS configuration.\n'
        printf 'Run: %s\n' "$HOME/baby-step/rebuild-system.sh"
        printf 'Safe test without activation: %s --build-only\n' "$HOME/baby-step/rebuild-system.sh"
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

start_log "rebuild"
acquire_maintenance_lock
TOTAL=7
BUILD_WORK=""
active_before="$(readlink -f /run/current-system)"

cleanup() {
    if [ -n "$BUILD_WORK" ]; then
        case "$BUILD_WORK" in
            "$STATE_DIR"/build.*) rm -rf -- "$BUILD_WORK" ;;
        esac
    fi
}
trap cleanup EXIT

printf 'Preparing a safe NixOS rebuild.\n\n'

show_step 1 "$TOTAL" "Checking required commands"
if require_commands nix jq hostname df nixos-rebuild systemctl; then
    show_ok
else
    show_failed
    fatal "A required system command is missing"
fi

show_step 2 "$TOTAL" "Detecting this computer's flake configuration"
if detect_flake_target; then
    show_ok
    printf '  Using: %s\n' "$FLAKE_TARGET"
else
    show_failed
    fatal "Could not safely determine the NixOS flake target"
fi

show_step 3 "$TOTAL" "Evaluating the configuration"
if run_logged "NixOS evaluation" nix eval --raw \
       "$NIXOS_DIR#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.drvPath"; then
    show_ok
else
    show_failed
    write_maintenance_state "NixOS rebuild" "Evaluation failed; nothing activated" \
        "Flake detection and evaluation" "None" "See $LOG_FILE"
    fatal "Configuration evaluation failed. Nothing was activated."
fi

if [ "$build_only" -eq 0 ]; then
    printf '\nYour password may be requested now. Type it in this Terminal and press Enter.\n'
    printf 'The password will not be displayed while you type.\n\n'
    if ! sudo -v; then
        fatal "sudo authentication failed. Nothing was activated."
    fi
fi

BUILD_WORK="$(mktemp -d "$STATE_DIR/build.XXXXXX")"
show_step 4 "$TOTAL" "Building the new system"
if (
    cd "$BUILD_WORK" || exit 1
    nixos-rebuild build --flake "$FLAKE_TARGET"
) >> "$LOG_FILE" 2>&1; then
    built_system="$(readlink -f "$BUILD_WORK/result" 2>/dev/null || true)"
    show_ok
    record_success build "$FLAKE_TARGET -> ${built_system:-build completed}"
else
    show_failed
    write_maintenance_state "NixOS rebuild" "Build failed; nothing activated" \
        "Flake detection, evaluation, candidate build" "None" "See $LOG_FILE"
    fatal "The build failed. Your running NixOS generation is unchanged."
fi

if [ "$build_only" -eq 1 ]; then
    show_step 5 "$TOTAL" "Keeping the current running generation"
    show_ok
    show_step 6 "$TOTAL" "Checking that no switch occurred"
    active_after="$(readlink -f /run/current-system)"
    if [ "$active_after" = "$active_before" ]; then
        show_ok
    else
        show_failed
        fatal "The active system changed unexpectedly during the build-only test"
    fi
    show_step 7 "$TOTAL" "Saving maintenance status"
    write_maintenance_state "NixOS build-only test" "Build succeeded; not activated" \
        "Flake detection, evaluation, candidate build" "Only log and state files" \
        "Candidate still needs a switch"
    show_ok
    printf '\nSUCCESS: The configuration builds correctly. Nothing was activated.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

show_step 5 "$TOTAL" "Activating the successfully built system"
if run_logged "NixOS switch" sudo nixos-rebuild switch --flake "$FLAKE_TARGET"; then
    active_system="$(readlink -f /run/current-system)"
    if [ -z "$built_system" ] || [ "$active_system" != "$built_system" ]; then
        show_failed
        write_maintenance_state "NixOS rebuild" \
            "Switch completed with a system different from the validated candidate" \
            "Flake detection, evaluation, candidate build, switch, artifact comparison" \
            "/run/current-system changed" "Stop and inspect $LOG_FILE"
        fatal "The active system does not match the validated build."
    fi
    show_ok
    record_success switch "$FLAKE_TARGET -> $active_system"
else
    show_failed
    write_maintenance_state "NixOS rebuild" "Build succeeded, switch failed" \
        "Flake detection, evaluation, candidate build, attempted switch" \
        "None" "Running generation may be unchanged; see $LOG_FILE"
    fatal "The build succeeded, but activation failed. See the log before retrying."
fi

show_step 6 "$TOTAL" "Checking services after activation"
service_query_failed=0
if ! system_failed="$(systemctl --failed --no-legend --plain 2>> "$LOG_FILE")"; then
    service_query_failed=1
    system_failed=""
fi
if ! user_failed="$(systemctl --user --failed --no-legend --plain 2>> "$LOG_FILE")"; then
    service_query_failed=1
    user_failed=""
fi
if [ "$service_query_failed" -eq 0 ] &&
   [ -z "$system_failed" ] && [ -z "$user_failed" ]; then
    show_ok
    service_warning="None"
else
    show_warning
    printf '%s\n%s\n' "$system_failed" "$user_failed" >> "$LOG_FILE"
    if [ "$service_query_failed" -ne 0 ]; then
        service_warning="The system switched, but service health could not be queried; see $LOG_FILE"
    else
        service_warning="The system switched, but one or more services failed; see $LOG_FILE"
    fi
fi

show_step 7 "$TOTAL" "Saving maintenance status"
write_maintenance_state "NixOS rebuild and switch" "Build and switch succeeded" \
    "Flake detection, evaluation, build, switch, service check" \
    "/run/current-system and NixOS generation" "$service_warning"
show_ok

if [ "$service_warning" = "None" ]; then
    printf '\nSUCCESS: The NixOS rebuild completed correctly.\n'
else
    printf '\nREBUILD COMPLETED, BUT THE SYSTEM NEEDS ATTENTION.\n'
fi
printf 'Active system: %s\n' "$(readlink -f /run/current-system)"
printf 'Detailed log: %s\n' "$LOG_FILE"

if [ "$service_warning" != "None" ]; then
    exit 1
fi
