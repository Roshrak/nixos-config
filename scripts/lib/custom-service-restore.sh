#!/usr/bin/env bash

# Exact-file restore helpers for the two declared custom user services.
# Sourcing this file is side-effect free. All writes go through run_root,
# which the bootstrap entry point defines after its disposable/live target is
# selected; fixture tests provide their own confined adapter.

custom_restore_error() {
    printf 'Custom-service restore: %s\n' "$*" >&2
}

custom_restore_safe_path() {
    local path="$1" allow_missing="${2:-1}" allow_leaf_link="${3:-0}"
    local current="/" component missing_seen=0 index=0 last
    local -a parts=()
    case "$path" in /*) ;; *) custom_restore_error "path is not absolute: $path"; return 1 ;; esac
    case "$path" in *[[:cntrl:]]*) custom_restore_error "path contains a control character: $path"; return 1 ;; esac
    [[ "$allow_missing" =~ ^[01]$ && "$allow_leaf_link" =~ ^[01]$ ]] || {
        custom_restore_error 'path policy flags must be 0 or 1'
        return 2
    }
    IFS='/' read -r -a parts <<< "${path#/}"
    last=$((${#parts[@]} - 1))
    for component in "${parts[@]}"; do
        case "$component" in
            ''|.|..)
                custom_restore_error "unsafe path component in $path"
                return 1
                ;;
        esac
        current="${current%/}/$component"
        if [ -L "$current" ]; then
            if [ "$index" -eq "$last" ] && [ "$allow_leaf_link" -eq 1 ]; then
                index=$((index + 1))
                continue
            fi
            custom_restore_error "symlink path component: $current"
            return 1
        fi
        if [ -e "$current" ]; then
            [ "$missing_seen" -eq 0 ] || {
                custom_restore_error "path reappears below a missing ancestor: $current"
                return 1
            }
            if [ "$current" != "$path" ] && [ ! -d "$current" ]; then
                custom_restore_error "non-directory path component: $current"
                return 1
            fi
        elif [ "$allow_missing" -eq 1 ]; then
            # A not-yet-created target may be missing at any depth, but no
            # existing component below that point may reappear.
            missing_seen=1
        else
            custom_restore_error "missing path ancestor: $current"
            return 1
        fi
        index=$((index + 1))
    done
}

custom_restore_validate_private_directory() {
    if [ "$#" -ne 3 ]; then
        custom_restore_error 'usage: custom_restore_validate_private_directory PATH UID GID'
        return 2
    fi
    local path="$1" uid="$2" gid="$3" metadata
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 2
    custom_restore_safe_path "$path" 1 || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -d "$path" ] && [ ! -L "$path" ] || {
            custom_restore_error "private recovery path is not a real directory: $path"
            return 1
        }
        metadata="$(stat -c '%a:%u:%g' -- "$path")" || return 1
        [ "$metadata" = "700:$uid:$gid" ] || {
            custom_restore_error "private recovery path must be mode 0700 and owned by $uid:$gid: $path"
            return 1
        }
    fi
}

custom_restore_ensure_private_directory() {
    if [ "$#" -ne 3 ]; then
        custom_restore_error 'usage: custom_restore_ensure_private_directory PATH UID GID'
        return 2
    fi
    local path="$1" uid="$2" gid="$3" current="/" component
    local -a parts=()
    custom_restore_safe_path "$path" 1 || return 1
    IFS='/' read -r -a parts <<< "${path#/}"
    for component in "${parts[@]}"; do
        current="${current%/}/$component"
        if [ -L "$current" ]; then
            custom_restore_error "refusing symlink while creating private recovery path: $current"
            return 1
        elif [ -e "$current" ]; then
            [ -d "$current" ] || {
                custom_restore_error "private recovery path has a non-directory ancestor: $current"
                return 1
            }
        else
            if [ "$current" = "$path" ]; then
                run_root mkdir -m 0700 -- "$current" || return 1
            else
                run_root mkdir -m 0755 -- "$current" || return 1
            fi
            run_root chown "$uid:$gid" -- "$current" || return 1
        fi
    done
    custom_restore_validate_private_directory "$path" "$uid" "$gid"
}

custom_restore_validate_new_private_directory() {
    if [ "$#" -ne 3 ]; then
        custom_restore_error 'usage: custom_restore_validate_new_private_directory PATH UID GID'
        return 2
    fi
    local path="$1"
    custom_restore_safe_path "$path" 1 || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        custom_restore_error "new private recovery path already exists: $path"
        return 1
    fi
    custom_restore_validate_private_directory "$path" "$2" "$3"
}

custom_restore_validate_source_link() {
    if [ "$#" -ne 2 ]; then return 2; fi
    local path="$1" target="$2"
    case "$path|$target" in
        */dotfiles/.local/bin/obs\|/home/aesc/.local/bin/obs-safe) ;;
        */dotfiles/.config/systemd/user/default.target.wants/agy-bridge.service\|/home/aesc/.config/systemd/user/agy-bridge.service) ;;
        */dotfiles/.config/systemd/user/default.target.wants/hermes-gateway.service\|/home/aesc/.config/systemd/user/hermes-gateway.service) ;;
        */dotfiles/.config/systemd/user/default.target.wants/mc-chat-responder.service\|/home/aesc/.config/systemd/user/mc-chat-responder.service) ;;
        */dotfiles/.config/theme-profiles/sway/config-home/noctalia/palettes\|/home/aesc/.config/noctalia/palettes) ;;
        */dotfiles/.config/theme-profiles/sway/noctalia-state/community-palettes\|/home/aesc/.local/state/noctalia/community-palettes) ;;
        */dotfiles/.config/theme-profiles/sway/noctalia-state/clipboard\|/home/aesc/.local/state/noctalia/clipboard) ;;
        */dotfiles/.config/theme-profiles/sway/noctalia-state/community-templates\|/home/aesc/.local/state/noctalia/community-templates) ;;
        */dotfiles/.config/theme-profiles/sway/noctalia-state/plugins\|/home/aesc/.local/state/noctalia/plugins) ;;
        */dotfiles/.config/theme-profiles/mango/config-home/noctalia/palettes\|/home/aesc/.config/noctalia/palettes) ;;
        */dotfiles/.config/theme-profiles/mango/noctalia-state/community-palettes\|/home/aesc/.local/state/noctalia/community-palettes) ;;
        */dotfiles/.config/theme-profiles/mango/noctalia-state/clipboard\|/home/aesc/.local/state/noctalia/clipboard) ;;
        */dotfiles/.config/theme-profiles/mango/noctalia-state/community-templates\|/home/aesc/.local/state/noctalia/community-templates) ;;
        */dotfiles/.config/theme-profiles/mango/noctalia-state/plugins\|/home/aesc/.local/state/noctalia/plugins) ;;
        */dotfiles/.config/theme-profiles/niri/config-home/noctalia/palettes\|/home/aesc/.config/noctalia/palettes) ;;
        */dotfiles/.config/theme-profiles/niri/noctalia-state/community-palettes\|/home/aesc/.local/state/noctalia/community-palettes) ;;
        */dotfiles/.config/theme-profiles/niri/noctalia-state/clipboard\|/home/aesc/.local/state/noctalia/clipboard) ;;
        */dotfiles/.config/theme-profiles/niri/noctalia-state/community-templates\|/home/aesc/.local/state/noctalia/community-templates) ;;
        */dotfiles/.config/theme-profiles/niri/noctalia-state/plugins\|/home/aesc/.local/state/noctalia/plugins) ;;
        *)
            custom_restore_error "selected source contains an unapproved symlink: $path -> $target"
            return 1
            ;;
    esac
}

# Recursive copies are allowed to preserve the repository's explicit user
# links, but every walk is physical (-P), every link is recorded as a link,
# and no link target is traversed. Special files are refused before cp/chown.
custom_restore_validate_tree_types() {
    if [ "$#" -ne 2 ]; then
        custom_restore_error 'usage: custom_restore_validate_tree_types PATH source|destination'
        return 2
    fi
    local root="$1" role="$2" listing record type entry target
    case "$role" in source|destination) ;; *) return 2 ;; esac
    if [ -L "$root" ]; then
        [ "$role" = source ] || {
            custom_restore_error "selected destination root is a symlink: $root"
            return 1
        }
        target="$(readlink -- "$root")" || return 1
        custom_restore_validate_source_link "$root" "$target"
        return $?
    fi
    [ -d "$root" ] && [ ! -L "$root" ] || {
        custom_restore_error "selected tree root is not a real directory: $root"
        return 1
    }
    listing="$(mktemp "${CUSTOM_RESTORE_PREFLIGHT_DIR:-/tmp}/.tree-types.XXXXXX")" || return 1
    if ! find -P "$root" -mindepth 1 -printf '%y\0%p\0' > "$listing"; then
        rm -f -- "$listing"
        custom_restore_error "could not enumerate selected tree without following links: $root"
        return 1
    fi
    while IFS= read -r -d '' type && IFS= read -r -d '' entry; do
        case "$type" in
            d|f) ;;
            l)
                if [ "$role" = source ]; then
                    target="$(readlink -- "$entry")" || { rm -f -- "$listing"; return 1; }
                    if ! custom_restore_validate_source_link "$entry" "$target"; then
                        rm -f -- "$listing"
                        return 1
                    fi
                fi
                ;;
            *)
                rm -f -- "$listing"
                custom_restore_error "selected tree contains unsupported special file type '$type': $entry"
                return 1
                ;;
        esac
    done < "$listing"
    rm -f -- "$listing"
}

custom_restore_validate_repository_private_content() {
    if [ "$#" -ne 1 ]; then return 2; fi
    local repo_root="$1" hermes_dir="$1/dotfiles/.hermes" entry name listing
    custom_restore_safe_path "$repo_root" 0 || return 1
    custom_restore_safe_path "$hermes_dir" 1 || return 1
    [ -e "$hermes_dir" ] || return 0
    [ -d "$hermes_dir" ] && [ ! -L "$hermes_dir" ] || {
        custom_restore_error "repository .hermes path is not a real directory: $hermes_dir"
        return 1
    }
    listing="$(mktemp "${CUSTOM_RESTORE_PREFLIGHT_DIR:-/tmp}/.hermes-entries.XXXXXX")" || return 1
    if ! find -P "$hermes_dir" -mindepth 1 -print0 > "$listing"; then
        rm -f -- "$listing"
        custom_restore_error "could not enumerate repository .hermes content: $hermes_dir"
        return 1
    fi
    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        if [ "$name" != agy_bridge.py ] || [ ! -f "$entry" ] || [ -L "$entry" ]; then
            rm -f -- "$listing"
            custom_restore_error "repository copy contains unmanifested private Hermes data: $entry"
            return 1
        fi
    done < "$listing"
    rm -f -- "$listing"
}

custom_restore_preflight_repository_copy() {
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: custom_restore_preflight_repository_copy REPO_ROOT TARGET_HOME DESTINATION BACKUP UID GID'
        return 2
    fi
    local repo_root="$1" target_home="$2" destination="$3" backup="$4"
    local uid="$5" gid="$6"
    custom_restore_safe_path "$repo_root" 0 || return 1
    [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || return 1
    custom_restore_validate_tree_types "$repo_root" source || return 1
    custom_restore_validate_repository_private_content "$repo_root" || return 1
    custom_restore_safe_path "$target_home" 1 || return 1
    if [ -e "$target_home" ]; then
        [ -d "$target_home" ] && [ ! -L "$target_home" ] &&
            [ "$(stat -c '%u:%g' -- "$target_home")" = "$uid:$gid" ] || {
                custom_restore_error "repository-copy target home is unsafe or has unexpected ownership: $target_home"
                return 1
            }
    fi
    custom_restore_safe_path "$destination" 1 || return 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -d "$destination" ] && [ ! -L "$destination" ] &&
            [ "$(stat -c '%u:%g' -- "$destination")" = "$uid:$gid" ] || {
                custom_restore_error "repository-copy destination is unsafe or has unexpected ownership: $destination"
                return 1
            }
        custom_restore_validate_tree_types "$destination" destination || return 1
    fi
    custom_restore_safe_path "$backup" 1 || return 1
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        custom_restore_error "repository-copy recovery destination already exists: $backup"
        return 1
    fi
}

custom_restore_check_source_file() {
    local path="$1" label="$2" mode_text mode
    custom_restore_safe_path "$path" 0 || return 1
    if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ]; then
        custom_restore_error "declared $label is missing, unsafe, or unreadable: $path"
        return 1
    fi
    mode_text="$(stat -c '%a' -- "$path")" || return 1
    mode=$((8#$mode_text))
    if (( (mode & 0444) == 0 )); then
        custom_restore_error "declared $label has no read permission bits: $path"
        return 1
    fi
}

preflight_custom_service_restore() (
    set -euo pipefail
    if [ "$#" -ne 5 ]; then
        custom_restore_error 'usage: preflight_custom_service_restore MANIFEST DOTFILES TARGET_HOME UID GID'
        exit 2
    fi
    local manifest="$1" dotfiles="$2" target_home="$3" expected_uid="$4" expected_gid="$5"
    local source_relative backup_relative kind extra source_path
    local hermes_dir="$target_home/.hermes" helper="$target_home/.hermes/agy_bridge.py"
    local uid_seen=0 chat_seen=0 hermes_unit_seen=0 chat_unit_seen=0
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] || {
        custom_restore_error 'target UID/GID must be decimal numbers'
        exit 1
    }
    custom_restore_safe_path "$manifest" 0 || exit 1
    custom_restore_safe_path "$dotfiles" 0 || exit 1
    custom_restore_safe_path "$target_home" 1 || exit 1
    if [ ! -f "$manifest" ] || [ -L "$manifest" ] || [ ! -r "$manifest" ]; then
        custom_restore_error "manifest is missing or unreadable: $manifest"
        exit 1
    fi
    if [ ! -d "$dotfiles" ] || [ -L "$dotfiles" ]; then
        custom_restore_error "dotfiles source is missing or unsafe: $dotfiles"
        exit 1
    fi

    while IFS=$'\t' read -r source_relative backup_relative kind extra ||
          [ -n "${source_relative:-}" ]; do
        case "${source_relative:-}" in ''|\#*) continue ;; esac
        [ -z "${extra:-}" ] || {
            custom_restore_error 'manifest has an unexpected column'
            exit 1
        }
        case "$source_relative|$backup_relative|$kind" in
            '.hermes/agy_bridge.py|.hermes/agy_bridge.py|code')
                [ "$uid_seen" -eq 0 ] || { custom_restore_error 'duplicate Hermes helper mapping'; exit 1; }
                uid_seen=1
                ;;
            '.local/bin/mc_chat_responder.py|.local/bin/mc_chat_responder.py|code')
                [ "$chat_seen" -eq 0 ] || { custom_restore_error 'duplicate chat helper mapping'; exit 1; }
                chat_seen=1
                ;;
            '.config/systemd/user/agy-bridge.service|.config/systemd/user/agy-bridge.service|unit')
                [ "$hermes_unit_seen" -eq 0 ] || { custom_restore_error 'duplicate Hermes unit mapping'; exit 1; }
                hermes_unit_seen=1
                ;;
            '.config/systemd/user/mc-chat-responder.service|.config/systemd/user/mc-chat-responder.service|unit')
                [ "$chat_unit_seen" -eq 0 ] || { custom_restore_error 'duplicate chat unit mapping'; exit 1; }
                chat_unit_seen=1
                ;;
            *)
                custom_restore_error 'manifest contains an unapproved mapping'
                exit 1
                ;;
        esac
        source_path="$dotfiles/$source_relative"
        custom_restore_check_source_file "$source_path" "source $source_relative" || exit 1
    done < "$manifest"

    if [ "$uid_seen" -ne 1 ] || [ "$chat_seen" -ne 1 ] ||
       [ "$hermes_unit_seen" -ne 1 ] || [ "$chat_unit_seen" -ne 1 ]; then
        custom_restore_error 'manifest must contain each of the four approved entries once'
        exit 1
    fi

    if [ -e "$target_home" ] || [ -L "$target_home" ]; then
        [ -d "$target_home" ] && [ ! -L "$target_home" ] || {
            custom_restore_error "target home is not a real directory: $target_home"
            exit 1
        }
        [ "$(stat -c '%u:%g' -- "$target_home")" = "$expected_uid:$expected_gid" ] || {
            custom_restore_error "target home ownership does not match $expected_uid:$expected_gid"
            exit 1
        }
    fi
    if [ -e "$hermes_dir" ] || [ -L "$hermes_dir" ]; then
        [ -d "$hermes_dir" ] && [ ! -L "$hermes_dir" ] || {
            custom_restore_error "target .hermes is not a real directory: $hermes_dir"
            exit 1
        }
        [ "$(stat -c '%u:%g' -- "$hermes_dir")" = "$expected_uid:$expected_gid" ] || {
            custom_restore_error "target .hermes ownership does not match $expected_uid:$expected_gid"
            exit 1
        }
    fi
    if [ -e "$helper" ] || [ -L "$helper" ]; then
        [ -f "$helper" ] && [ ! -L "$helper" ] || {
            custom_restore_error "target Hermes helper is not a regular file: $helper"
            exit 1
        }
        [ "$(stat -c '%u:%g' -- "$helper")" = "$expected_uid:$expected_gid" ] || {
            custom_restore_error "target Hermes helper ownership does not match $expected_uid:$expected_gid"
            exit 1
        }
    fi
)

restore_hermes_bridge() (
    set -euo pipefail
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: restore_hermes_bridge MANIFEST DOTFILES TARGET_HOME RECOVERY_ROOT UID GID'
        exit 2
    fi
    local manifest="$1" dotfiles="$2" target_home="$3" recovery_root="$4"
    local target_uid="$5" target_gid="$6"
    local source="$dotfiles/.hermes/agy_bridge.py"
    local hermes_dir="$target_home/.hermes" destination="$target_home/.hermes/agy_bridge.py"
    local entry="$recovery_root/hermes-bridge" previous="$recovery_root/hermes-bridge/previous"
    local state_file="$recovery_root/hermes-bridge/prior-state.txt"
    local temp_file="" temp_identity="" restore_temp="" restore_temp_identity=""
    local committed_identity="" current_identity="" source_hash temp_hash previous_hash
    local hermes_dir_was_present=0 had_previous=0 committed=0 commit_uncertain=0
    local previous_mode previous_owner hermes_dir_mode="" hermes_dir_owner=""

    preflight_custom_service_restore "$manifest" "$dotfiles" "$target_home" \
        "$target_uid" "$target_gid" || exit 1
    custom_restore_safe_path "$recovery_root" 1 || exit 1
    source_hash="$(sha256sum -- "$source" | awk '{print $1}')" || exit 1
    if [ -f "$destination" ] &&
       [ "$(sha256sum -- "$destination" | awk '{print $1}')" = "$source_hash" ] &&
       [ "$(stat -c '%a:%u:%g' -- "$destination")" = "644:$target_uid:$target_gid" ]; then
        printf 'Hermes helper already matches source and ownership: %s\n' "$destination"
        exit 0
    fi
    if [ -e "$entry" ] || [ -L "$entry" ]; then
        custom_restore_error "recovery entry already exists; refusing to overwrite: $entry"
        exit 1
    fi
    if [ -d "$hermes_dir" ]; then
        hermes_dir_was_present=1
        hermes_dir_mode="$(stat -c '%a' -- "$hermes_dir")" || exit 1
        hermes_dir_owner="$(stat -c '%u:%g' -- "$hermes_dir")" || exit 1
    fi
    if [ -f "$destination" ]; then had_previous=1; fi

    local recovery_parent
    recovery_parent="$(dirname -- "$recovery_root")" || exit 1
    custom_restore_validate_private_directory "$recovery_parent" \
        "$target_uid" "$target_gid" || exit 1
    custom_restore_ensure_private_directory "$recovery_parent" \
        "$target_uid" "$target_gid" || exit 1
    custom_restore_ensure_private_directory "$recovery_root" \
        "$target_uid" "$target_gid" || exit 1
    custom_restore_ensure_private_directory "$entry" \
        "$target_uid" "$target_gid" || exit 1
    if [ "$had_previous" -eq 1 ]; then
        run_root cp -a -- "$destination" "$previous" || exit 1
        previous_mode="$(stat -c '%a' -- "$destination")" || exit 1
        previous_owner="$(stat -c '%u:%g' -- "$destination")" || exit 1
        previous_hash="$(sha256sum -- "$destination" | awk '{print $1}')" || exit 1
        [ "$(sha256sum -- "$previous" | awk '{print $1}')" = "$previous_hash" ] || {
            custom_restore_error 'recovery copy did not preserve the previous helper bytes'
            exit 1
        }
        [ "$(stat -c '%a:%u:%g' -- "$previous")" = \
          "$previous_mode:$target_uid:$target_gid" ] || {
            custom_restore_error 'recovery copy did not preserve prior helper metadata'
            exit 1
        }
        printf 'present=1\nsha256=%s\nmode=%s\nowner=%s\nhermes_dir_present=1\nhermes_dir_mode=%s\nhermes_dir_owner=%s\n' \
            "$previous_hash" "$previous_mode" "$previous_owner" \
            "$hermes_dir_mode" "$hermes_dir_owner" |
            run_root tee -- "$state_file" > /dev/null || exit 1
    elif [ "$hermes_dir_was_present" -eq 1 ]; then
        printf 'present=0\nhermes_dir_present=1\nhermes_dir_mode=%s\nhermes_dir_owner=%s\n' \
            "$hermes_dir_mode" "$hermes_dir_owner" |
            run_root tee -- "$state_file" > /dev/null || exit 1
    else
        printf 'present=0\nhermes_dir_present=0\n' |
            run_root tee -- "$state_file" > /dev/null || exit 1
    fi
    run_root chmod 0600 "$state_file" || exit 1
    run_root chown "$target_uid:$target_gid" "$state_file" || exit 1

    rollback_transaction() {
        local failed=0
        if [ -n "$temp_file" ] && { [ -e "$temp_file" ] || [ -L "$temp_file" ]; }; then
            if [ -n "$temp_identity" ] && [ -f "$temp_file" ] && [ ! -L "$temp_file" ] &&
               [ "$(stat -c '%d:%i:%u:%g' -- "$temp_file")" = "$temp_identity" ]; then
                run_root rm -f -- "$temp_file" || failed=1
            else
                custom_restore_error "staging path changed; leaving it untouched at $temp_file"
                failed=1
            fi
        fi
        if [ "$committed" -eq 1 ]; then
            if ! custom_restore_safe_path "$recovery_root" 0 ||
               [ ! -d "$recovery_root" ] || [ -L "$recovery_root" ] ||
               [ "$(stat -c '%a:%u:%g' -- "$recovery_root")" != "700:$target_uid:$target_gid" ] ||
               ! custom_restore_safe_path "$destination" 0 ||
               [ -L "$destination" ] || [ ! -f "$destination" ]; then
                custom_restore_error "committed helper is no longer a regular file; recovery retained at $previous"
                failed=1
            else
                current_identity="$(stat -c '%d:%i:%u:%g' -- "$destination")" || failed=1
                if [ "$failed" -eq 0 ] && [ "$current_identity" != "$committed_identity" ]; then
                    custom_restore_error "committed helper changed; preserving destination and recovery at $previous"
                    failed=1
                fi
            fi
            if [ "$failed" -eq 0 ] && [ "$had_previous" -eq 1 ]; then
                if ! custom_restore_safe_path "$previous" 0 || [ ! -f "$previous" ] || [ -L "$previous" ]; then
                    custom_restore_error "before-image is unsafe or missing; committed helper left in place at $destination"
                    failed=1
                elif [ "$(sha256sum -- "$previous" | awk '{print $1}')" != "$previous_hash" ] ||
                     [ "$(stat -c '%a:%u:%g' -- "$previous")" != "$previous_mode:$previous_owner" ]; then
                    custom_restore_error "before-image changed; committed helper left in place and recovery path retained at $previous"
                    failed=1
                elif ! restore_temp="$(run_root mktemp -p "$hermes_dir" '.agy_bridge.py.rollback.XXXXXX')"; then
                    failed=1
                elif [[ "$restore_temp" != "$hermes_dir"/.agy_bridge.py.rollback.* ]] ||
                     [ -L "$restore_temp" ] || [ ! -f "$restore_temp" ]; then
                    custom_restore_error "rollback staging path is unsafe; recovery retained at $previous"
                    failed=1
                else
                    restore_temp_identity="$(stat -c '%d:%i:%u:%g' -- "$restore_temp")" || failed=1
                    if [ "$failed" -eq 0 ] && ! run_root cp -a -- "$previous" "$restore_temp"; then
                        custom_restore_error "rollback copy failed; committed helper left in place and recovery retained at $previous"
                        failed=1
                    fi
                    if [ "$failed" -eq 0 ]; then
                        local staged_hash staged_metadata
                        staged_hash="$(sha256sum -- "$restore_temp" | awk '{print $1}')" || failed=1
                        staged_metadata="$(stat -c '%a:%u:%g' -- "$restore_temp")" || failed=1
                        if [ "$failed" -eq 0 ] &&
                           { [ "$staged_hash" != "$previous_hash" ] ||
                             [ "$staged_metadata" != "$previous_mode:$previous_owner" ]; }; then
                            custom_restore_error "rollback copy verification failed; committed helper left in place and recovery retained at $previous"
                            failed=1
                        fi
                    fi
                    if [ "$failed" -eq 0 ]; then
                        restore_temp_identity="$(stat -c '%d:%i:%u:%g' -- "$restore_temp")" || failed=1
                        if ! custom_restore_safe_path "$destination" 0; then
                            custom_restore_error "destination path changed before rollback publish; recovery retained at $previous"
                            failed=1
                        fi
                        if [ "$failed" -eq 0 ]; then
                            current_identity="$(stat -c '%d:%i:%u:%g' -- "$destination")" || failed=1
                        fi
                        if [ "$failed" -eq 0 ] && [ "$current_identity" != "$committed_identity" ]; then
                            custom_restore_error "destination changed before rollback publish; recovery retained at $previous"
                            failed=1
                        elif [ "$failed" -eq 0 ] && run_root mv -T -- "$restore_temp" "$destination"; then
                            restore_temp=""
                            restore_temp_identity=""
                        elif [ "$failed" -eq 0 ] && [ ! -e "$restore_temp" ] &&
                             [ ! -L "$restore_temp" ] &&
                             [ "$(stat -c '%d:%i:%u:%g' -- "$destination")" = "$restore_temp_identity" ]; then
                            restore_temp=""
                            restore_temp_identity=""
                            custom_restore_error 'rollback rename returned failure after publishing; verifying restored bytes'
                        else
                            custom_restore_error "rollback rename failed; committed helper left in place and recovery retained at $previous"
                            failed=1
                        fi
                        if [ "$failed" -eq 0 ] && [ -z "$restore_temp" ]; then
                            local restored_hash restored_metadata
                            restored_hash="$(sha256sum -- "$destination" | awk '{print $1}')" || failed=1
                            restored_metadata="$(stat -c '%a:%u:%g' -- "$destination")" || failed=1
                            if [ "$failed" -eq 0 ] &&
                               { [ "$restored_hash" != "$previous_hash" ] ||
                                 [ "$restored_metadata" != "$previous_mode:$previous_owner" ]; }; then
                                custom_restore_error "published rollback failed independent verification; recovery retained at $previous"
                                failed=1
                            fi
                        fi
                    fi
                    if [ -n "$restore_temp" ] && [ -n "$restore_temp_identity" ]; then
                        local current_temp_identity
                        if [ -f "$restore_temp" ] && [ ! -L "$restore_temp" ]; then
                            current_temp_identity="$(stat -c '%d:%i:%u:%g' -- "$restore_temp")" || failed=1
                            if [ "$current_temp_identity" = "$restore_temp_identity" ]; then
                                run_root rm -f -- "$restore_temp" || failed=1
                            else
                                custom_restore_error "rollback temporary changed; leaving it untouched at $restore_temp"
                                failed=1
                            fi
                        else
                            custom_restore_error "rollback temporary is no longer a regular file; leaving path untouched: $restore_temp"
                            failed=1
                        fi
                    fi
                fi
            elif [ "$failed" -eq 0 ]; then
                run_root rm -f -- "$destination" || failed=1
                if [ -e "$destination" ] || [ -L "$destination" ]; then failed=1; fi
            fi
        elif [ "$commit_uncertain" -eq 1 ]; then
            custom_restore_error "rename outcome is uncertain; preserving destination and recovery entry at $entry"
            failed=1
        fi
        if [ "$hermes_dir_was_present" -eq 0 ] && [ -d "$hermes_dir" ]; then
            run_root rmdir -- "$hermes_dir" 2>/dev/null || failed=1
        fi
        return "$failed"
    }

    if [ ! -d "$hermes_dir" ]; then
        if ! custom_restore_ensure_directory "$hermes_dir" \
            "$target_uid" "$target_gid" 0700; then
            rollback_transaction || custom_restore_error 'rollback after directory setup failure was incomplete'
            custom_restore_error 'could not prepare the target .hermes directory'
            exit 1
        fi
    fi

    if ! temp_file="$(run_root mktemp -p "$hermes_dir" '.agy_bridge.py.bootstrap.XXXXXX')"; then
        rollback_transaction || custom_restore_error 'rollback after staging failure was incomplete'
        custom_restore_error 'could not create same-filesystem helper staging file'
        exit 1
    fi
    temp_identity="$(stat -c '%d:%i:%u:%g' -- "$temp_file")" || {
        rollback_transaction || custom_restore_error 'rollback after staging identity failure was incomplete'
        exit 1
    }
    if ! run_root install -m 0644 -- "$source" "$temp_file" ||
       ! run_root chown "$target_uid:$target_gid" "$temp_file" ||
       ! run_root chmod 0644 "$temp_file"; then
        rollback_transaction || custom_restore_error 'rollback after staging failure was incomplete'
        custom_restore_error 'could not prepare the exact helper bytes and ownership'
        exit 1
    fi
    temp_identity="$(stat -c '%d:%i:%u:%g' -- "$temp_file")" || {
        rollback_transaction || custom_restore_error 'rollback after staged identity verification was incomplete'
        exit 1
    }
    temp_hash="$(sha256sum -- "$temp_file" | awk '{print $1}')" || {
        rollback_transaction || custom_restore_error 'rollback after hash failure was incomplete'
        exit 1
    }
    if [ "$temp_hash" != "$source_hash" ]; then
        rollback_transaction || custom_restore_error 'rollback after staging verification failure was incomplete'
        custom_restore_error 'staged helper hash differs from its source'
        exit 1
    fi
    # Recheck source and destination immediately before the atomic commit.
    [ "$(sha256sum -- "$source" | awk '{print $1}')" = "$source_hash" ] || {
        rollback_transaction || custom_restore_error 'rollback after source recheck failure was incomplete'
        custom_restore_error 'source helper changed during restore'
        exit 1
    }
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        rollback_transaction || custom_restore_error 'rollback after destination recheck failure was incomplete'
        custom_restore_error 'destination changed to a non-regular path during restore'
        exit 1
    fi
    custom_restore_safe_path "$destination" 1 || {
        rollback_transaction || custom_restore_error 'rollback after destination path change was incomplete'
        exit 1
    }
    if [ "$had_previous" -eq 1 ]; then
        if [ ! -f "$destination" ] || [ -L "$destination" ] ||
           [ "$(sha256sum -- "$destination" | awk '{print $1}')" != "$previous_hash" ] ||
           [ "$(stat -c '%a:%u:%g' -- "$destination")" != "$previous_mode:$previous_owner" ]; then
            rollback_transaction || custom_restore_error 'rollback after destination identity change was incomplete'
            custom_restore_error 'target helper changed after preflight; refusing to replace it'
            exit 1
        fi
    elif [ -e "$destination" ] || [ -L "$destination" ]; then
        rollback_transaction || custom_restore_error 'rollback after destination creation was incomplete'
        custom_restore_error 'target helper appeared after preflight; refusing to replace it'
        exit 1
    fi
    temp_identity="$(stat -c '%d:%i:%u:%g' -- "$temp_file")" || {
        rollback_transaction || custom_restore_error 'rollback after staged identity recheck was incomplete'
        exit 1
    }
    if run_root mv -T -- "$temp_file" "$destination"; then
        temp_file=""
        committed=1
        committed_identity="$temp_identity"
    else
        local rename_status=$?
        if [ ! -e "$temp_file" ] && [ ! -L "$temp_file" ] && [ -f "$destination" ] &&
           [ ! -L "$destination" ] &&
           [ "$(stat -c '%d:%i:%u:%g' -- "$destination")" = "$temp_identity" ]; then
            temp_file=""
            committed=1
            committed_identity="$temp_identity"
            custom_restore_error "atomic helper rename returned status $rename_status after publishing; attempting verified rollback"
        elif [ -e "$temp_file" ] && [ ! -L "$temp_file" ] &&
             [ "$(stat -c '%d:%i:%u:%g' -- "$temp_file")" = "$temp_identity" ]; then
            custom_restore_error "atomic helper rename failed with status $rename_status before publication"
        else
            commit_uncertain=1
            custom_restore_error "atomic helper rename returned status $rename_status with an uncertain publication state"
        fi
        rollback_transaction || custom_restore_error "rollback after rename failure was incomplete; recovery retained at $entry"
        custom_restore_error 'atomic helper rename failed'
        exit 1
    fi

    if [ "$(sha256sum -- "$destination" | awk '{print $1}')" != "$source_hash" ] ||
       [ "$(stat -c '%a:%u:%g' -- "$destination")" != "644:$target_uid:$target_gid" ]; then
        rollback_transaction || custom_restore_error 'post-commit rollback was incomplete'
        custom_restore_error 'committed helper failed hash, mode, or ownership verification'
        exit 1
    fi
    printf 'Hermes helper restored atomically: %s (sha256 %s)\n' "$destination" "$source_hash"
)

rollback_hermes_bridge() (
    set -euo pipefail
    if [ "$#" -ne 4 ]; then
        custom_restore_error 'usage: rollback_hermes_bridge RECOVERY_ROOT TARGET_HOME UID GID'
        exit 2
    fi
    local recovery_root="$1" target_home="$2" target_uid="$3" target_gid="$4"
    local entry="$recovery_root/hermes-bridge" state_file="$recovery_root/hermes-bridge/prior-state.txt"
    local previous="$recovery_root/hermes-bridge/previous"
    local hermes_dir="$target_home/.hermes" destination="$target_home/.hermes/agy_bridge.py"
    local state_present state_dir_present previous_hash previous_mode previous_owner
    local prior_dir_mode="" prior_dir_owner="" current_owner temp_file="" marker_temp=""
    local marker="$recovery_root/hermes-bridge/rolled-back"
    [[ "$target_uid" =~ ^[0-9]+$ && "$target_gid" =~ ^[0-9]+$ ]] || {
        custom_restore_error 'target UID/GID must be decimal numbers'
        exit 1
    }
    custom_restore_safe_path "$recovery_root" 0 || exit 1
    custom_restore_safe_path "$target_home" 0 || exit 1
    [ -d "$entry" ] && [ ! -L "$entry" ] &&
        [ "$(stat -c '%u:%a' -- "$entry")" = "$target_uid:700" ] || {
            custom_restore_error "private recovery entry is missing or unsafe: $entry"
            exit 1
        }
    [ -f "$state_file" ] && [ ! -L "$state_file" ] &&
        [ "$(stat -c '%u:%a' -- "$state_file")" = "$target_uid:600" ] || {
            custom_restore_error "prior-state record is missing or unsafe: $state_file"
            exit 1
        }
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        [ -f "$marker" ] && [ ! -L "$marker" ] &&
            [ "$(stat -c '%u:%a' -- "$marker")" = "$target_uid:600" ] &&
            grep -Fxq 'rolled-back=1' "$marker" || {
                custom_restore_error 'rollback marker is unsafe or malformed'
                exit 1
            }
        printf 'Hermes restore transaction was already rolled back.\n'
        exit 0
    fi
    if ! awk -F= '
        NF != 2 { exit 1 }
        $1 !~ /^(present|sha256|mode|owner|hermes_dir_present|hermes_dir_mode|hermes_dir_owner)$/ { exit 1 }
        seen[$1]++ { exit 1 }
        END { if (NR < 2) exit 1 }
    ' "$state_file"; then
        custom_restore_error 'prior-state record is malformed or contains duplicate fields'
        exit 1
    fi
    state_value() {
        awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); count++ }
            END { if (count != 1) exit 1 }' "$state_file"
    }
    state_present="$(state_value present)" || exit 1
    state_dir_present="$(state_value hermes_dir_present)" || exit 1
    case "$state_present|$state_dir_present" in
        '1|1')
            [ "$(awk 'END { print NR }' "$state_file")" -eq 7 ] || {
                custom_restore_error 'present-helper recovery record has an unexpected field count'
                exit 1
            }
            previous_hash="$(state_value sha256)" || exit 1
            previous_mode="$(state_value mode)" || exit 1
            previous_owner="$(state_value owner)" || exit 1
            prior_dir_mode="$(state_value hermes_dir_mode)" || exit 1
            prior_dir_owner="$(state_value hermes_dir_owner)" || exit 1
            [[ "$previous_hash" =~ ^[[:xdigit:]]{64}$ &&
               "$previous_mode" =~ ^[0-7]{3,4}$ &&
               "$previous_owner" = "$target_uid:$target_gid" &&
               "$prior_dir_mode" =~ ^[0-7]{3,4}$ &&
               "$prior_dir_owner" = "$target_uid:$target_gid" ]] || {
                custom_restore_error 'saved helper or directory metadata is malformed'
                exit 1
            }
            [ -f "$previous" ] && [ ! -L "$previous" ] || {
                custom_restore_error 'saved previous helper is missing or unsafe'
                exit 1
            }
            [ "$(sha256sum -- "$previous" | awk '{print $1}')" = "$previous_hash" ] &&
                [ "$(stat -c '%a:%u:%g' -- "$previous")" = \
                  "$previous_mode:$previous_owner" ] || {
                    custom_restore_error 'saved previous helper does not match its record'
                    exit 1
                }
            ;;
        '0|0')
            [ "$(awk 'END { print NR }' "$state_file")" -eq 2 ] || {
                custom_restore_error 'absent-helper recovery record has an unexpected field count'
                exit 1
            }
            ;;
        '0|1')
            [ "$(awk 'END { print NR }' "$state_file")" -eq 4 ] || {
                custom_restore_error 'preexisting-directory recovery record has an unexpected field count'
                exit 1
            }
            prior_dir_mode="$(state_value hermes_dir_mode)" || exit 1
            prior_dir_owner="$(state_value hermes_dir_owner)" || exit 1
            [[ "$prior_dir_mode" =~ ^[0-7]{3,4}$ &&
               "$prior_dir_owner" = "$target_uid:$target_gid" ]] || {
                custom_restore_error 'saved .hermes directory metadata is malformed'
                exit 1
            }
            ;;
        *)
            custom_restore_error 'prior-state record has an unsupported presence combination'
            exit 1
            ;;
    esac
    if [ "$state_dir_present" -eq 1 ] &&
       [ "$prior_dir_owner" != "$target_uid:$target_gid" ]; then
        custom_restore_error 'saved .hermes directory owner does not match selected target user'
        exit 1
    fi

    [ -d "$target_home" ] && [ ! -L "$target_home" ] &&
        [ "$(stat -c '%u:%g' -- "$target_home")" = "$target_uid:$target_gid" ] || {
            custom_restore_error 'target home changed ownership or type before rollback'
            exit 1
        }
    custom_restore_safe_path "$hermes_dir" 1 || exit 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] &&
            [ "$(stat -c '%u:%g' -- "$destination")" = "$target_uid:$target_gid" ] || {
                custom_restore_error 'Hermes helper changed type or ownership before rollback'
                exit 1
            }
    fi
    if [ -e "$hermes_dir" ] || [ -L "$hermes_dir" ]; then
        [ -d "$hermes_dir" ] && [ ! -L "$hermes_dir" ] &&
            [ "$(stat -c '%u:%g' -- "$hermes_dir")" = "$target_uid:$target_gid" ] || {
                custom_restore_error '.hermes changed ownership or type before rollback'
                exit 1
            }
    elif [ "$state_dir_present" -eq 1 ]; then
        run_root install -d -m "$prior_dir_mode" "$hermes_dir" || exit 1
        run_root chown "$prior_dir_owner" "$hermes_dir" || exit 1
    fi

    trap 'if [ -n "$temp_file" ] && { [ -e "$temp_file" ] || [ -L "$temp_file" ]; }; then run_root rm -f -- "$temp_file"; fi; if [ -n "$marker_temp" ] && { [ -e "$marker_temp" ] || [ -L "$marker_temp" ]; }; then run_root rm -f -- "$marker_temp"; fi' EXIT

    if [ "$state_present" -eq 1 ]; then
        temp_file="$(run_root mktemp -p "$hermes_dir" '.agy_bridge.py.rollback.XXXXXX')" || exit 1
        run_root cp -a -- "$previous" "$temp_file" || exit 1
        [ "$(sha256sum -- "$temp_file" | awk '{print $1}')" = "$previous_hash" ] &&
            [ "$(stat -c '%a:%u:%g' -- "$temp_file")" = \
              "$previous_mode:$previous_owner" ] || {
                run_root rm -f -- "$temp_file"
                custom_restore_error 'rollback staging failed prior helper verification'
                exit 1
            }
        run_root mv -T -- "$temp_file" "$destination" || exit 1
        [ "$(sha256sum -- "$destination" | awk '{print $1}')" = "$previous_hash" ] &&
            [ "$(stat -c '%a:%u:%g' -- "$destination")" = \
              "$previous_mode:$previous_owner" ] || {
                custom_restore_error 'restored previous helper failed verification'
                exit 1
            }
    else
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            [ -f "$destination" ] && [ ! -L "$destination" ] || {
                custom_restore_error 'refusing to remove a changed non-regular helper during rollback'
                exit 1
            }
            current_owner="$(stat -c '%u:%g' -- "$destination")"
            [ "$current_owner" = "$target_uid:$target_gid" ] || {
                custom_restore_error 'refusing to remove helper with unexpected ownership during rollback'
                exit 1
            }
            run_root rm -f -- "$destination" || exit 1
        fi
    fi

    if [ "$state_dir_present" -eq 1 ]; then
        [ -d "$hermes_dir" ] && [ ! -L "$hermes_dir" ] || {
            custom_restore_error 'preexisting .hermes directory disappeared during rollback'
            exit 1
        }
        [ "$(stat -c '%a:%u:%g' -- "$hermes_dir")" = \
          "$prior_dir_mode:$prior_dir_owner" ] || {
            custom_restore_error 'preexisting .hermes directory metadata changed'
            exit 1
        }
    elif [ -d "$hermes_dir" ]; then
        run_root rmdir -- "$hermes_dir" || {
            custom_restore_error 'new .hermes directory contains unrelated files; left it intact'
            exit 1
        }
    fi
    marker_temp="$(run_root mktemp -p "$entry" '.rolled-back.XXXXXX')" || exit 1
    printf 'rolled-back=1\n' | run_root tee -- "$marker_temp" > /dev/null || exit 1
    run_root chmod 0600 "$marker_temp" || exit 1
    run_root chown "$target_uid:$target_gid" "$marker_temp" || exit 1
    run_root mv -T -- "$marker_temp" "$marker" || exit 1
    marker_temp=""
    printf 'Hermes helper transaction rolled back from %s.\n' "$entry"
)

custom_restore_entry_tree_digest() (
    set -o pipefail
    if [ "$#" -ne 1 ]; then return 2; fi
    local entry="$1" parent name
    parent="$(dirname -- "$entry")" || exit 1
    name="$(basename -- "$entry")" || exit 1
    tar --sort=name --format=gnu --numeric-owner --owner=0 --group=0 \
        --mtime='@0' -cf - -C "$parent" -- "$name" | sha256sum | awk '{print $1}'
)

custom_restore_directory_tree_digest() (
    set -o pipefail
    if [ "$#" -ne 1 ]; then return 2; fi
    tar --sort=name --format=gnu --numeric-owner --owner=0 --group=0 \
        --mtime='@0' -cf - -C "$1" . | sha256sum | awk '{print $1}'
)

custom_restore_capture_directory_list() {
    if [ "$#" -ne 3 ]; then return 2; fi
    local source_directory="$1" list_root="$2" list_name="$3"
    local cached_list="$list_root/$list_name.entries.nul"
    local cached_digest="$list_root/$list_name.tree.sha256"
    local current_list current_digest
    custom_restore_safe_path "$source_directory" 1 || return 1
    custom_restore_safe_path "$list_root" 0 || return 1
    current_list="$(mktemp "$list_root/.entries.XXXXXX")" || return 1
    if [ -L "$source_directory" ]; then
        rm -f -- "$current_list"
        custom_restore_error "selected source directory is linked: $source_directory"
        return 1
    elif [ -d "$source_directory" ]; then
        custom_restore_validate_tree_types "$source_directory" source || {
            rm -f -- "$current_list"
            return 1
        }
        if ! (set -o pipefail; find -P "$source_directory" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z) > "$current_list"; then
            rm -f -- "$current_list"
            custom_restore_error "could not enumerate selected source entries: $source_directory"
            return 1
        fi
        current_digest="$(custom_restore_directory_tree_digest "$source_directory")" || {
            rm -f -- "$current_list"
            custom_restore_error "could not fingerprint selected source tree: $source_directory"
            return 1
        }
    else
        : > "$current_list" || { rm -f -- "$current_list"; return 1; }
        current_digest=ABSENT
    fi
    if [ -e "$cached_list" ] || [ -L "$cached_list" ]; then
        if [ -L "$cached_list" ] || [ ! -f "$cached_list" ] || ! cmp -s -- "$cached_list" "$current_list"; then
            rm -f -- "$current_list"
            custom_restore_error "selected source entry list changed after preflight: $source_directory"
            return 1
        fi
        if [ -L "$cached_digest" ] || [ ! -f "$cached_digest" ]; then
            rm -f -- "$current_list"
            custom_restore_error "selected source contents changed after preflight: $source_directory"
            return 1
        fi
        local recorded_digest
        recorded_digest="$(cat -- "$cached_digest")" || { rm -f -- "$current_list"; return 1; }
        if [ "$recorded_digest" != "$current_digest" ]; then
            rm -f -- "$current_list"
            custom_restore_error "selected source contents changed after preflight: $source_directory"
            return 1
        fi
        rm -f -- "$current_list" || return 1
    else
        [ ! -e "$cached_digest" ] && [ ! -L "$cached_digest" ] || {
            rm -f -- "$current_list"
            custom_restore_error "incomplete selected source preflight record: $source_directory"
            return 1
        }
        if ! mv -T -- "$current_list" "$cached_list"; then
            rm -f -- "$current_list"
            custom_restore_error "could not store selected source entry list: $source_directory"
            return 1
        fi
        printf '%s\n' "$current_digest" > "$cached_digest" || return 1
        chmod 0600 "$cached_digest" || return 1
    fi
}

custom_restore_validate_destination_directory() {
    if [ "$#" -ne 3 ]; then return 2; fi
    local path="$1" uid="$2" gid="$3"
    custom_restore_safe_path "$path" 1 || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -d "$path" ] && [ ! -L "$path" ] || {
            custom_restore_error "selected destination is not a real directory: $path"
            return 1
        }
        [ "$(stat -c '%u:%g' -- "$path")" = "$uid:$gid" ] || {
            custom_restore_error "selected destination has unexpected ownership: $path"
            return 1
        }
    fi
}

custom_restore_validate_destination_entry() {
    if [ "$#" -ne 5 ]; then return 2; fi
    local source="$1" destination="$2" backup="$3" uid="$4"
    local gid="$5" source_kind
    custom_restore_safe_path "$source" 0 1 || return 1
    custom_restore_safe_path "$destination" 1 1 || return 1
    custom_restore_safe_path "$backup" 1 || return 1
    if [ -L "$source" ]; then
        source_kind=link
        local source_target
        source_target="$(readlink -- "$source")" || return 1
        custom_restore_validate_source_link "$source" "$source_target" || return 1
    elif [ -d "$source" ]; then
        source_kind=directory
    elif [ -f "$source" ]; then
        source_kind=file
    else
        custom_restore_error "selected source entry has an unsupported type: $source"
        return 1
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        case "$source_kind" in
            directory) [ -d "$destination" ] || { custom_restore_error "destination type differs from source: $destination"; return 1; } ;;
            file) [ -f "$destination" ] || { custom_restore_error "destination type differs from source: $destination"; return 1; } ;;
            link)
                [ -L "$destination" ] || { custom_restore_error "destination type differs from source: $destination"; return 1; }
                [ "$(readlink -- "$source")" = "$(readlink -- "$destination")" ] || {
                    custom_restore_error "refusing to replace a different destination symlink: $destination"
                    return 1
                }
                ;;
        esac
        [ "$(stat -c '%u:%g' -- "$destination")" = "$uid:$gid" ] || {
            custom_restore_error "selected destination entry has unexpected ownership: $destination"
            return 1
        }
    fi
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        [ ! -L "$backup" ] && { [ -d "$backup" ] || [ -f "$backup" ]; } || {
            custom_restore_error "selected recovery entry is linked or special: $backup"
            return 1
        }
    fi
    [ "$gid" -ge 0 ] || return 1
}

preflight_selected_user_configuration() {
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: preflight_selected_user_configuration REPO_ROOT TARGET_HOME BACKUP_BASE UID GID MANIFEST'
        return 2
    fi
    local repo_root="$1" target_home="$2" backup_base="$3" target_uid="$4" target_gid="$5" manifest="$6"
    local dotfiles="$repo_root/dotfiles" list_root="${CUSTOM_RESTORE_PREFLIGHT_DIR:-}"
    local list_name source_directory destination_directory backup_directory list_file name source_entry
    local mode metadata current_uid current_gid
    local -a source_dirs=() destination_dirs=() recovery_dirs=() list_names=()
    [[ "$target_uid" =~ ^[0-9]+$ && "$target_gid" =~ ^[0-9]+$ ]] || {
        custom_restore_error 'target UID/GID must be decimal numbers'
        return 1
    }
    custom_restore_safe_path "$repo_root" 0 || return 1
    [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || {
        custom_restore_error "repository source is not a real directory: $repo_root"
        return 1
    }
    custom_restore_safe_path "$dotfiles" 0 || return 1
    custom_restore_validate_private_directory "$backup_base" "$target_uid" "$target_gid" || return 1
    if [ -z "$list_root" ]; then
        custom_restore_error 'selected-user preflight list directory was not allocated'
        return 1
    fi
    custom_restore_safe_path "$list_root" 0 || return 1
    [ -d "$list_root" ] && [ ! -L "$list_root" ] || return 1
    metadata="$(stat -c '%a:%u:%g' -- "$list_root")" || return 1
    current_uid="$(id -u)" || return 1
    current_gid="$(id -g)" || return 1
    [ "$metadata" = "700:$current_uid:$current_gid" ] || {
        custom_restore_error "selected-user preflight directory is not private: $list_root"
        return 1
    }

    preflight_custom_service_restore "$manifest" "$dotfiles" "$target_home" \
        "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/.config" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/.local" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/.local/bin" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/.local/share" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/.local/share/applications" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/baby-step" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/baby-step/logs" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/baby-step/state" "$target_uid" "$target_gid" || return 1
    custom_restore_validate_destination_directory "$target_home/baby-step/backups" "$target_uid" "$target_gid" || return 1

    source_dirs=("$dotfiles/.config" "$dotfiles/.local/bin" \
        "$dotfiles/.local/share/applications" "$repo_root/baby-step")
    destination_dirs=("$target_home/.config" "$target_home/.local/bin" \
        "$target_home/.local/share/applications" "$target_home/baby-step")
    recovery_dirs=("$backup_base/user/.config" "$backup_base/user/.local/bin" \
        "$backup_base/user/.local/share/applications" "$backup_base/user/baby-step")
    list_names=(config local-bin applications baby-step)
    for index in 0 1 2 3; do
        source_directory="${source_dirs[$index]}"
        destination_directory="${destination_dirs[$index]}"
        backup_directory="${recovery_dirs[$index]}"
        list_name="${list_names[$index]}"
        custom_restore_capture_directory_list "$source_directory" "$list_root" "$list_name" || return 1
        custom_restore_validate_destination_directory "$destination_directory" \
            "$target_uid" "$target_gid" || return 1
        if [ -d "$destination_directory" ]; then
            custom_restore_validate_tree_types "$destination_directory" destination || return 1
        fi
        custom_restore_safe_path "$backup_directory" 1 || return 1
        list_file="$list_root/$list_name.entries.nul"
        while IFS= read -r -d '' name; do
            case "$name" in ''|.|..|*/*|*$'\t'*|*$'\r'*|*$'\n'*)
                custom_restore_error "selected source contains an unsafe entry name: $source_directory"
                return 1
                ;;
            esac
            source_entry="$source_directory/$name"
            custom_restore_validate_destination_entry "$source_entry" \
                "$destination_directory/$name" "$backup_directory/$name" \
                "$target_uid" "$target_gid" || return 1
        done < "$list_file"
    done
    if [ "${CUSTOM_RESTORE_CHECK_REPOSITORY:-1}" = 1 ]; then
        custom_restore_validate_destination_directory "$target_home/nixos-config" \
            "$target_uid" "$target_gid" || return 1
        if [ -d "$target_home/nixos-config" ]; then
            custom_restore_validate_tree_types "$target_home/nixos-config" destination || return 1
        fi
    fi
}

custom_restore_ensure_directory() {
    if [ "$#" -lt 3 ] || [ "$#" -gt 7 ]; then return 2; fi
    local path="$1" uid="$2" gid="$3" final_mode="${4:-0755}"
    local parent_uid="${5:-$2}" parent_gid="${6:-$3}" parent_mode="${7:-0755}"
    local current="/" component
    local -a parts=()
    [[ "$final_mode" =~ ^0?[0-7]{3,4}$ && "$parent_mode" =~ ^0?[0-7]{3,4}$ ]] || return 2
    custom_restore_safe_path "$path" 1 || return 1
    IFS='/' read -r -a parts <<< "${path#/}"
    for component in "${parts[@]}"; do
        current="${current%/}/$component"
        if [ -L "$current" ]; then
            custom_restore_error "refusing symlink while creating destination directory: $current"
            return 1
        elif [ -e "$current" ]; then
            [ -d "$current" ] || {
                custom_restore_error "destination path component is not a directory: $current"
                return 1
            }
        else
            if [ "$current" = "$path" ]; then
                run_root mkdir -m "$final_mode" -- "$current" || return 1
                run_root chown "$uid:$gid" -- "$current" || return 1
            else
                run_root mkdir -m "$parent_mode" -- "$current" || return 1
                run_root chown "$parent_uid:$parent_gid" -- "$current" || return 1
            fi
        fi
    done
    custom_restore_validate_destination_directory "$path" "$uid" "$gid"
}

backup_and_replace_entry() {
    if [ "$#" -ne 5 ]; then
        custom_restore_error 'usage: backup_and_replace_entry SOURCE DESTINATION BACKUP UID GID'
        return 2
    fi
    local source_entry="$1" destination_entry="$2" backup_entry="$3" target_uid="$4" target_gid="$5"
    local source_digest destination_digest
    custom_restore_safe_path "$source_entry" 0 1 || return 1
    custom_restore_safe_path "$destination_entry" 1 1 || return 1
    custom_restore_safe_path "$backup_entry" 1 || return 1
    if [ -d "$source_entry" ]; then
        custom_restore_validate_tree_types "$source_entry" source || return 1
    elif [ -L "$source_entry" ]; then
        custom_restore_validate_source_link "$source_entry" \
            "$(readlink -- "$source_entry")" || return 1
    fi
    if [ -d "$destination_entry" ]; then
        custom_restore_validate_tree_types "$destination_entry" destination || return 1
    fi
    if [ -e "$destination_entry" ] || [ -L "$destination_entry" ]; then
        source_digest="$(custom_restore_entry_tree_digest "$source_entry")" || return 1
        destination_digest="$(custom_restore_entry_tree_digest "$destination_entry")" || return 1
        if [ "$source_digest" = "$destination_digest" ]; then
            return 0
        fi
    fi
    custom_restore_ensure_directory "$(dirname -- "$destination_entry")" \
        "$target_uid" "$target_gid" || return 1
    if [ -e "$destination_entry" ] || [ -L "$destination_entry" ]; then
        custom_restore_safe_path "$destination_entry" 0 || return 1
        custom_restore_safe_path "$backup_entry" 1 || return 1
        if [ -e "$backup_entry" ] || [ -L "$backup_entry" ]; then
            custom_restore_error "recovery destination already exists: $backup_entry"
            return 1
        fi
        custom_restore_ensure_directory "$(dirname -- "$backup_entry")" \
            "$target_uid" "$target_gid" || return 1
        run_root mv -- "$destination_entry" "$backup_entry" || return 1
    fi
    custom_restore_safe_path "$destination_entry" 1 || return 1
    run_root cp -a -- "$source_entry" "$destination_entry" || return 1
    custom_restore_safe_path "$destination_entry" 0 1 || return 1
    run_root chown -hR "$target_uid:$target_gid" -- "$destination_entry" || return 1
    if [ -d "$destination_entry" ]; then
        custom_restore_validate_tree_types "$destination_entry" destination || return 1
    elif [ -L "$destination_entry" ]; then
        [ "$(readlink -- "$destination_entry")" = "$(readlink -- "$source_entry")" ] || {
            custom_restore_error "copied source link target differs after deployment: $destination_entry"
            return 1
        }
    fi
}

deploy_directory_entries() {
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: deploy_directory_entries SOURCE_DIR DEST_DIR BACKUP_DIR UID GID LIST_FILE'
        return 2
    fi
    local source_directory="$1" destination_directory="$2" backup_directory="$3"
    local target_uid="$4" target_gid="$5" list_file="$6" current_list name source_entry
    if [ ! -e "$source_directory" ] && [ ! -L "$source_directory" ]; then
        [ -f "$list_file" ] && [ ! -L "$list_file" ] &&
            [ ! -s "$list_file" ] &&
            [ "$(cat -- "${list_file%.entries.nul}.tree.sha256")" = ABSENT ] || {
                custom_restore_error "selected source directory disappeared after preflight: $source_directory"
                return 1
            }
        return 0
    fi
    [ -d "$source_directory" ] && [ ! -L "$source_directory" ] || {
        custom_restore_error "selected source directory changed type: $source_directory"
        return 1
    }
    custom_restore_validate_destination_directory "$destination_directory" "$target_uid" "$target_gid" || return 1
    current_list="$(mktemp "$CUSTOM_RESTORE_PREFLIGHT_DIR/.deploy-entries.XXXXXX")" || return 1
    custom_restore_validate_tree_types "$source_directory" source || return 1
    if [ -d "$destination_directory" ]; then
        custom_restore_validate_tree_types "$destination_directory" destination || return 1
    fi
    if ! (set -o pipefail; find -P "$source_directory" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z) > "$current_list"; then
        rm -f -- "$current_list"
        custom_restore_error "could not re-enumerate selected source: $source_directory"
        return 1
    fi
    if [ -L "$list_file" ] || [ ! -f "$list_file" ] || ! cmp -s -- "$list_file" "$current_list"; then
        rm -f -- "$current_list"
        custom_restore_error "selected source changed after complete preflight: $source_directory"
        return 1
    fi
    rm -f -- "$current_list" || return 1
    local cached_digest current_digest
    cached_digest="$(cat -- "${list_file%.entries.nul}.tree.sha256")" || return 1
    current_digest="$(custom_restore_directory_tree_digest "$source_directory")" || return 1
    [ "$cached_digest" = "$current_digest" ] || {
        custom_restore_error "selected source contents changed after preflight: $source_directory"
        return 1
    }
    custom_restore_ensure_directory "$destination_directory" "$target_uid" "$target_gid" || return 1
    while IFS= read -r -d '' name; do
        source_entry="$source_directory/$name"
        custom_restore_validate_destination_entry "$source_entry" \
            "$destination_directory/$name" "$backup_directory/$name" \
            "$target_uid" "$target_gid" || return 1
        backup_and_replace_entry "$source_entry" "$destination_directory/$name" \
            "$backup_directory/$name" "$target_uid" "$target_gid" || return 1
    done < "$list_file"
}

deploy_selected_user_configuration_impl() {
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: deploy_selected_user_configuration REPO_ROOT TARGET_HOME BACKUP_BASE UID GID MANIFEST'
        return 2
    fi
    local repo_root="$1" target_home="$2" backup_base="$3" target_uid="$4" target_gid="$5" manifest="$6"
    local dotfiles="$repo_root/dotfiles" list_root="$CUSTOM_RESTORE_PREFLIGHT_DIR"
    preflight_selected_user_configuration "$repo_root" "$target_home" "$backup_base" \
        "$target_uid" "$target_gid" "$manifest" || return 1
    if [ ! -d "$target_home" ]; then
        custom_restore_ensure_directory "$target_home" "$target_uid" "$target_gid" \
            0700 || return 1
    fi
    restore_hermes_bridge "$manifest" "$dotfiles" "$target_home" \
        "$backup_base/custom-services" "$target_uid" "$target_gid" || return 1

    deploy_directory_entries "$dotfiles/.config" "$target_home/.config" \
        "$backup_base/user/.config" "$target_uid" "$target_gid" \
        "$list_root/config.entries.nul" || return 1
    deploy_directory_entries "$dotfiles/.local/bin" "$target_home/.local/bin" \
        "$backup_base/user/.local/bin" "$target_uid" "$target_gid" \
        "$list_root/local-bin.entries.nul" || return 1
    deploy_directory_entries "$dotfiles/.local/share/applications" \
        "$target_home/.local/share/applications" \
        "$backup_base/user/.local/share/applications" "$target_uid" "$target_gid" \
        "$list_root/applications.entries.nul" || return 1
    deploy_directory_entries "$repo_root/baby-step" "$target_home/baby-step" \
        "$backup_base/user/baby-step" "$target_uid" "$target_gid" \
        "$list_root/baby-step.entries.nul" || return 1

    custom_restore_ensure_directory "$target_home/baby-step/logs" "$target_uid" "$target_gid" || return 1
    custom_restore_ensure_directory "$target_home/baby-step/state" "$target_uid" "$target_gid" || return 1
    custom_restore_ensure_directory "$target_home/baby-step/backups" "$target_uid" "$target_gid" || return 1

    [ "$(sha256sum -- "$dotfiles/.hermes/agy_bridge.py" | awk '{print $1}')" = \
      "$(sha256sum -- "$target_home/.hermes/agy_bridge.py" | awk '{print $1}')" ] || {
        custom_restore_error 'deployed Hermes helper differs from its source'
        return 1
    }
    cmp -s -- "$dotfiles/.config/systemd/user/agy-bridge.service" \
        "$target_home/.config/systemd/user/agy-bridge.service" || {
        custom_restore_error 'deployed Hermes unit differs from its source'
        return 1
    }
    printf 'Selected user configuration deployed; Hermes service was not started.\n'
}

deploy_selected_user_configuration() {
    if [ "$#" -ne 6 ]; then
        custom_restore_error 'usage: deploy_selected_user_configuration REPO_ROOT TARGET_HOME BACKUP_BASE UID GID MANIFEST'
        return 2
    fi
    local repo_root="$1" target_home="$2" backup_base="$3" target_uid="$4" target_gid="$5" manifest="$6"
    local created_preflight=0 status=0 current_uid current_gid metadata
    if [ -z "${CUSTOM_RESTORE_PREFLIGHT_DIR:-}" ]; then
        CUSTOM_RESTORE_PREFLIGHT_DIR="$(mktemp -d /tmp/custom-restore-preflight.XXXXXX)" || return 1
        chmod 0700 "$CUSTOM_RESTORE_PREFLIGHT_DIR" || return 1
        created_preflight=1
    fi
    if deploy_selected_user_configuration_impl "$repo_root" "$target_home" "$backup_base" \
        "$target_uid" "$target_gid" "$manifest"; then
        status=0
    else
        status=$?
    fi
    if [ "$created_preflight" -eq 1 ]; then
        if custom_restore_safe_path "$CUSTOM_RESTORE_PREFLIGHT_DIR" 0; then
            metadata="$(stat -c '%a:%u:%g' -- "$CUSTOM_RESTORE_PREFLIGHT_DIR")" || status=1
            current_uid="$(id -u)" || status=1
            current_gid="$(id -g)" || status=1
            if [ "$metadata" = "700:$current_uid:$current_gid" ]; then
                rm -rf -- "$CUSTOM_RESTORE_PREFLIGHT_DIR" || status=1
            else
                custom_restore_error "leaving unexpected preflight directory untouched: $CUSTOM_RESTORE_PREFLIGHT_DIR"
                status=1
            fi
        else
            status=1
        fi
        CUSTOM_RESTORE_PREFLIGHT_DIR=""
    fi
    return "$status"
}
