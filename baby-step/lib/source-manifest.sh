#!/usr/bin/env bash

# Emit the selected, nonsecret inputs in a NixOS flake tree as NUL-separated
# relative paths. The same list drives snapshots and update receipts.
nixos_source_manifest() (
    set -euo pipefail

    if [ "$#" -ne 1 ] || [ ! -d "$1" ] || [ -L "$1" ]; then
        printf 'NixOS source root is missing or not a directory.\n' >&2
        exit 1
    fi

    local source_root work_dir directories files symlinks path relative mode_text mode
    source_root="$(cd -P -- "$1" && pwd)" || exit 1
    [ -f "$source_root/flake.nix" ] || {
        printf 'NixOS source root has no flake.nix: %s\n' "$source_root" >&2
        exit 1
    }

    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixos-source-manifest.XXXXXXXX")" || exit 1
    chmod 700 "$work_dir"
    directories="$work_dir/directories.nul"
    files="$work_dir/files.nul"
    symlinks="$work_dir/symlinks.nul"
    trap 'rm -f -- "$directories" "$files" "$symlinks"; rmdir -- "$work_dir"' EXIT

    find "$source_root" \( -name .git -o -name 'backup-*' \) -prune -o \
        -type d -print0 | sort -z > "$directories"
    while IFS= read -r -d '' path; do
        mode_text="$(stat -c '%a' -- "$path")"
        mode=$((8#$mode_text))
        if (( (mode & 0444) == 0 || (mode & 0111) == 0 )); then
            printf 'Unreadable or untraversable source directory: %s\n' "$path" >&2
            exit 1
        fi
    done < "$directories"

    find "$source_root" \( -name .git -o -name 'backup-*' \) -prune -o \
        -type l -print0 | sort -z > "$symlinks"
    while IFS= read -r -d '' path; do
        relative="${path#"$source_root"/}"
        # Nix's local flake result link is a generated convenience pointer,
        # never a source input. Every other symlink fails closed, including
        # links that point outside the tree or form a loop.
        if [ "$relative" != result ]; then
            printf 'Symlink in NixOS source tree is not allowed: %s\n' "$relative" >&2
            exit 1
        fi
    done < "$symlinks"

    find "$source_root" \( -name .git -o -name 'backup-*' \) -prune -o \
        -type f -print0 | sort -z > "$files"
    while IFS= read -r -d '' path; do
        relative="${path#"$source_root"/}"
        case "$relative" in
            result|result-*|*.bak|*.bak-*|*.before-*|*.backup.*|*.lock.before-*)
                continue
                ;;
            hardware-configuration.nix)
                # The obsolete top-level generated file is separately
                # retained by backup-config.sh; the flake imports the host
                # copy under hosts/<name>/.
                continue
                ;;
        esac

        case "$relative" in
            *.nix|flake.lock|.gitignore|*.md|*.lua|*.js|*.json|*.xml|*.ttf|*.otf|\
            *.css|*.svg|*.patch|*.diff|*.sh|*.service|*.target|*.conf|*.kdl|\
            *.yaml|*.yml|*.toml|*.desktop|*.rules)
                ;;
            *) continue ;;
        esac

        case "/$relative/" in
            */.env/*|*/.env.*/*|*/secrets/*|*/secret/*|*/credentials/*|\
            */private/*|*/private-keys/*|*/auth/*|*/tokens/*|*/.ssh/*)
                continue
                ;;
        esac
        case "${relative##*/}" in
            .env|.env.*|*.pem|*.key|*secret*|*credential*|*token*|*password*|*private-key*)
                continue
                ;;
        esac

        mode_text="$(stat -c '%a' -- "$path")"
        mode=$((8#$mode_text))
        if [ ! -r "$path" ] || (( (mode & 0444) == 0 )); then
            printf 'Unreadable NixOS source file: %s\n' "$relative" >&2
            exit 1
        fi
        printf '%s\0' "$relative"
    done < "$files"
)
