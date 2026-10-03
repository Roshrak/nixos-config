#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

check_only=0
[ "$#" -le 1 ] || { printf 'ERROR: Use one option at a time.\n' >&2; exit 2; }
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
acquire_maintenance_lock
TOTAL=9
[ "$check_only" -eq 0 ] || TOTAL=1
BUILD_WORK=""
lock_backup=""
lock_updated=0
lock_existed=0
lock_updated_identity=''
activation_attempted=0
fallback_before=""
update_run_id="${MAINTENANCE_RUN_ID:-$(date +%s)-$$}"

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [ -n "$BUILD_WORK" ]; then
        case "$BUILD_WORK" in
            "$STATE_DIR"/update-build.*) rm -rf -- "$BUILD_WORK" ;;
        esac
    fi
    if [ "$status" -ne 0 ] && [ "$activation_attempted" -eq 0 ] &&
       [ "$lock_updated" -eq 1 ]; then
        if ! restore_lock; then
            printf 'ERROR: The previous flake.lock could not be restored. See %s\n' \
                "$LOG_FILE" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "Interrupted before completion.\n" >> "$LOG_FILE"; exit 130' INT TERM HUP

restore_lock() {
    [ "$lock_updated" -eq 1 ] || return 0

    if [ -z "$lock_updated_identity" ] || [ -L "$NIXOS_DIR/flake.lock" ] ||
       [ "$(lock_identity)" != "$lock_updated_identity" ]; then
        printf 'ERROR: flake.lock changed or its identity is unknown; preserving it. Before-image: %s\n' \
            "${lock_backup:-no prior lock existed}" | tee -a "$LOG_FILE" >&2
        return 1
    fi

    printf 'Restoring the previous flake.lock after the failed update.\n' >> "$LOG_FILE"
    if [ "$lock_existed" -eq 0 ]; then
        if [ ! -e "$NIXOS_DIR/flake.lock" ] ||
           rm -f -- "$NIXOS_DIR/flake.lock" >> "$LOG_FILE" 2>&1 ||
           run_logged "Remove this update's new lock" sudo -n rm -f -- "$NIXOS_DIR/flake.lock"; then
            lock_updated=0
            return 0
        fi
        printf 'WARNING: Could not remove the newly created flake.lock.\n' >> "$LOG_FILE"
        return 1
    fi

    [ -n "$lock_backup" ] && [ -f "$lock_backup" ] || return 1
    if cp -a "$lock_backup" "$NIXOS_DIR/flake.lock" >> "$LOG_FILE" 2>&1; then
        lock_updated=0
        return 0
    fi
    if run_logged "Restore the previous lock before-image" sudo -n cp -a "$lock_backup" "$NIXOS_DIR/flake.lock"; then
        lock_updated=0
        return 0
    fi
    printf 'WARNING: Could not restore the previous flake.lock automatically.\n' \
        >> "$LOG_FILE"
    return 1
}

lock_identity() {
    if [ ! -e "$NIXOS_DIR/flake.lock" ] && [ ! -L "$NIXOS_DIR/flake.lock" ]; then printf 'ABSENT\n'; return 0; fi
    [ -f "$NIXOS_DIR/flake.lock" ] && [ ! -L "$NIXOS_DIR/flake.lock" ] || return 1
    stat -c '%d:%i:%u:%g:%a' "$NIXOS_DIR/flake.lock" || return 1
    sha256sum "$NIXOS_DIR/flake.lock" || return 1
}

show_banner 'NixOS update' 'Back up lock -> update inputs -> evaluate -> build -> activate -> verify'
[ "$check_only" -eq 0 ] || show_detail 'CHECK ONLY: prerequisites and target detection; no update or build.'

show_step 1 "$TOTAL" "Checking commands, disk space, and flake target"
require_commands nix jq hostname df nixos-rebuild systemctl sudo timeout bootctl readlink sha256sum sort xargs stat mktemp || fatal 'A required update command is missing'
free_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"
boot_free_kib="$(df -Pk /boot | awk 'NR == 2 { print $4 }')"
if [[ "$free_kib" =~ ^[0-9]+$ && "$boot_free_kib" =~ ^[0-9]+$ ]] &&
    [ "$free_kib" -ge 5242880 ] &&
    [ "$boot_free_kib" -ge 262144 ] &&
    detect_flake_target; then
    show_ok
    printf '  Using: %s\n' "$FLAKE_TARGET"
else
    show_failed
    fatal "Prerequisite check failed; 5 GiB on / and 256 MiB on /boot are required"
fi

if [ "$check_only" -eq 1 ]; then
    printf '\nSUCCESS: Update safety checks passed.\n'
    printf 'No system configuration or packages were changed; log and state files were updated.\n'
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
[ ! -L "$NIXOS_DIR/flake.lock" ] || fatal 'Refusing a symlinked flake.lock, including a dangling link'
if [ -e "$NIXOS_DIR/flake.lock" ] && [ ! -f "$NIXOS_DIR/flake.lock" ]; then
    fatal 'flake.lock exists but is not a regular file; it was preserved'
fi
if [ -f "$NIXOS_DIR/flake.lock" ]; then
    lock_existed=1
    lock_backup="$(mktemp "$BACKUP_DIR/flake.lock.previous.XXXXXX")" || fatal 'Could not create a unique lock before-image'
    if cp -a "$NIXOS_DIR/flake.lock" "$lock_backup" >> "$LOG_FILE" 2>&1; then
        show_ok
    else
        show_failed
        fatal "Could not back up flake.lock"
    fi
else
    lock_existed=0
    show_warning
    printf 'No existing flake.lock was found.\n' >> "$LOG_FILE"
fi

show_step 3 "$TOTAL" "Updating Nix flake inputs"
lock_updated=1
update_command=(nix flake update --flake "path:$NIXOS_DIR")
if [ ! -w "$NIXOS_DIR" ] || { [ -e "$NIXOS_DIR/flake.lock" ] && [ ! -w "$NIXOS_DIR/flake.lock" ]; }; then
    update_command=(sudo -n "${update_command[@]}")
fi
if run_logged "Nix flake update" "${update_command[@]}"; then
    lock_updated_identity="$(lock_identity)" || fatal 'Updated flake.lock is not a regular readable file'
    show_ok
else
    lock_updated_identity="$(lock_identity)" || lock_updated_identity=''
    show_failed
    if ! restore_lock; then
        fatal "Nix flake update failed, and the previous flake.lock could not be restored."
    fi
    write_maintenance_state "System update" "Flake update failed; nothing activated" \
        "Prerequisites and lock backup" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "Nix flake update failed. Your running system was not changed."
fi

show_step 4 "$TOTAL" "Evaluating the updated configuration"
if run_logged "Updated NixOS evaluation" nix eval --no-write-lock-file --raw \
       "path:$NIXOS_DIR#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.drvPath"; then
    show_ok
else
    show_failed
    if ! restore_lock; then
        fatal "Evaluation failed, and the previous flake.lock could not be restored."
    fi
    write_maintenance_state "System update" "Evaluation failed; nothing activated" \
        "Flake update and evaluation" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "The updated configuration did not evaluate. Nothing was activated."
fi

validated_source_digest="$(configuration_source_digest)" || fatal 'Could not fingerprint the updated source'
BUILD_WORK="$(mktemp -d "$STATE_DIR/update-build.XXXXXX")" || fatal 'Could not create an isolated build directory'
show_step 5 "$TOTAL" "Building the updated system"
if (
    cd "$BUILD_WORK" || exit 1
    run_logged "NixOS build" nixos-rebuild build --no-write-lock-file --flake "$FLAKE_TARGET"
); then
    built_system="$(readlink -f "$BUILD_WORK/result" 2>/dev/null || true)"
    [ -n "$built_system" ] && [ -x "$built_system/init" ] || fatal 'Build returned success without a usable candidate system'
    [ "$(configuration_source_digest)" = "$validated_source_digest" ] || fatal 'Source changed during the build; candidate was not activated'
    show_ok
    record_success build "$FLAKE_TARGET -> ${built_system:-build completed}"
else
    show_failed
    if ! restore_lock; then
        fatal "The build failed, and the previous flake.lock could not be restored."
    fi
    write_maintenance_state "System update" "Build failed; nothing activated" \
        "Flake update, evaluation, candidate build" "flake.lock restored when possible" \
        "See $LOG_FILE"
    fatal "The build failed. Your running NixOS generation is unchanged."
fi

fallback_profile="/nix/var/nix/profiles/system-profiles/fallback"
fallback_before="$(readlink -f "$fallback_profile" 2>> "$LOG_FILE" || true)"
if [ -z "$fallback_before" ] || [ ! -x "$fallback_before/init" ]; then
    show_failed
    write_maintenance_state "System update" \
        "Named fallback could not be verified before activation" \
        "Flake update, evaluation, candidate build, fallback preflight" \
        "No system activation was attempted" \
        "Restore/verify the named fallback before updating; see $LOG_FILE"
    fatal "The named fallback system is unavailable. The new system was not activated."
fi
printf 'Fallback system before activation: %s\n' "$fallback_before" >> "$LOG_FILE"

show_step 6 "$TOTAL" "Running the dry activation preflight"
if run_logged "NixOS dry activation" sudo nixos-rebuild --no-reexec dry-activate --store-path "$built_system"; then
    show_ok
else
    show_failed
    if ! restore_lock; then
        fatal "Dry activation failed, and the previous flake.lock could not be restored."
    fi
    write_maintenance_state "System update" "Dry activation failed; running system unchanged" \
        "Flake update, evaluation, candidate build, fallback check, dry activation" \
        "flake.lock restored when possible" "See $LOG_FILE"
    fatal "Dry activation failed; the new system was not switched."
fi

show_step 7 "$TOTAL" "Activating the successfully built system"
[ "$(configuration_source_digest)" = "$validated_source_digest" ] || fatal 'Source changed before activation; candidate was not switched'
activation_attempted=1
if run_logged "NixOS switch" sudo nixos-rebuild --no-reexec switch --store-path "$built_system"; then
    active_system="$(readlink -f /run/current-system)"
    if [ -z "$built_system" ] || [ "$active_system" != "$built_system" ]; then
        show_failed
        write_maintenance_state "System update" \
            "Switch completed with a system different from the validated candidate" \
            "Flake update, evaluation, candidate build, switch, artifact comparison" \
            "Active generation changed; Git backup was not started" \
            "Stop and inspect $LOG_FILE"
        fatal "The active system does not match the validated build. Nothing will be pushed."
    fi

    current_gen="$(current_generation || true)"
    fallback_system="$(readlink -f "$fallback_profile" 2>> "$LOG_FILE" || true)"
    expected_boot_id="nixos-generation-${current_gen}.conf"
    if [[ ! "$current_gen" =~ ^[0-9]+$ ]] ||
       [ -z "$fallback_system" ] ||
       [ "$fallback_system" != "$fallback_before" ] ||
       [ "$fallback_system" = "$active_system" ] ||
       [ ! -x "$fallback_system/init" ] ||
       ! boot_entries="$(sudo -n bootctl list --json=short 2>> "$LOG_FILE")" ||
       ! jq -e --arg id "$expected_boot_id" --arg init "init=$active_system/init" \
           'any(.[]; .id == $id and .isDefault == true and ((.options // "") | contains($init)))' \
           <<< "$boot_entries" >/dev/null ||
       ! jq -e --arg init "init=$fallback_system/init" \
           'any(.[]; ((.options // "") | contains($init)))' \
           <<< "$boot_entries" >/dev/null; then
        show_failed
        write_maintenance_state "System update" \
            "System switched, but boot default/fallback verification failed" \
            "Flake update, evaluation, build, switch, active artifact, boot entry inspection" \
            "$active_system is active; boot profile was not independently verified" \
            "Keep the current and fallback generations; inspect $LOG_FILE before rebooting"
        fatal "System switched, but the newest generation is not verified as boot default with the named fallback available."
    fi

    show_ok
    printf '  Boot default: %s (generation %s)\n' "$expected_boot_id" "$current_gen"
    printf '  Named fallback unchanged; boot entry present: %s\n' "$fallback_system"
    record_success switch "$FLAKE_TARGET -> $active_system"
else
    show_failed
    write_maintenance_state "System update" "Build succeeded, switch failed" \
        "Flake update, evaluation, build, attempted switch" \
        "Updated flake.lock remains in place" "See $LOG_FILE"
    fatal "The build succeeded, but activation failed. Do not retry randomly."
fi

show_step 8 "$TOTAL" "Updating safe non-Nix items"
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
    show_warning 'Optional Flatpak/firmware metadata work failed; NixOS activation already completed. See the command output above.'
fi

show_step 9 "$TOTAL" "Running the final health check"
health_status=0
run_logged 'Post-update health check' "$SCRIPT_DIR/check-system.sh" || health_status=$?
case "$health_status" in
    0)
        show_ok
        health_warning="None"
        ;;
    1)
        health_warning="The update switched successfully with health warnings; see $LOG_FILE"
        show_warning "$health_warning"
        ;;
    *)
        show_failed
        write_maintenance_state "System update" \
            "Update and switch succeeded, but final health checks failed" \
            "Flake update, evaluation, build, switch, non-Nix updates, failed health check" \
            "flake.lock, Nix store, active generation, Flatpak metadata/apps when available" \
            "The active system needs attention; see $LOG_FILE"
        fatal "The system switched, but an important final health check failed. Nothing will be pushed."
        ;;
esac

receipt_health=passed
if [ "$health_status" -eq 1 ]; then
    receipt_health=warning
fi
if [ "$(configuration_source_digest)" != "$validated_source_digest" ] ||
   ! write_update_receipt "$update_run_id" "$receipt_health"; then
    show_failed
    write_maintenance_state "System update" \
        "System switched and health check completed, but the success receipt could not be verified" \
        "Flake update, evaluation, build, switch, boot/fallback validation, health check" \
        "The active generation remains switched; backup resume is disabled" \
        "Inspect $LOG_FILE and current state before proceeding"
    fatal "Could not record a trustworthy update receipt. No backup/push should proceed."
fi
printf 'Verified update receipt recorded for run %s.\n' "$update_run_id" >> "$LOG_FILE"

write_maintenance_state "System update" "Update, build, and switch succeeded" \
    "Flake update, evaluation, build, switch, non-Nix updates, health check" \
    "flake.lock, Nix store, active generation, Flatpak metadata/apps when available" \
    "$health_warning"

printf '\nSUCCESS: Your system update completed correctly.\n'
if [ "$non_nix_warning" -ne 0 ] || [ "$health_warning" != "None" ]; then
    printf 'The main NixOS update succeeded, with a non-fatal warning in the log.\n'
fi
printf 'Detailed log: %s\n' "$LOG_FILE"
