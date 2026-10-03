#!/usr/bin/env bash

# Shared, small helpers for the beginner-facing maintenance scripts.
# This file is not intended to be run directly.

BABY_STEP_DIR="${BABY_STEP_DIR:-$HOME/baby-step}"
NIXOS_SOURCE_POLICY_INVALID=0
if [ -z "${NIXOS_DIR+x}" ]; then
    NIXOS_DIR=/etc/nixos
    source_pointer="$BABY_STEP_DIR/state/nixos-source.path"
    if [ -e "$source_pointer" ] || [ -L "$source_pointer" ]; then
        if [ -f "$source_pointer" ] && [ ! -L "$source_pointer" ] &&
           [ "$(stat -c '%u:%a' -- "$source_pointer")" = "$(id -u):600" ]; then
            IFS= read -r NIXOS_DIR < "$source_pointer" || NIXOS_SOURCE_POLICY_INVALID=1
            case "$NIXOS_DIR" in
                /*) ;;
                *) NIXOS_SOURCE_POLICY_INVALID=1 ;;
            esac
            if ! cmp -s -- "$source_pointer" <(printf '%s\n' "$NIXOS_DIR") ||
               [[ "$NIXOS_DIR" == *[$'\r\t\n']* ]] || [ -L "$NIXOS_DIR" ]; then
                NIXOS_SOURCE_POLICY_INVALID=1
            fi
        else
            NIXOS_SOURCE_POLICY_INVALID=1
        fi
        [ "$NIXOS_SOURCE_POLICY_INVALID" -eq 0 ] || NIXOS_DIR=''
    fi
fi
BACKUP_REPO="${BACKUP_REPO:-$HOME/nixos-config}"
LOG_DIR="$BABY_STEP_DIR/logs"
STATE_DIR="$BABY_STEP_DIR/state"
BACKUP_DIR="$BABY_STEP_DIR/backups"
export GIT_OPTIONAL_LOCKS="${GIT_OPTIONAL_LOCKS:-0}"

noctalia_settings_syntax_check() {
    local config_home="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}"
    python3 - "$config_home/noctalia" <<'PY'
import json, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
if (root / 'config.toml').is_file():
    with (root / 'config.toml').open('rb') as f: tomllib.load(f)
elif (root / 'settings.json').is_file():
    json.loads((root / 'settings.json').read_text())
else:
    print('No settings file at the selected Noctalia configuration home.', file=sys.stderr)
    raise SystemExit(1)
PY
}
export -f noctalia_settings_syntax_check

# shellcheck source=lib/source-manifest.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/source-manifest.sh"

LOG_FILE=""
FLAKE_ATTR=""
FLAKE_TARGET=""
MAINTENANCE_LOCK_FD="${MAINTENANCE_LOCK_FD:-}"

ensure_baby_dirs() {
    local directory owner mode_text
    for directory in "$BABY_STEP_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"; do
        [ ! -L "$directory" ] || { printf 'ERROR: Maintenance directory is linked: %s\n' "$directory" >&2; return 1; }
        if [ ! -e "$directory" ]; then (umask 077; mkdir -p -- "$directory") || return 1; fi
        [ -d "$directory" ] || return 1
        owner="$(stat -c '%u' "$directory")" || return 1
        mode_text="$(stat -c '%a' "$directory")" || return 1
        [ "$owner" = "$(id -u)" ] && (( (8#$mode_text & 0022) == 0 )) || {
            printf 'ERROR: Maintenance directory is not owned and write-protected: %s\n' "$directory" >&2
            return 1
        }
    done
}

start_log() {
    local kind="$1"
    local stamp

    if ! ensure_baby_dirs; then
        printf 'ERROR: Could not create maintenance directories under %s\n' \
            "$BABY_STEP_DIR" >&2
        exit 1
    fi
    [[ "$kind" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'ERROR: Invalid log kind.\n' >&2; exit 2; }
    stamp="$(date +%F-%H%M%S)"
    LOG_FILE="$(umask 077; mktemp "$LOG_DIR/${kind}-${stamp}.XXXXXX.log")" || {
        printf 'ERROR: Could not create a private maintenance log.\n' >&2
        exit 1
    }
    if ! chmod 600 "$LOG_FILE" ||
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
    if [ -L "$STATE_DIR/maintenance.lock" ] ||
       { [ -e "$STATE_DIR/maintenance.lock" ] && [ ! -f "$STATE_DIR/maintenance.lock" ]; }; then
        fatal 'Maintenance lock is a symlink or non-file; it was preserved'
    fi
    # Read/write open creates an absent lock without truncating an existing file.
    if ! exec {MAINTENANCE_LOCK_FD}<> "$STATE_DIR/maintenance.lock"; then
        fatal "Could not open the maintenance lock"
    fi
    inherited_lock="$(readlink -f "/proc/$$/fd/$MAINTENANCE_LOCK_FD")" || fatal 'Could not verify the opened lock'
    if [ "$inherited_lock" != "$STATE_DIR/maintenance.lock" ] ||
       [ ! -f "/proc/$$/fd/$MAINTENANCE_LOCK_FD" ] ||
       [ "$(stat -Lc '%u' "/proc/$$/fd/$MAINTENANCE_LOCK_FD")" != "$(id -u)" ]; then
        exec {MAINTENANCE_LOCK_FD}>&-
        fatal 'Opened lock does not match the owned state file; no lock content was changed'
    fi
    chmod 600 "/proc/$$/fd/$MAINTENANCE_LOCK_FD" || fatal "Could not secure the maintenance lock"
    if ! flock -n "$MAINTENANCE_LOCK_FD"; then
        fatal "Another baby-step maintenance command is already running"
    fi
    export BABY_STEP_LOCK_HELD=1 MAINTENANCE_LOCK_FD
}

log_note() {
    printf '%s\n' "$*" | redact_output >> "$LOG_FILE"
}

redact_output() {
    awk '
        /-----BEGIN .*PRIVATE KEY-----/ { private_key=1; print "[REDACTED PRIVATE KEY]"; fflush(); next }
        private_key { if (/-----END .*PRIVATE KEY-----/) private_key=0; next }
        { print; fflush() }
    ' | sed -u -E \
        -e 's#(https?://|ssh://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
        -e 's#(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{16,}|tskey-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16})#[REDACTED]#g' \
        -e 's#((password|passwd|passphrase|token|secret|api[_-]?key|credential|cookie|authorization)[[:space:]"\x27]*[=:][[:space:]]*).*$#\1[REDACTED]#I'
}

ui_badge() {
    local label="$1" color="$2" use_color=0
    if [ -z "${NO_COLOR+x}" ]; then
        case "${BABY_STEP_COLOR:-auto}" in
            always) use_color=1 ;;
            auto) if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then use_color=1; fi ;;
        esac
    fi
    if [ "$use_color" -eq 1 ]; then
        printf '\033[%sm[%s]\033[0m' "$color" "$label"
    else
        printf '[%s]' "$label"
    fi
}

show_banner() {
    printf '\n============================================================\n'
    printf '  %s\n' "$1"
    printf '============================================================\n'
    [ "$#" -lt 2 ] || printf '  %s\n' "$2"
    [ -z "$LOG_FILE" ] || printf '  Private log: %s\n' "$LOG_FILE"
    printf '\n'
}

show_detail() {
    printf '  %s\n' "$*" | redact_output
}

show_step() {
    local number="$1"
    local total="$2"
    shift 2
    BABY_STEP_STAGE_STARTED=$SECONDS
    BABY_STEP_STAGE_LABEL="$*"
    local filled=$(((number - 1) * 10 / total)) bar='' index
    for ((index=0; index<10; index++)); do
        if [ "$index" -lt "$filled" ]; then bar+='#'; else bar+='.'; fi
    done
    printf '\n[%02d/%02d] [%s] %s\n' "$number" "$total" "$bar" "$*"
    [ -z "$LOG_FILE" ] || log_note "STEP $number/$total: $*"
}

show_result() {
    local label="$1" color="$2" elapsed=$((SECONDS - ${BABY_STEP_STAGE_STARTED:-SECONDS}))
    shift 2
    printf '  '; ui_badge "$label" "$color"; printf ' %s (%ss)\n' "${BABY_STEP_STAGE_LABEL:-Result}" "$elapsed"
    [ "$#" -eq 0 ] || show_detail "$*"
    [ -z "$LOG_FILE" ] || log_note "$label: ${BABY_STEP_STAGE_LABEL:-Result} (${elapsed}s) ${*:-}"
}

show_ok() { show_result OK 32 "$@"; }
show_warning() { show_result WARNING 33 "$@"; }
show_failed() { show_result FAILED 31 "$@"; }
show_skipped() { show_result SKIPPED 36 "$@"; }

show_summary() {
    printf '\n------------------------------------------------------------\n'
    printf '  %s\n' "$1"
    shift
    [ "$#" -eq 0 ] || show_detail "$*"
    [ -z "$LOG_FILE" ] || printf '  Details: %s\n' "$LOG_FILE"
    printf '%s\n' '------------------------------------------------------------'
}

fatal() {
    local message="$*"

    printf '\nERROR: %s\n' "$message" | redact_output >&2
    if [ -n "$LOG_FILE" ]; then
        log_note "ERROR: $message"
        printf 'Detailed log: %s\n' "$LOG_FILE" >&2
    fi
    exit 1
}

run_logged() (
    set -o pipefail
    local description="$1"
    local status interval="${BABY_STEP_PROGRESS_INTERVAL:-10}" heartbeat_pid started=$SECONDS
    local -a pipeline_status=()
    shift

    [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 300 )) || interval=10
    printf '\n  [RUN] %s\n' "$description" | tee -a "$LOG_FILE" || return 74
    (
        sleep_pid=''
        trap 'if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; fi' EXIT
        trap 'exit 0' INT TERM HUP
        while :; do
            sleep "$interval" &
            sleep_pid=$!
            wait "$sleep_pid" || exit 0
            sleep_pid=''
            printf '  [WAIT] %s is still running (%ss elapsed).\n' "$description" "$((SECONDS - started))"
        done
    ) &
    heartbeat_pid=$!
    trap 'kill "$heartbeat_pid" 2>/dev/null || true; wait "$heartbeat_pid" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if "$@" 2>&1 | redact_output | tee -a "$LOG_FILE"; then
        pipeline_status=("${PIPESTATUS[@]}")
        status=0
    else
        pipeline_status=("${PIPESTATUS[@]}")
        status="${pipeline_status[0]}"
        if [ "${pipeline_status[1]}" -ne 0 ] || [ "${pipeline_status[2]}" -ne 0 ]; then status=74; fi
    fi
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    trap - EXIT INT TERM HUP
    printf '  [EXIT %s] %s (%ss; command exit %s)\n' "$status" "$description" "$((SECONDS - started))" "${pipeline_status[0]}" | tee -a "$LOG_FILE" || return 74
    return "$status"
)

require_commands() {
    local missing=0
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            show_detail "Missing required command: $command_name"
            log_note "Missing required command: $command_name"
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
    FLAKE_ATTR=''
    FLAKE_TARGET=''

    [ "$NIXOS_SOURCE_POLICY_INVALID" -eq 0 ] &&
        [ -f "$NIXOS_DIR/flake.nix" ] || return 1

    attrs_json="$(nix eval --no-write-lock-file --json "path:$NIXOS_DIR#nixosConfigurations" \
        --apply builtins.attrNames 2>> "$LOG_FILE")" || return 1
    count="$(jq 'length' <<< "$attrs_json")" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    host_name="$(hostname)"
    if [ "$count" -eq 1 ]; then
        FLAKE_ATTR="$(jq -r '.[0]' <<< "$attrs_json")"
    elif [ "$count" -gt 1 ]; then
        while IFS= read -r candidate; do
            candidate_host="$(nix eval --no-write-lock-file --raw \
                "path:$NIXOS_DIR#nixosConfigurations.${candidate}.config.networking.hostName" \
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

    candidate_host="$(nix eval --no-write-lock-file --raw \
        "path:$NIXOS_DIR#nixosConfigurations.${FLAKE_ATTR}.config.networking.hostName" \
        2>> "$LOG_FILE")" || return 1
    if [ "$candidate_host" != "$host_name" ]; then
        printf 'Configuration %s has hostname %s, but this computer is %s.\n' \
            "$FLAKE_ATTR" "$candidate_host" "$host_name" >> "$LOG_FILE"
        return 1
    fi

    FLAKE_TARGET="path:$NIXOS_DIR#$FLAKE_ATTR"
    printf 'Detected flake target: %s\n' "$FLAKE_TARGET" >> "$LOG_FILE"
}

current_generation() (
    set -o pipefail
    # list-generations marks the system PROFILE current, which can be staged
    # for the next boot while another generation is actually running.
    local active generations generation target
    active="$(readlink -f /run/current-system)" || return 1
    generations="$(nixos-rebuild list-generations --json 2>/dev/null |
        jq -er 'sort_by(.generation) | reverse | .[].generation')" || return 1
    while IFS= read -r generation; do
        [[ "$generation" =~ ^[0-9]+$ ]] || return 1
        target="$(readlink -f "/nix/var/nix/profiles/system-${generation}-link" 2>/dev/null)" || continue
        if [ "$target" = "$active" ]; then printf '%s\n' "$generation"; return 0; fi
    done <<< "$generations"
    return 1
)

configuration_source_digest() {
    local digest

    [ -d "$NIXOS_DIR" ] || return 1
    digest="$(
        set -o pipefail
        nixos_source_manifest "$NIXOS_DIR" |
            (cd "$NIXOS_DIR" && xargs -0 -r sha256sum) |
            sha256sum | awk '{print $1}'
    )" || return 1
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

receipt_value() {
    local receipt="$1"
    local key="$2"
    awk -F= -v key="$key" '$1 == key { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }' "$receipt"
}

write_update_receipt() {
    local run_id="$1"
    local health="$2"
    local path="$STATE_DIR/update-success-receipt.txt"
    local temporary active generation lock_digest source_digest

    [[ "$run_id" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || return 1
    case "$health" in passed|warning) ;; *) return 1 ;; esac
    active="$(readlink -f /run/current-system 2>/dev/null)" || return 1
    generation="$(current_generation)" || return 1
    [[ "$generation" =~ ^[0-9]+$ ]] || return 1
    lock_digest="$(sha256sum "$NIXOS_DIR/flake.lock" | awk '{print $1}')" || return 1
    source_digest="$(configuration_source_digest)" || return 1
    [[ "$lock_digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1

    ensure_baby_dirs || return 1
    temporary="$(mktemp "$STATE_DIR/.update-success-receipt.XXXXXX")" || return 1
    if ! {
        printf 'schema=2\nrun_id=%s\nactive_system=%s\ngeneration=%s\n' \
            "$run_id" "$active" "$generation"
        printf 'flake_lock_sha256=%s\nnixos_source_sha256=%s\nhealth=%s\n' \
            "$lock_digest" "$source_digest" "$health"
        printf 'recorded_at=%s\n' "$(date --iso-8601=seconds)"
    } > "$temporary" || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$path"; then
        rm -f -- "$temporary"
        return 1
    fi
}

validate_update_receipt() {
    local expected_run_id="$1"
    local receipt="$STATE_DIR/update-success-receipt.txt"
    local active generation lock_digest source_digest health

    [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
    [ "$(stat -c '%u:%a' "$receipt" 2>/dev/null)" = "$(id -u):600" ] || return 1
    [ "$(receipt_value "$receipt" schema 2>/dev/null)" = 2 ] || return 1
    [ "$(receipt_value "$receipt" run_id 2>/dev/null)" = "$expected_run_id" ] || return 1
    active="$(readlink -f /run/current-system 2>/dev/null)" || return 1
    generation="$(current_generation)" || return 1
    lock_digest="$(sha256sum "$NIXOS_DIR/flake.lock" 2>/dev/null | awk '{print $1}')" || return 1
    source_digest="$(configuration_source_digest)" || return 1
    health="$(receipt_value "$receipt" health 2>/dev/null)" || return 1
    case "$health" in passed|warning) ;; *) return 1 ;; esac

    [ "$(receipt_value "$receipt" active_system 2>/dev/null)" = "$active" ] &&
        [ "$(receipt_value "$receipt" generation 2>/dev/null)" = "$generation" ] &&
        [ "$(receipt_value "$receipt" flake_lock_sha256 2>/dev/null)" = "$lock_digest" ] &&
        [ "$(receipt_value "$receipt" nixos_source_sha256 2>/dev/null)" = "$source_digest" ]
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
