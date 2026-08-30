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

ensure_baby_dirs() {
    mkdir -p "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"
}

start_log() {
    local kind="$1"
    local stamp

    ensure_baby_dirs
    stamp="$(date +%F-%H%M%S)"
    LOG_FILE="$LOG_DIR/${kind}-${stamp}.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    printf 'Started: %s\n' "$(date --iso-8601=seconds)" >> "$LOG_FILE"
    printf 'Command: %s\n' "$kind" >> "$LOG_FILE"
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
    count="$(jq 'length' <<< "$attrs_json")"

    if [ "$count" -eq 1 ]; then
        FLAKE_ATTR="$(jq -r '.[0]' <<< "$attrs_json")"
    elif [ "$count" -gt 1 ]; then
        host_name="$(hostname)"
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

    ensure_baby_dirs
    temporary="$(mktemp "$STATE_DIR/.last-${marker}.XXXXXX")"
    printf '%s — %s\n' "$(date --iso-8601=seconds)" "$*" > "$temporary"
    mv -f "$temporary" "$path"
}

write_maintenance_state() {
    local action="$1"
    local result="$2"
    local checks="$3"
    local files_changed="$4"
    local warnings="$5"
    local temporary
    local generation

    ensure_baby_dirs
    generation="$(current_generation)"
    [ -n "$generation" ] || generation="Unknown"
    temporary="$(mktemp "$STATE_DIR/.maintenance.XXXXXX")"

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
    } > "$temporary"

    mv -f "$temporary" "$STATE_DIR/last-maintenance.txt"
}
