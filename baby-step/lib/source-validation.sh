#!/usr/bin/env bash

# Shared production gates for backup-config.sh. Sourcing this file does not
# evaluate a flake, create a snapshot, build a system, or replace any file.

evaluate_nixos_toplevel() {
    if [ "$#" -ne 2 ]; then
        printf 'usage: evaluate_nixos_toplevel FLAKE_REFERENCE HOST_KEY\n' >&2
        return 2
    fi
    local flake_reference="$1" host_key="$2" result
    case "$host_key" in
        ''|*[!A-Za-z0-9._+-]*|-*|.*)
            printf 'Invalid NixOS host key.\n' >&2
            return 2
            ;;
    esac
    case "$flake_reference" in
        ''|*'#'*)
            printf 'Invalid flake reference.\n' >&2
            return 2
            ;;
    esac

    result="$(timeout 120 nix eval --offline --no-write-lock-file --raw \
        "${flake_reference}#nixosConfigurations.${host_key}.config.system.build.toplevel.outPath")" || {
        printf 'NixOS toplevel evaluation failed for host %s.\n' "$host_key" >&2
        return 1
    }
    case "$result" in
        /nix/store/*) ;;
        *)
            printf 'Nix returned an unexpected toplevel path.\n' >&2
            return 1
            ;;
    esac
    printf '%s\n' "$result"
}

source_contract_digest() {
    if [ "$#" -ne 1 ] || [ ! -f "$1" ] || [ -L "$1" ] || [ ! -r "$1" ]; then
        printf 'Source resource contract is missing, unreadable, or linked.\n' >&2
        return 1
    fi
    sha256sum -- "$1" | awk '{print $1}'
}

capture_source_contract_paths() {
    if [ "$#" -ne 3 ]; then
        printf 'usage: capture_source_contract_paths CONTRACT HOST LIST_FILE\n' >&2
        return 2
    fi
    local contract="$1" host_key="$2" list_file="$3"
    case "$host_key" in
        ''|*[!A-Za-z0-9._+-]*|-*|.*)
            printf 'Invalid NixOS host key in source contract.\n' >&2
            return 2
            ;;
    esac
    if ! jq -e --arg host "$host_key" '
        type == "object" and .schema == 1 and
        (.common | type == "array") and
        (.hosts | type == "object") and
        (.hosts[$host] | type == "array") and
        (.common | index("flake.nix") != null) and
        (.common | index("flake.lock") != null) and
        (.common | index("configuration.nix") != null) and
        ((.common + .hosts[$host]) as $paths |
         ($paths | length) > 0 and
         all($paths[]; type == "string" and
             test("^[A-Za-z0-9_.+/-]+$") and
             (split("/") | all(.[]; . != "" and . != "." and . != ".."))) and
         (($paths | unique | length) == ($paths | length)))
    ' "$contract" >/dev/null; then
        printf 'Source resource contract has an invalid schema, path, or duplicate.\n' >&2
        return 1
    fi
    if ! jq -er --arg host "$host_key" \
        '(.common + .hosts[$host])[]' "$contract" > "$list_file"; then
        printf 'Source resource contract enumeration failed.\n' >&2
        return 1
    fi
    if [ ! -s "$list_file" ]; then
        printf 'Source resource contract enumeration produced an empty list.\n' >&2
        return 1
    fi
}

validate_required_build_inputs_from_list() (
    set -euo pipefail
    if [ "$#" -ne 5 ]; then
        printf 'usage: validate_required_build_inputs_from_list ROOT HOST CONTRACT MANIFEST LIST_FILE\n' >&2
        exit 2
    fi
    local root="$1" host_key="$2" contract="$3" manifest_script="$4" list_file="$5"
    local physical_root relative component current mode_text mode
    local contract_digest_before contract_digest_after
    local -a components=()

    case "$host_key" in
        ''|*[!A-Za-z0-9._+-]*|-*|.*)
            printf 'Invalid NixOS host key in source contract.\n' >&2
            exit 2
            ;;
    esac
    if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -f "$contract" ] ||
       [ -L "$contract" ] || [ ! -r "$contract" ] ||
       [ ! -f "$manifest_script" ] || [ ! -r "$manifest_script" ] ||
       [ -L "$manifest_script" ] || [ ! -s "$list_file" ]; then
        printf 'Source root, input contract, source manifest, or captured list is unsafe.\n' >&2
        exit 1
    fi
    contract_digest_before="$(source_contract_digest "$contract")" || exit 1
    if ! declare -F nixos_source_manifest >/dev/null 2>&1; then
        . "$manifest_script"
    fi
    if ! declare -F nixos_source_manifest >/dev/null 2>&1; then
        printf 'Source manifest did not define nixos_source_manifest.\n' >&2
        exit 1
    fi

    physical_root="$(cd -P -- "$root" && pwd)" || exit 1
    while IFS= read -r relative; do
        case "$relative" in
            ''|/*|*[$'\t\r\n']*)
                printf 'Unsafe path in source resource contract.\n' >&2
                exit 1
                ;;
        esac
        IFS='/' read -r -a components <<< "$relative"
        current="$physical_root"
        for component in "${components[@]}"; do
            case "$component" in
                ''|.|..|*[!A-Za-z0-9_.+-]*)
                    printf 'Unsafe path component in source resource contract.\n' >&2
                    exit 1
                    ;;
            esac
            current="$current/$component"
            if [ -L "$current" ]; then
                printf 'Symlinked required source input: %s\n' "$relative" >&2
                exit 1
            fi
            if [ "$current" != "$physical_root/${relative}" ] && [ -d "$current" ]; then
                mode_text="$(stat -c '%a' -- "$current")" || exit 1
                mode=$((8#$mode_text))
                if (( (mode & 0111) == 0 )); then
                    printf 'Untraversable required source directory: %s\n' "$relative" >&2
                    exit 1
                fi
            fi
        done
        if [ ! -f "$physical_root/$relative" ] || [ ! -r "$physical_root/$relative" ]; then
            printf 'Required build input is missing or unreadable: %s\n' "$relative" >&2
            exit 1
        fi
        mode_text="$(stat -c '%a' -- "$physical_root/$relative")" || exit 1
        mode=$((8#$mode_text))
        if (( (mode & 0444) == 0 )); then
            printf 'Required build input has no read permission bits: %s\n' "$relative" >&2
            exit 1
        fi
        if ! nixos_source_manifest "$physical_root" | grep -zFx -- "$relative" >/dev/null; then
            printf 'Required build input is outside the selected source manifest: %s\n' "$relative" >&2
            exit 1
        fi
    done < "$list_file"

    contract_digest_after="$(source_contract_digest "$contract")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed during validation.\n' >&2
        exit 1
    fi
)

validate_required_build_inputs() (
    set -euo pipefail
    if [ "$#" -ne 4 ]; then
        printf 'usage: validate_required_build_inputs ROOT HOST CONTRACT MANIFEST\n' >&2
        exit 2
    fi
    local temp_dir list_file contract_digest_before contract_digest_after
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/source-contract.XXXXXX")" || exit 1
    chmod 0700 "$temp_dir" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    list_file="$temp_dir/required-inputs.txt"
    contract_digest_before="$(source_contract_digest "$3")" || exit 1
    capture_source_contract_paths "$3" "$2" "$list_file" || exit 1
    contract_digest_after="$(source_contract_digest "$3")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed during enumeration.\n' >&2
        exit 1
    fi
    validate_required_build_inputs_from_list "$1" "$2" "$3" "$4" "$list_file"
)

verify_nixos_snapshot() (
    set -euo pipefail
    if [ "$#" -ne 5 ]; then
        printf 'usage: verify_nixos_snapshot SOURCE SNAPSHOT HOST CONTRACT MANIFEST\n' >&2
        exit 2
    fi
    local source_reference="$1" snapshot="$2" host_key="$3" contract="$4" manifest_script="$5"
    local snapshot_reference source_toplevel snapshot_toplevel built timeout_seconds
    local relative temp_dir list_file contract_digest_before contract_digest_after
    case "$source_reference" in
        ''|*'#'*) printf 'Invalid source flake reference.\n' >&2; exit 2 ;;
    esac
    if [ ! -d "$snapshot" ] || [ -L "$snapshot" ]; then
        printf 'Prepared NixOS snapshot is missing or unsafe.\n' >&2
        exit 1
    fi
    timeout_seconds="${BABY_STEP_SNAPSHOT_BUILD_TIMEOUT:-900}"
    case "$timeout_seconds" in
        ''|*[!0-9]*) printf 'Snapshot build timeout must be an integer.\n' >&2; exit 2 ;;
    esac
    if (( timeout_seconds < 1 || timeout_seconds > 3600 )); then
        printf 'Snapshot build timeout must be between 1 and 3600 seconds.\n' >&2
        exit 2
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/source-contract.XXXXXX")" || exit 1
    chmod 0700 "$temp_dir" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    list_file="$temp_dir/required-inputs.txt"
    contract_digest_before="$(source_contract_digest "$contract")" || exit 1
    capture_source_contract_paths "$contract" "$host_key" "$list_file" || exit 1
    contract_digest_after="$(source_contract_digest "$contract")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed during enumeration.\n' >&2
        exit 1
    fi
    validate_required_build_inputs_from_list "$source_reference" "$host_key" \
        "$contract" "$manifest_script" "$list_file" || exit 1
    validate_required_build_inputs_from_list "$snapshot" "$host_key" \
        "$contract" "$manifest_script" "$list_file" || exit 1
    while IFS= read -r relative; do
        if ! cmp -s -- "$source_reference/$relative" "$snapshot/$relative"; then
            printf 'Required build input differs between source and prepared snapshot: %s\n' "$relative" >&2
            exit 1
        fi
    done < "$list_file"
    contract_digest_after="$(source_contract_digest "$contract")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed before evaluation.\n' >&2
        exit 1
    fi

    source_toplevel="$(evaluate_nixos_toplevel "$source_reference" "$host_key")" || exit 1
    snapshot_reference="path:$(cd -P -- "$snapshot" && pwd)" || exit 1
    snapshot_toplevel="$(evaluate_nixos_toplevel "$snapshot_reference" "$host_key")" || exit 1
    if [ "$source_toplevel" != "$snapshot_toplevel" ]; then
        printf 'Source and prepared snapshot toplevels differ.\n' >&2
        exit 1
    fi

    contract_digest_after="$(source_contract_digest "$contract")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed before build.\n' >&2
        exit 1
    fi
    built="$(timeout "$timeout_seconds" nix build --offline --no-link \
        --no-write-lock-file --print-out-paths \
        "${snapshot_reference}#nixosConfigurations.${host_key}.config.system.build.toplevel")" || {
        printf 'Prepared snapshot no-link build failed or timed out.\n' >&2
        exit 1
    }
    if [ "$built" != "$snapshot_toplevel" ] || [ ! -e "$built" ]; then
        printf 'Prepared snapshot build output did not match its evaluated toplevel.\n' >&2
        exit 1
    fi
    contract_digest_after="$(source_contract_digest "$contract")" || exit 1
    if [ "$contract_digest_before" != "$contract_digest_after" ]; then
        printf 'Source resource contract changed during build.\n' >&2
        exit 1
    fi
    printf '%s\n' "$built"
)
