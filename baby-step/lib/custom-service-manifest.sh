#!/usr/bin/env bash
# Public helper contract shared by backup, restore and publication. No runtime
# Hermes configuration, cron database, delivery target or credential is selected.
_CUSTOM_SERVICE_CONTRACT_DIR="${BASH_SOURCE[0]%/*}"

custom_service_public_contract() {
    local contract="$_CUSTOM_SERVICE_CONTRACT_DIR/custom-service-manifest.json"
    [ -f "$contract" ] && [ ! -L "$contract" ] && [ -r "$contract" ] || return 1
    jq -e '.schema_version == 1 and (.public_files | type == "array") and (.public_files | length == 6) and
      (.public_files | map(.path) | length == (unique | length)) and
      all(.public_files[]; (.path | test("^\\.hermes/(agy_bridge\\.py|scripts/clean-system(\\.py|\\.job\\.json)|plugins/human-stage-policy/(__init__\\.py|plugin\\.yaml)|skills/human-controlled-project-stages/SKILL\\.md)$")) and
        (.origin == "home" or .origin == "repository") and
        (.kind == "code" or .kind == "retained") and
        (.restore | type == "boolean") and (.mode | test("^0[0-7]{3}$")))' "$contract" >/dev/null || return 1
    printf '%s\n' "$contract"
}

# Pin all source ancestors and copy from the selected regular-file descriptor;
# fail on a concurrent write. Only audit-owned private prepared files are made.
custom_service_copy_source() {
    python3 - "$1" "$2" <<'PY'
import os, stat, sys, hashlib
source, prepared = sys.argv[1:]
fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    parts = source.split('/')[1:]
    if not parts or any(p in {'', '.', '..'} for p in parts):
        raise ValueError('invalid selected source path')
    for part in parts[:-1]:
        nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        os.close(fd); fd = nxt
    leaf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    try:
        before = os.fstat(leaf)
        if not stat.S_ISREG(before.st_mode) or not before.st_mode & 0o444:
            raise ValueError('selected source is not a readable regular file')
        data = bytearray()
        while block := os.read(leaf, 1024 * 1024):
            data.extend(block)
        after = os.fstat(leaf)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        current = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        if fields(before) != fields(after) or fields(before) != fields(current):
            raise ValueError('selected source changed during copy')
        out = os.open(prepared, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, stat.S_IMODE(before.st_mode))
        with os.fdopen(out, 'wb') as stream:
            os.fchmod(stream.fileno(), stat.S_IMODE(before.st_mode))
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
    finally:
        os.close(leaf)
finally:
    os.close(fd)
PY
}

prepare_custom_service_sources() (
    set -euo pipefail
    if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
        printf 'usage: prepare_custom_service_sources MANIFEST HOME DOTCONFIG LOCAL_BIN CUSTOM_FILES [RETAINED_REPOSITORY]\n' >&2
        exit 2
    fi
    local manifest="$1" source_home="$2" dotconfig="$3" local_bin="$4" custom_files="$5"
    local retained_repo="${6:-}" contract source_relative backup_relative kind extra source_path prepared mode_text row origin
    local hermes_seen=0 minecraft_seen=0 agy_unit_seen=0 minecraft_unit_seen=0
    local -A seen=()
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || exit 1
    contract="$(custom_service_public_contract)" || { printf 'Public source contract unavailable or invalid.\n' >&2; exit 1; }
    mkdir -p "$local_bin" "$custom_files"
    while IFS=$'\t' read -r source_relative backup_relative kind extra || [ -n "${source_relative:-}" ]; do
        case "$source_relative" in ''|\#*) continue ;; esac
        [ -z "${extra:-}" ] && [ "$source_relative" = "$backup_relative" ] && [ -z "${seen[$source_relative]:-}" ] || {
            printf 'Duplicate or unsafe custom-service mapping.\n' >&2; exit 1;
        }
        seen["$source_relative"]=1
        origin=home
        case "$source_relative|$kind" in
            '.local/bin/mc_chat_responder.py|code') minecraft_seen=1; prepared="$local_bin/mc_chat_responder.py" ;;
            '.config/systemd/user/agy-bridge.service|unit') agy_unit_seen=1; prepared="$dotconfig/systemd/user/agy-bridge.service" ;;
            '.config/systemd/user/mc-chat-responder.service|unit') minecraft_unit_seen=1; prepared="$dotconfig/systemd/user/mc-chat-responder.service" ;;
            *)
                row="$(jq -r --arg p "$source_relative" --arg k "$kind" '.public_files[] | select(.path == $p and .kind == $k) | .origin' "$contract")"
                [ -n "$row" ] || { printf 'Unapproved custom-service manifest mapping.\n' >&2; exit 1; }
                origin="$row"; prepared="$custom_files/$backup_relative"
                [ "$source_relative" != .hermes/agy_bridge.py ] || hermes_seen=1
                ;;
        esac
        if [ "$origin" = repository ]; then
            [ -n "$retained_repo" ] || { printf 'Retained repository source is required.\n' >&2; exit 1; }
            source_path="$retained_repo/dotfiles/$source_relative"
        else
            source_path="$source_home/$source_relative"
        fi
        if [ "$kind" = unit ]; then
            [ -f "$source_path" ] && [ ! -L "$source_path" ] && [ -r "$source_path" ] &&
                [ -f "$prepared" ] && [ ! -L "$prepared" ] && cmp -s -- "$source_path" "$prepared" || {
                printf 'Selected snapshot omits or changes declared unit: %s\n' "$source_relative" >&2; exit 1;
            }
        else
            mkdir -p "$(dirname -- "$prepared")"
            custom_service_copy_source "$source_path" "$prepared" || {
                printf 'Could not pin and prepare declared public source: %s\n' "$source_relative" >&2; exit 1;
            }
        fi
    done < "$manifest"
    [ "$hermes_seen:$minecraft_seen:$agy_unit_seen:$minecraft_unit_seen" = 1:1:1:1 ] || {
        printf 'Custom-service manifest is incomplete.\n' >&2; exit 1;
    }
    if grep -Fxq '# public-source-contract=v2' "$manifest"; then
        while IFS= read -r source_relative; do
            [ "${seen[$source_relative]:-}" = 1 ] || { printf 'Required public source omitted: %s\n' "$source_relative" >&2; exit 1; }
        done < <(jq -r '.public_files[].path' "$contract")
    fi
)
