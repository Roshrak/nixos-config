#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

check_only=0
case "${1:-}" in
    "") ;;
    --check-only) check_only=1 ;;
    -h|--help)
        printf 'Copy important NixOS and user configuration into the Git backup.\n'
        printf 'This does not commit or push.\n'
        printf 'Run: %s\n' "$HOME/baby-step/backup-config.sh"
        exit 0
        ;;
    *)
        printf 'ERROR: Unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac

start_log "backup"
acquire_maintenance_lock
TOTAL=6
SNAPSHOT_WORK=""
REPLACEMENTS_COMPLETE=0
rollback_root=""
replaced_destinations=()
replacement_had_original=()

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e
    if [ "$status" -ne 0 ] && [ "$REPLACEMENTS_COMPLETE" -eq 0 ] &&
       [ "${#replaced_destinations[@]}" -gt 0 ]; then
        rollback_replacements ||
            printf 'WARNING: Automatic repository rollback was incomplete.\n' >> "$LOG_FILE"
    fi
    if [ -n "$SNAPSHOT_WORK" ]; then
        case "$SNAPSHOT_WORK" in
            "$STATE_DIR"/snapshot.*) rm -rf -- "$SNAPSHOT_WORK" ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "Interrupted before completion.\n" >> "$LOG_FILE"; exit 130' INT TERM HUP

rollback_replacements() {
    local index
    local destination
    local relative
    local rollback
    local failed=0

    for ((index=${#replaced_destinations[@]} - 1; index >= 0; index--)); do
        destination="${replaced_destinations[$index]}"
        case "$destination" in
            "$BACKUP_REPO"/*) ;;
            *) failed=1; continue ;;
        esac
        relative="${destination#"$BACKUP_REPO"/}"
        rollback="$rollback_root/$relative"
        if [ "${replacement_had_original[$index]}" -eq 1 ] && [ -e "$rollback" ]; then
            rm -rf -- "$destination" || failed=1
            mkdir -p "$(dirname -- "$destination")" || failed=1
            mv "$rollback" "$destination" || failed=1
        elif [ "${replacement_had_original[$index]}" -eq 0 ]; then
            rm -rf -- "$destination" || failed=1
        fi
    done
    return "$failed"
}

replace_tree() {
    local prepared="$1"
    local destination="$2"
    local relative
    local rollback
    local had_original=0

    case "$destination" in
        "$BACKUP_REPO"/*) ;;
        *) return 1 ;;
    esac
    [ -d "$prepared" ] || return 1

    relative="${destination#"$BACKUP_REPO"/}"
    rollback="$rollback_root/$relative"
    mkdir -p "$(dirname -- "$destination")" "$(dirname -- "$rollback")"

    if [ -e "$destination" ]; then
        had_original=1
    fi
    replaced_destinations+=("$destination")
    replacement_had_original+=("$had_original")
    if [ "$had_original" -eq 1 ]; then
        mv "$destination" "$rollback" || return 1
    fi
    if mv "$prepared" "$destination"; then
        return 0
    fi
    return 1
}

printf 'Preparing a focused configuration backup.\n\n'

show_step 1 "$TOTAL" "Checking sources and Git repository"
if require_commands cp find git mktemp mv nix jq timeout mango niri noctalia &&
   [ -d "$BACKUP_REPO/.git" ] &&
   detect_flake_target; then
    show_ok
else
    show_failed
    fatal "Configuration source or Git backup repository is unavailable"
fi

show_step 2 "$TOTAL" "Validating desktop configuration"
if timeout 15 mango -c "$HOME/.config/mango/config.conf" -p \
       >> "$LOG_FILE" 2>&1 &&
   timeout 15 niri validate >> "$LOG_FILE" 2>&1 &&
   timeout 15 noctalia config validate >> "$LOG_FILE" 2>&1 &&
   ([ ! -f "$HOME/.config/sway/config" ] || ! command -v sway >/dev/null 2>&1 || \
    timeout 15 sway -C -c "$HOME/.config/sway/config" >> "$LOG_FILE" 2>&1); then
    show_ok
else
    show_failed
    fatal "A desktop configuration is invalid; backup stopped before changing the repository"
fi

if [ "$check_only" -eq 1 ]; then
    printf '\nSUCCESS: Backup safety checks passed. Nothing was copied.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

rollback_root="$BACKUP_DIR/repository-previous"
rm -rf -- "$rollback_root"
SNAPSHOT_WORK="$(mktemp -d "$STATE_DIR/snapshot.XXXXXX")"
mkdir -p "$rollback_root" "$SNAPSHOT_WORK/nixos"

show_step 3 "$TOTAL" "Preparing the NixOS configuration snapshot"
while IFS= read -r -d '' source_path; do
    relative="${source_path#"$NIXOS_DIR"/}"
    case "$relative" in
        .git/*|backup-*/*|result|result-*|*.bak|*.bak-*|*.before-*|*.backup.*)
            continue
            ;;
        hardware-configuration.nix)
            cp -a "$source_path" "$BACKUP_DIR/hardware-configuration.previous.nix"
            continue
            ;;
        *.nix|flake.lock|.gitignore|*.md|fonts/*.ttf|fonts/*/*.ttf) ;;
        *) continue ;;
    esac
    mkdir -p "$SNAPSHOT_WORK/nixos/$(dirname -- "$relative")"
    cp -a --no-preserve=ownership "$source_path" "$SNAPSHOT_WORK/nixos/$relative"
done < <(
    find "$NIXOS_DIR" -maxdepth 4 -type f -print0
)

if [ -f "$SNAPSHOT_WORK/nixos/flake.nix" ] &&
   [ -f "$SNAPSHOT_WORK/nixos/configuration.nix" ] &&
   [ -f "$SNAPSHOT_WORK/nixos/flake.lock" ] &&
   [ -f "$SNAPSHOT_WORK/nixos/hosts/$FLAKE_ATTR/host.nix" ] &&
   [ -f "$SNAPSHOT_WORK/nixos/hosts/$FLAKE_ATTR/hardware-configuration.nix" ]; then
    show_ok
else
    show_failed
    fatal "The prepared NixOS snapshot is incomplete"
fi

show_step 4 "$TOTAL" "Preparing selected user configuration"
mkdir -p "$SNAPSHOT_WORK/dotconfig"
for config_name in \
    mango noctalia kitty fcitx5 nvim fastfetch niri sway theme-profiles \
    plasma-workspace systemd; do
    source_dir="$HOME/.config/$config_name"
    [ -d "$source_dir" ] || continue
    mkdir -p "$SNAPSHOT_WORK/dotconfig/$config_name"
    cp -a "$source_dir/." "$SNAPSHOT_WORK/dotconfig/$config_name/"
    find "$SNAPSHOT_WORK/dotconfig/$config_name" -type f \
        \( -name '*.bak' -o -name '*.bak-*' -o -name '*.before-*' \
           -o -name '*.backup' -o -name '*.old' \) -delete
done
for config_file in mimeapps.list kwinrc user-dirs.dirs; do
    if [ -f "$HOME/.config/$config_file" ]; then
        cp -a "$HOME/.config/$config_file" "$SNAPSHOT_WORK/dotconfig/$config_file"
    fi
done
show_ok

show_step 5 "$TOTAL" "Preparing helpers and baby-step tools"
mkdir -p "$SNAPSHOT_WORK/local-bin"
for helper_name in \
    apply-theme-profile clean-stray-sessions niri-session-guarded \
    mango-session-guarded sway-session-guarded save-noctalia-profile \
    noctalia-greeter-sync-smart mango-animation steam obs obs-safe \
    obs-fix-recording-paths slogout; do
    if [ -f "$HOME/.local/bin/$helper_name" ]; then
        cp -a "$HOME/.local/bin/$helper_name" "$SNAPSHOT_WORK/local-bin/$helper_name"
    fi
done

mkdir -p "$SNAPSHOT_WORK/baby-step/lib"
for baby_file in \
    README.txt system-summary.txt system-summary-for-ai.md \
    check-system.sh rebuild-system.sh update-system.sh \
    backup-config.sh update-and-push.sh; do
    if [ -f "$BABY_STEP_DIR/$baby_file" ]; then
        cp -a "$BABY_STEP_DIR/$baby_file" "$SNAPSHOT_WORK/baby-step/$baby_file"
    fi
done
cp -a "$BABY_STEP_DIR/lib/common.sh" "$SNAPSHOT_WORK/baby-step/lib/common.sh"
show_ok

show_step 6 "$TOTAL" "Updating the recoverable repository snapshot"
if ! replace_tree "$SNAPSHOT_WORK/nixos" "$BACKUP_REPO/nixos"; then
    show_failed
    fatal "Could not replace the repository NixOS snapshot"
fi
if ! replace_tree "$SNAPSHOT_WORK/dotconfig" "$BACKUP_REPO/dotfiles/.config"; then
    show_failed
    fatal "Could not replace the repository user configuration snapshot"
fi
if ! replace_tree "$SNAPSHOT_WORK/local-bin" "$BACKUP_REPO/dotfiles/.local/bin"; then
    show_failed
    fatal "Could not replace the repository helper snapshot"
fi
if ! replace_tree "$SNAPSHOT_WORK/baby-step" "$BACKUP_REPO/baby-step"; then
    show_failed
    fatal "Could not replace the repository baby-step snapshot"
fi
REPLACEMENTS_COMPLETE=1

show_ok
record_success snapshot "Snapshot prepared in $BACKUP_REPO (not committed or pushed)"
write_maintenance_state "Configuration snapshot" "Snapshot copied; not committed or pushed" \
    "Source validation and recoverable snapshot replacement" \
    "$BACKUP_REPO and local hardware backup" \
    "Git commit and push have not yet run"

printf '\nSUCCESS: Important configuration was copied to the Git backup.\n'
printf 'Nothing was committed or pushed.\n'
printf 'Previous repository copies are recoverable from: %s\n' "$rollback_root"
printf 'Detailed log: %s\n' "$LOG_FILE"
