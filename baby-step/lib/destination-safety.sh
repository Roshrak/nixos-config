#!/usr/bin/env bash

backup_path_error() {
    printf 'Backup destination safety: %s\n' "$*" >&2
}

# Inspect every path component without resolving through it. Missing components
# are accepted only as a suffix; dangling links are rejected by the -L test.
backup_validate_path() {
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        backup_path_error 'usage: backup_validate_path ABSOLUTE_PATH directory|file [allow-missing]'
        return 2
    fi
    local path="$1" kind="$2" allow_missing="${3:-1}"
    local current=/ component index last missing_seen=0 mode owner expected_owner
    local -a components=()
    case "$path" in /*) ;; *) backup_path_error "path is not absolute: $path"; return 1 ;; esac
    case "$kind" in directory|file) ;; *) backup_path_error "unsupported path type: $kind"; return 2 ;; esac
    case "$allow_missing" in 0|1) ;; *) backup_path_error 'allow-missing must be 0 or 1'; return 2 ;; esac
    case "$path" in
        *[[:cntrl:]]*)
            backup_path_error "path contains a control character: $path"
            return 1
            ;;
    esac
    case "$path" in /|*/|*//*|*/./*|*/../*|*/.|*/..)
        backup_path_error "path is not normalized: $path"
        return 1
        ;;
    esac
    IFS='/' read -r -a components <<< "${path#/}"
    if [ "${#components[@]}" -eq 0 ]; then
        backup_path_error "path has no leaf component: $path"
        return 1
    fi
    last=$((${#components[@]} - 1))
    for index in "${!components[@]}"; do
        component="${components[$index]}"
        case "$component" in ''|.|..) backup_path_error "unsafe path component in $path"; return 1 ;; esac
        current="${current%/}/$component"
        if [ -L "$current" ]; then
            backup_path_error "refusing symlink path component: $current"
            return 1
        fi
        if [ -e "$current" ]; then
            if [ "$missing_seen" -eq 1 ]; then
                backup_path_error "path reappears below a missing ancestor: $current"
                return 1
            fi
            if [ "$index" -lt "$last" ] && [ ! -d "$current" ]; then
                backup_path_error "non-directory path component: $current"
                return 1
            fi
            if [ "$index" -eq "$last" ]; then
                if [ "$kind" = directory ] && [ ! -d "$current" ]; then
                    backup_path_error "destination is not a real directory: $current"
                    return 1
                fi
                if [ "$kind" = file ] && [ ! -f "$current" ]; then
                    backup_path_error "destination is not a regular file: $current"
                    return 1
                fi
            fi
        elif [ "$allow_missing" -eq 1 ]; then
            missing_seen=1
        else
            backup_path_error "required path component is missing: $current"
            return 1
        fi
    done
}

backup_validate_destination() {
    if [ "$#" -ne 3 ]; then
        backup_path_error 'usage: backup_validate_destination REPOSITORY_ROOT DESTINATION directory|file'
        return 2
    fi
    local root="$1" destination="$2" kind="$3"
    backup_validate_path "$root" directory 0 || return 1
    case "$destination" in
        "$root"/*) ;;
        *) backup_path_error "destination escapes repository root: $destination"; return 1 ;;
    esac
    backup_validate_path "$destination" "$kind" 1
}

backup_validate_private_directory() {
    if [ "$#" -ne 1 ]; then
        backup_path_error 'usage: backup_validate_private_directory DIRECTORY'
        return 2
    fi
    local path="$1" metadata expected
    backup_validate_path "$path" directory 0 || return 1
    metadata="$(stat -c '%a:%u:%g' -- "$path")" || return 1
    expected="700:$(id -u):$(id -g)" || return 1
    if [ "$metadata" != "$expected" ]; then
        backup_path_error "private recovery directory metadata is unexpected: $path"
        return 1
    fi
}

backup_nearest_device() {
    if [ "$#" -ne 1 ]; then return 2; fi
    local path="$1"
    while [ ! -e "$path" ]; do
        [ ! -L "$path" ] || return 1
        [ "$path" != / ] || return 1
        path="$(dirname -- "$path")" || return 1
    done
    [ ! -L "$path" ] || return 1
    stat -c '%d' -- "$path"
}

backup_validate_rename_filesystem() {
    if [ "$#" -ne 3 ]; then return 2; fi
    local source="$1" destination_parent="$2" recovery_parent="$3"
    local source_device destination_device recovery_device
    source_device="$(backup_nearest_device "$source")" || return 1
    destination_device="$(backup_nearest_device "$destination_parent")" || return 1
    recovery_device="$(backup_nearest_device "$recovery_parent")" || return 1
    if [ "$source_device" != "$destination_device" ] ||
       [ "$source_device" != "$recovery_device" ]; then
        backup_path_error 'prepared, destination, and recovery paths must share a filesystem for identity-checked renames'
        return 1
    fi
}
