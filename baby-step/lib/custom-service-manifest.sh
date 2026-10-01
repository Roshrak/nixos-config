#!/usr/bin/env bash

# Validate the narrow user-service source map and prepare only its declared
# code files. Unit files are already covered by the selected systemd config
# snapshot; this function proves those snapshot copies match their sources.
prepare_custom_service_sources() (
    set -euo pipefail
    if [ "$#" -ne 5 ]; then
        printf 'usage: prepare_custom_service_sources MANIFEST HOME DOTCONFIG LOCAL_BIN CUSTOM_FILES\n' >&2
        exit 2
    fi

    local manifest="$1"
    local source_home="$2"
    local dotconfig="$3"
    local local_bin="$4"
    local custom_files="$5"
    local source_relative backup_relative kind extra source_path prepared mode_text
    local hermes_seen=0 minecraft_seen=0 agy_unit_seen=0 minecraft_unit_seen=0

    if [ ! -f "$manifest" ] || [ -L "$manifest" ] || [ ! -r "$manifest" ]; then
        printf 'Custom-service manifest is missing or unreadable.\n' >&2
        exit 1
    fi
    mkdir -p "$local_bin" "$custom_files"

    while IFS=$'\t' read -r source_relative backup_relative kind extra; do
        case "$source_relative" in ''|\#*) continue ;; esac
        [ -z "${extra:-}" ] || {
            printf 'Unexpected custom-service manifest column.\n' >&2
            exit 1
        }
        case "$source_relative|$backup_relative|$kind" in
            '.hermes/agy_bridge.py|.hermes/agy_bridge.py|code')
                [ "$hermes_seen" -eq 0 ] || {
                    printf 'Duplicate Hermes bridge manifest entry.\n' >&2
                    exit 1
                }
                hermes_seen=1
                prepared="$custom_files/$backup_relative"
                ;;
            '.local/bin/mc_chat_responder.py|.local/bin/mc_chat_responder.py|code')
                [ "$minecraft_seen" -eq 0 ] || {
                    printf 'Duplicate chat helper manifest entry.\n' >&2
                    exit 1
                }
                minecraft_seen=1
                prepared="$local_bin/${backup_relative#.local/bin/}"
                ;;
            '.config/systemd/user/agy-bridge.service|.config/systemd/user/agy-bridge.service|unit')
                [ "$agy_unit_seen" -eq 0 ] || {
                    printf 'Duplicate Hermes unit manifest entry.\n' >&2
                    exit 1
                }
                agy_unit_seen=1
                prepared="$dotconfig/systemd/user/agy-bridge.service"
                ;;
            '.config/systemd/user/mc-chat-responder.service|.config/systemd/user/mc-chat-responder.service|unit')
                [ "$minecraft_unit_seen" -eq 0 ] || {
                    printf 'Duplicate chat unit manifest entry.\n' >&2
                    exit 1
                }
                minecraft_unit_seen=1
                prepared="$dotconfig/systemd/user/mc-chat-responder.service"
                ;;
            *)
                printf 'Unapproved custom-service manifest mapping.\n' >&2
                exit 1
                ;;
        esac

        source_path="$source_home/$source_relative"
        if [ ! -f "$source_path" ] || [ -L "$source_path" ] || [ ! -r "$source_path" ]; then
            printf 'Declared custom-service source is missing or unreadable: %s\n' "$source_relative" >&2
            exit 1
        fi
        mode_text="$(stat -c '%a' -- "$source_path")"
        if (( (8#$mode_text & 0444) == 0 )); then
            printf 'Declared custom-service source has no read permission bits: %s\n' "$source_relative" >&2
            exit 1
        fi

        if [ "$kind" = code ]; then
            mkdir -p "$(dirname -- "$prepared")"
            cp -a --no-preserve=ownership "$source_path" "$prepared"
            cmp -s -- "$source_path" "$prepared" || {
                printf 'Prepared helper differs from its source: %s\n' "$source_relative" >&2
                exit 1
            }
        else
            if [ ! -f "$prepared" ] || [ -L "$prepared" ] ||
               ! cmp -s -- "$source_path" "$prepared"; then
                printf 'Selected user config snapshot omits or changes unit: %s\n' "$source_relative" >&2
                exit 1
            fi
        fi
    done < "$manifest"

    if [ "$hermes_seen" -ne 1 ] || [ "$minecraft_seen" -ne 1 ] ||
       [ "$agy_unit_seen" -ne 1 ] || [ "$minecraft_unit_seen" -ne 1 ]; then
        printf 'Custom-service manifest is incomplete.\n' >&2
        exit 1
    fi
)
