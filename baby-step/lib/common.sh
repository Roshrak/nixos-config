#!/usr/bin/env bash

# Shared, small helpers for the beginner-facing maintenance scripts.
# This file is not intended to be run directly.

BABY_STEP_DIR="${BABY_STEP_DIR:-$HOME/baby-step}"
NIXOS_DIR="${NIXOS_DIR:-/etc/nixos}"
BACKUP_REPO="${BACKUP_REPO:-$HOME/nixos-config}"
LOG_DIR="$BABY_STEP_DIR/logs"
STATE_DIR="$BABY_STEP_DIR/state"
BACKUP_DIR="$BABY_STEP_DIR/backups"

LOG_FILE=""
FLAKE_ATTR=""
FLAKE_TARGET=""
MAINTENANCE_LOCK_FD="${MAINTENANCE_LOCK_FD:-}"

ensure_baby_dirs() {
    mkdir -p "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"
}

start_log() {
    local kind="$1"
    local stamp

    if ! ensure_baby_dirs; then
        printf 'ERROR: Could not create maintenance directories under %s\n' \
            "$BABY_STEP_DIR" >&2
        exit 1
    fi
    stamp="$(date +%F-%H%M%S)"
    LOG_FILE="$LOG_DIR/${kind}-${stamp}.log"
    if ! : > "$LOG_FILE" || ! chmod 600 "$LOG_FILE" ||
       ! printf 'Started: %s\n' "$(date --iso-8601=seconds)" >> "$LOG_FILE" ||
       ! printf 'Command: %s\n' "$kind" >> "$LOG_FILE"; then
        printf 'ERROR: Could not create maintenance log: %s\n' "$LOG_FILE" >&2
        exit 1
    fi
}

acquire_maintenance_lock() {
    local inherited_lock=""

    command -v flock >/dev/null 2>&1 || fatal "Missing required command: flock"
    if [ "${BABY_STEP_LOCK_HELD:-0}" -eq 1 ] &&
       [[ "$MAINTENANCE_LOCK_FD" =~ ^[0-9]+$ ]]; then
        inherited_lock="$(readlink -f "/proc/$$/fd/$MAINTENANCE_LOCK_FD" \
            2>/dev/null || true)"
        if [ "$inherited_lock" = "$STATE_DIR/maintenance.lock" ]; then
            flock -n "$MAINTENANCE_LOCK_FD" ||
                fatal "Another baby-step maintenance command is already running"
            return 0
        fi
    fi
    ensure_baby_dirs || fatal "Could not prepare the maintenance state directory"
    if ! exec {MAINTENANCE_LOCK_FD}> "$STATE_DIR/maintenance.lock"; then
        fatal "Could not open the maintenance lock"
    fi
    chmod 600 "$STATE_DIR/maintenance.lock" || fatal "Could not secure the maintenance lock"
    if ! flock -n "$MAINTENANCE_LOCK_FD"; then
        fatal "Another baby-step maintenance command is already running"
    fi
    export BABY_STEP_LOCK_HELD=1 MAINTENANCE_LOCK_FD
}

log_note() {
    printf '%s\n' "$*" >> "$LOG_FILE"
}

show_step() {
    local number="$1"
    local total="$2"
    shift 2
    printf '[%s/%s] %s... ' "$number" "$total" "$*"
}

show_ok() {
    printf 'OK\n'
}

show_warning() {
    printf 'WARNING\n'
}

show_failed() {
    printf 'FAILED\n'
}

fatal() {
    local message="$*"

    printf '\nERROR: %s\n' "$message" >&2
    if [ -n "$LOG_FILE" ]; then
        printf 'ERROR: %s\n' "$message" >> "$LOG_FILE"
        printf 'Detailed log: %s\n' "$LOG_FILE" >&2
    fi
    exit 1
}

run_logged() {
    local description="$1"
    local status
    shift

    printf '\n--- %s ---\n' "$description" >> "$LOG_FILE"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        status=$?
    fi

    printf 'Command failed with exit code %s\n' "$status" >> "$LOG_FILE"
    return "$status"
}

require_commands() {
    local missing=0
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'Missing required command: %s\n' "$command_name" >> "$LOG_FILE"
            missing=1
        fi
    done

    [ "$missing" -eq 0 ]
}

detect_flake_target() {
    local attrs_json
    local count
    local host_name
    local candidate
    local candidate_host

    [ -f "$NIXOS_DIR/flake.nix" ] || return 1

    attrs_json="$(nix eval --json "$NIXOS_DIR#nixosConfigurations" \
        --apply builtins.attrNames 2>> "$LOG_FILE")" || return 1
    count="$(jq 'length' <<< "$attrs_json")" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    host_name="$(hostname)"
    if [ "$count" -eq 1 ]; then
        FLAKE_ATTR="$(jq -r '.[0]' <<< "$attrs_json")"
    elif [ "$count" -gt 1 ]; then
        while IFS= read -r candidate; do
            candidate_host="$(nix eval --raw \
                "$NIXOS_DIR#nixosConfigurations.${candidate}.config.networking.hostName" \
                2>> "$LOG_FILE" || true)"
            if [ "$candidate_host" = "$host_name" ]; then
                if [ -n "$FLAKE_ATTR" ]; then
                    printf 'More than one configuration matches hostname %s.\n' \
                        "$host_name" >> "$LOG_FILE"
                    return 1
                fi
                FLAKE_ATTR="$candidate"
            fi
        done < <(jq -r '.[]' <<< "$attrs_json")
    fi

    [ -n "$FLAKE_ATTR" ] || return 1
    case "$FLAKE_ATTR" in
        *[!A-Za-z0-9._+-]*) return 1 ;;
    esac

    candidate_host="$(nix eval --raw \
        "$NIXOS_DIR#nixosConfigurations.${FLAKE_ATTR}.config.networking.hostName" \
        2>> "$LOG_FILE")" || return 1
    if [ "$candidate_host" != "$host_name" ]; then
        printf 'Configuration %s has hostname %s, but this computer is %s.\n' \
            "$FLAKE_ATTR" "$candidate_host" "$host_name" >> "$LOG_FILE"
        return 1
    fi

    FLAKE_TARGET="$NIXOS_DIR#$FLAKE_ATTR"
    printf 'Detected flake target: %s\n' "$FLAKE_TARGET" >> "$LOG_FILE"
}

current_generation() {
    nixos-rebuild list-generations --json 2>/dev/null |
        jq -r '.[] | select(.current == true) | .generation' |
        head -n 1
}

marker_value() {
    local marker="$1"
    local path="$STATE_DIR/last-${marker}.txt"

    if [ -s "$path" ]; then
        sed -n '1p' "$path"
    else
        printf 'Not recorded'
    fi
}

record_success() {
    local marker="$1"
    shift
    local path="$STATE_DIR/last-${marker}.txt"
    local temporary

    ensure_baby_dirs || fatal "Could not prepare the maintenance state directory"
    temporary="$(mktemp "$STATE_DIR/.last-${marker}.XXXXXX")" ||
        fatal "Could not create a temporary state file"
    if ! printf '%s — %s\n' "$(date --iso-8601=seconds)" "$*" > "$temporary" ||
       ! mv -f "$temporary" "$path"; then
        rm -f -- "$temporary"
        fatal "Could not save maintenance state: $path"
    fi
}

write_maintenance_state() {
    local action="$1"
    local result="$2"
    local checks="$3"
    local files_changed="$4"
    local warnings="$5"
    local temporary
    local generation

    ensure_baby_dirs || fatal "Could not prepare the maintenance state directory"
    generation="$(current_generation || true)"
    [ -n "$generation" ] || generation="Unknown"
    temporary="$(mktemp "$STATE_DIR/.maintenance.XXXXXX")" ||
        fatal "Could not create a temporary maintenance record"

    {
        printf 'Date: %s\n' "$(date --iso-8601=seconds)"
        printf 'Current system generation: %s\n' "$generation"
        printf 'Flake configuration detected: %s\n' "${FLAKE_TARGET:-Not detected}"
        printf 'Last action: %s\n' "$action"
        printf 'Result: %s\n' "$result"
        printf 'Checks completed: %s\n' "$checks"
        printf 'Files modified: %s\n' "$files_changed"
        printf 'Outstanding warnings: %s\n' "$warnings"
        printf 'Last successful system build: %s\n' "$(marker_value build)"
        printf 'Last successful system switch: %s\n' "$(marker_value switch)"
        printf 'Last successful Git backup: %s\n' "$(marker_value git-backup)"
    } > "$temporary" || {
        rm -f -- "$temporary"
        fatal "Could not write the maintenance record"
    }

    if ! mv -f "$temporary" "$STATE_DIR/last-maintenance.txt"; then
        rm -f -- "$temporary"
        fatal "Could not save the maintenance record"
    fi
}
