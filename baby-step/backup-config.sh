#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/destination-safety.sh"
. "$SCRIPT_DIR/lib/source-validation.sh"
. "$SCRIPT_DIR/lib/custom-service-manifest.sh"

check_only=0
case "${1:-}" in
    "") ;;
    --check-only) check_only=1 ;;
    -h|--help)
        printf 'Prepare and validate important NixOS and user configuration for the Git backup.\n'
        printf 'The snapshot check does not replace repository trees, commit, or push.\n'
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
SNAPSHOT_CHANGES=0
required_contract_digest=""
REPLACEMENTS_COMPLETE=0
rollback_root=""
replaced_destinations=()
replacement_had_original=()
replacement_moved_original=()
replacement_installed=()
replacement_original_identity=()
replacement_installed_identity=()
replacement_kind=()

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

backup_path_identity() {
    [ "$#" -eq 1 ] || return 2
    stat -c '%d:%i' -- "$1"
}

rollback_replacements() {
    local index destination relative rollback kind identity current_identity failed=0
    for ((index=${#replaced_destinations[@]} - 1; index >= 0; index--)); do
        destination="${replaced_destinations[$index]}"
        case "$destination" in
            "$BACKUP_REPO"/*) ;;
            *) printf 'Refusing rollback outside repository: %s\n' "$destination" >&2; failed=1; continue ;;
        esac
        relative="${destination#"$BACKUP_REPO"/}"
        rollback="$rollback_root/$relative"
        kind="${replacement_kind[$index]}"
        if ! backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" ||
           ! backup_validate_path "$rollback" "$kind" 1 ||
           ! backup_validate_private_directory "$rollback_root"; then
            failed=1
            continue
        fi
        if [ "${replacement_installed[$index]}" -eq 1 ]; then
            if [ ! -e "$destination" ]; then
                printf 'Installed snapshot path disappeared before rollback: %s\n' "$destination" >&2
                failed=1
                continue
            fi
            identity="${replacement_installed_identity[$index]}"
            current_identity="$(backup_path_identity "$destination")" || { failed=1; continue; }
            if [ "$current_identity" != "$identity" ]; then
                printf 'Installed snapshot path changed; leaving it untouched: %s\n' "$destination" >&2
                failed=1
                continue
            fi
            if ! rm -rf -- "$destination" || [ -e "$destination" ] || [ -L "$destination" ]; then
                printf 'Could not safely remove this transaction-installed path: %s\n' "$destination" >&2
                failed=1
                continue
            fi
        fi
        if [ "${replacement_had_original[$index]}" -eq 1 ]; then
            if [ "${replacement_moved_original[$index]}" -ne 1 ]; then
                if [ -e "$rollback" ] || [ -L "$rollback" ]; then
                    printf 'Original move state is uncertain; preserving both paths: %s\n' "$rollback" >&2
                    failed=1
                else
                    identity="${replacement_original_identity[$index]}"
                    current_identity="$(backup_path_identity "$destination" 2>/dev/null || true)"
                    if [ "$current_identity" != "$identity" ]; then
                        printf 'Original destination changed during a failed move; preserving it: %s\n' "$destination" >&2
                        failed=1
                    fi
                fi
                continue
            fi
            if [ ! -e "$rollback" ] || [ -e "$destination" ] || [ -L "$destination" ]; then
                printf 'Original recovery path is missing or destination is occupied: %s\n' "$rollback" >&2
                failed=1
                continue
            fi
            identity="${replacement_original_identity[$index]}"
            current_identity="$(backup_path_identity "$rollback")" || { failed=1; continue; }
            if [ "$current_identity" != "$identity" ]; then
                printf 'Recovery before-image changed; leaving it untouched: %s\n' "$rollback" >&2
                failed=1
                continue
            fi
            if ! mv -- "$rollback" "$destination"; then
                printf 'Could not restore verified before-image; it remains at %s\n' "$rollback" >&2
                failed=1
                continue
            fi
            current_identity="$(backup_path_identity "$destination")" || { failed=1; continue; }
            if [ "$current_identity" != "$identity" ]; then
                printf 'Restored before-image failed identity verification: %s\n' "$destination" >&2
                failed=1
            fi
        elif [ "${replacement_installed[$index]}" -eq 0 ] &&
             { [ -e "$destination" ] || [ -L "$destination" ]; }; then
            printf 'Unexpected path appeared at previously absent destination; preserving it: %s\n' "$destination" >&2
            failed=1
        fi
    done
    return "$failed"
}

replace_tree() {
    local prepared="$1" destination="$2" relative rollback kind=directory
    local had_original=0 original_identity='' prepared_identity current_identity index
    case "$destination" in
        "$BACKUP_REPO"/*) ;;
        *) backup_path_error "replacement escapes repository root: $destination"; return 1 ;;
    esac
    backup_validate_path "$prepared" directory 0 || return 1
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_private_directory "$rollback_root" || return 1

    relative="${destination#"$BACKUP_REPO"/}"
    rollback="$rollback_root/$relative"
    backup_validate_path "$rollback" "$kind" 1 || return 1
    backup_validate_rename_filesystem "$prepared" "$(dirname -- "$destination")" \
        "$(dirname -- "$rollback")" || return 1
    mkdir -p -- "$(dirname -- "$destination")" "$(dirname -- "$rollback")" || return 1
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_path "$rollback" "$kind" 1 || return 1
    backup_validate_rename_filesystem "$prepared" "$(dirname -- "$destination")" \
        "$(dirname -- "$rollback")" || return 1

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        had_original=1
        original_identity="$(backup_path_identity "$destination")" || return 1
    fi
    prepared_identity="$(backup_path_identity "$prepared")" || return 1
    replaced_destinations+=("$destination")
    replacement_had_original+=("$had_original")
    replacement_moved_original+=(0)
    replacement_installed+=(0)
    replacement_original_identity+=("$original_identity")
    replacement_installed_identity+=("")
    replacement_kind+=("$kind")
    index=$((${#replaced_destinations[@]} - 1))

    if [ "$had_original" -eq 1 ]; then
        if mv -- "$destination" "$rollback"; then
            replacement_moved_original[$index]=1
        else
            if [ ! -e "$destination" ] && [ ! -L "$destination" ] && [ -e "$rollback" ] &&
               [ "$(backup_path_identity "$rollback" 2>/dev/null || true)" = "$original_identity" ]; then
                replacement_moved_original[$index]=1
            fi
            return 1
        fi
    fi
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_path "$prepared" "$kind" 0 || return 1
    if mv -- "$prepared" "$destination"; then
        replacement_installed[$index]=1
        replacement_installed_identity[$index]="$prepared_identity"
        return 0
    fi
    if [ ! -e "$prepared" ] && [ ! -L "$prepared" ] && [ -e "$destination" ] &&
       [ "$(backup_path_identity "$destination" 2>/dev/null || true)" = "$prepared_identity" ]; then
        replacement_installed[$index]=1
        replacement_installed_identity[$index]="$prepared_identity"
    fi
    return 1
}

preview_file() {
    local prepared="$1"
    local destination="$2"
    local -a pipeline_status=()

    case "$prepared" in
        "$SNAPSHOT_WORK"/custom-files/*) ;;
        *) return 1 ;;
    esac
    case "$destination" in
        "$BACKUP_REPO"/dotfiles/*) ;;
        *) return 1 ;;
    esac
    local parent="$destination"
    while [ "$parent" != "$BACKUP_REPO/dotfiles" ]; do
        parent="$(dirname -- "$parent")"
        case "$parent" in
            "$BACKUP_REPO"/dotfiles|"$BACKUP_REPO"/dotfiles/*) ;;
            *) return 1 ;;
        esac
        [ ! -L "$parent" ] || return 1
    done
    [ -f "$prepared" ] && [ ! -L "$prepared" ] || return 1
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        printf 'Refusing non-regular custom backup destination: %s\n' "$destination" >&2
        return 1
    fi

    printf '\nPlanned snapshot change for %s:\n' "$destination"
    if [ ! -e "$destination" ]; then
        printf 'Only in pending snapshot: %s\n' "${destination#"$BACKUP_REPO"/}" |
            tee -a "$LOG_FILE"
        SNAPSHOT_CHANGES=1
        return 0
    fi
    if cmp -s -- "$destination" "$prepared"; then
        printf 'No changes.\n'
        return 0
    fi
    diff -u -- "$destination" "$prepared" 2>&1 | tee -a "$LOG_FILE"
    pipeline_status=("${PIPESTATUS[@]}")
    if [ "${pipeline_status[0]}" -eq 1 ]; then
        SNAPSHOT_CHANGES=1
    fi
    [ "${pipeline_status[0]}" -le 1 ] && [ "${pipeline_status[1]}" -eq 0 ]
}

replace_file() {
    local prepared="$1" destination="$2" relative rollback
    local kind=file had_original=0 original_identity='' prepared_identity current_identity index
    case "$prepared" in
        "$SNAPSHOT_WORK"/custom-files/*) ;;
        *) return 1 ;;
    esac
    backup_validate_path "$prepared" file 0 || return 1
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_private_directory "$rollback_root" || return 1
    relative="${destination#"$BACKUP_REPO"/}"
    rollback="$rollback_root/$relative"
    backup_validate_path "$rollback" "$kind" 1 || return 1
    backup_validate_rename_filesystem "$prepared" "$(dirname -- "$destination")" \
        "$(dirname -- "$rollback")" || return 1
    mkdir -p -- "$(dirname -- "$destination")" "$(dirname -- "$rollback")" || return 1
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_path "$rollback" "$kind" 1 || return 1
    backup_validate_rename_filesystem "$prepared" "$(dirname -- "$destination")" \
        "$(dirname -- "$rollback")" || return 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        had_original=1
        original_identity="$(backup_path_identity "$destination")" || return 1
    fi
    prepared_identity="$(backup_path_identity "$prepared")" || return 1
    replaced_destinations+=("$destination")
    replacement_had_original+=("$had_original")
    replacement_moved_original+=(0)
    replacement_installed+=(0)
    replacement_original_identity+=("$original_identity")
    replacement_installed_identity+=("")
    replacement_kind+=("$kind")
    index=$((${#replaced_destinations[@]} - 1))
    if [ "$had_original" -eq 1 ]; then
        if mv -- "$destination" "$rollback"; then
            replacement_moved_original[$index]=1
        else
            if [ ! -e "$destination" ] && [ ! -L "$destination" ] && [ -e "$rollback" ] &&
               [ "$(backup_path_identity "$rollback" 2>/dev/null || true)" = "$original_identity" ]; then
                replacement_moved_original[$index]=1
            fi
            return 1
        fi
    fi
    backup_validate_destination "$BACKUP_REPO" "$destination" "$kind" || return 1
    backup_validate_path "$prepared" "$kind" 0 || return 1
    if mv -- "$prepared" "$destination"; then
        replacement_installed[$index]=1
        replacement_installed_identity[$index]="$prepared_identity"
        return 0
    fi
    if [ ! -e "$prepared" ] && [ ! -L "$prepared" ] && [ -e "$destination" ] &&
       [ "$(backup_path_identity "$destination" 2>/dev/null || true)" = "$prepared_identity" ]; then
        replacement_installed[$index]=1
        replacement_installed_identity[$index]="$prepared_identity"
    fi
    return 1
}

preview_tree() {
    local prepared="$1"
    local destination="$2"
    local -a pipeline_status=()

    printf '\nPlanned snapshot change for %s:\n' "$destination"
    if [ -d "$destination" ]; then
        diff -qr -- "$destination" "$prepared" 2>&1 | tee -a "$LOG_FILE"
        pipeline_status=("${PIPESTATUS[@]}")
        if [ "${pipeline_status[0]}" -eq 1 ]; then
            SNAPSHOT_CHANGES=1
        fi
        [ "${pipeline_status[0]}" -le 1 ] && [ "${pipeline_status[1]}" -eq 0 ]
    else
        find "$prepared" -type f -printf 'Only in pending snapshot: %P\n' | tee -a "$LOG_FILE"
        pipeline_status=("${PIPESTATUS[@]}")
        if [ "${pipeline_status[0]}" -eq 0 ] &&
           [ -n "$(find "$prepared" -type f -print -quit)" ]; then
            SNAPSHOT_CHANGES=1
        fi
        [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ]
    fi
}

printf 'Preparing a focused configuration backup.\n\n'

show_step 1 "$TOTAL" "Checking sources and Git repository"
if require_commands chmod cmp cp diff find flock git grep jq mkdir mktemp mv nix rm sha256sum stat timeout mango niri noctalia Hyprland sort xargs rmdir &&
   [ -d "$BACKUP_REPO/.git" ] &&
   [ -f "$BABY_STEP_DIR/custom-service-manifest.tsv" ] &&
   [ ! -L "$BABY_STEP_DIR/custom-service-manifest.tsv" ] &&
   [ -r "$BABY_STEP_DIR/custom-service-manifest.tsv" ] &&
   detect_flake_target; then
    if backup_validate_path "$BABY_STEP_DIR" directory 0 &&
       backup_validate_path "$BACKUP_DIR" directory 0 &&
       backup_validate_path "$BACKUP_DIR/hardware-configuration.previous.nix" file 1 &&
       backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/nixos" directory &&
       backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.config" directory &&
       backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.local/bin" directory &&
       backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/baby-step" directory &&
       backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.hermes/agy_bridge.py" file; then
        show_ok
    else
        show_failed
        fatal "A backup or recovery destination is unsafe; repository targets were not changed"
    fi
else
    show_failed
    fatal "Configuration source or Git backup repository is unavailable"
fi

show_step 2 "$TOTAL" "Validating desktop configuration"
if timeout 15 mango -c "$HOME/.config/mango/config.conf" -p \
       >> "$LOG_FILE" 2>&1 &&
   timeout 15 niri validate >> "$LOG_FILE" 2>&1 &&
   timeout 15 noctalia config validate >> "$LOG_FILE" 2>&1 &&
   [ -f "$NIXOS_DIR/desktop/hyprland/hyprland.lua" ] &&
   [ ! -L "$NIXOS_DIR/desktop/hyprland/hyprland.lua" ] &&
   timeout 15 Hyprland --verify-config --config "$NIXOS_DIR/desktop/hyprland/hyprland.lua" \
       >> "$LOG_FILE" 2>&1 &&
   ([ ! -f "$HOME/.config/sway/config" ] || ! command -v sway >/dev/null 2>&1 || \
    WLR_BACKENDS=headless timeout 15 sway -C -c "$HOME/.config/sway/config" >> "$LOG_FILE" 2>&1); then
    show_ok
else
    show_failed
    fatal "A desktop configuration is invalid; backup stopped before changing the repository"
fi

SNAPSHOT_WORK="$(mktemp -d "$STATE_DIR/snapshot.XXXXXX")"
mkdir -p "$SNAPSHOT_WORK/nixos"

show_step 3 "$TOTAL" "Preparing the NixOS configuration snapshot"
manifest_path="$SNAPSHOT_WORK/nixos-source-manifest.nul"
if ! nixos_source_manifest "$NIXOS_DIR" > "$manifest_path"; then
    show_failed
    fatal "Could not enumerate the NixOS source tree; the repository is unchanged"
fi
while IFS= read -r -d '' relative; do
    source_path="$NIXOS_DIR/$relative"
    if [ ! -f "$source_path" ] || [ -L "$source_path" ] || [ ! -r "$source_path" ]; then
        show_failed
        fatal "A manifest source disappeared or became unreadable: $relative"
    fi
    mkdir -p "$SNAPSHOT_WORK/nixos/$(dirname -- "$relative")"
    cp -a --no-preserve=ownership "$source_path" "$SNAPSHOT_WORK/nixos/$relative"
done < "$manifest_path"

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

required_contract_digest="$(source_contract_digest "$BABY_STEP_DIR/required-build-inputs.json")" ||
    fatal "The required NixOS resource contract could not be fingerprinted"
snapshot_toplevel="$(verify_nixos_snapshot "$NIXOS_DIR" \
    "$SNAPSHOT_WORK/nixos" "$FLAKE_ATTR" \
    "$BABY_STEP_DIR/required-build-inputs.json" \
    "$SCRIPT_DIR/lib/source-manifest.sh" 2>> "$LOG_FILE")" || {
    show_failed
    fatal "The prepared NixOS snapshot failed resource, evaluation, parity, or build validation; the repository is unchanged"
}
printf 'Prepared NixOS snapshot evaluated and built: %s\n' "$snapshot_toplevel" >> "$LOG_FILE"

if [ "$check_only" -eq 1 ]; then
    printf '\nSUCCESS: Source coverage, evaluation, and offline build passed.\n'
    printf 'No repository tree, receipt, or persistent hardware backup was replaced.\n'
    printf 'A temporary snapshot and Nix store/cache artifacts were created.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

show_step 4 "$TOTAL" "Preparing selected user configuration"
mkdir -p "$SNAPSHOT_WORK/dotconfig"
for config_name in \
    mango noctalia kitty fcitx5 nvim fastfetch niri sway hypr xfce4 theme-profiles \
    plasma-workspace systemd; do
    source_dir="$HOME/.config/$config_name"
    [ -d "$source_dir" ] || continue
    mkdir -p "$SNAPSHOT_WORK/dotconfig/$config_name"
    cp -a "$source_dir/." "$SNAPSHOT_WORK/dotconfig/$config_name/"
    find "$SNAPSHOT_WORK/dotconfig/$config_name" -type f \
        \( -name '*.bak' -o -name '*.bak-*' -o -name '*.before-*' \
           -o -name '*.backup' -o -name '*.old' -o -name '*.giant-backup-*' \) -delete
done
# The guarded session runs the declarative Lua, not the old personal copy.
# Restore backups must carry that same verified source; leave the live personal
# file untouched. Remove a prepared leaf symlink before copying, never follow it.
mkdir -p "$SNAPSHOT_WORK/dotconfig/hypr"
cp -a --no-preserve=ownership --remove-destination -- \
    "$SNAPSHOT_WORK/nixos/desktop/hyprland/hyprland.lua" \
    "$SNAPSHOT_WORK/dotconfig/hypr/hyprland.lua"
# Only the private prepared copy is pruned. Do not follow links to live state.
# Keep settings, palettes, template source, and plugin configuration; omit
# clipboard data and generated catalog/setup/cache metadata from publication.
for prepared_config in "$SNAPSHOT_WORK/dotconfig/noctalia" \
    "$SNAPSHOT_WORK/dotconfig/theme-profiles"; do
    [ -d "$prepared_config" ] && [ ! -L "$prepared_config" ] || continue
    find -P "$prepared_config" -depth \
        \( -name clipboard -o -name .catalog -o -name .setup-complete \
           -o -name .noctalia-cache.json \) -exec rm -rf -- {} +
done
rm -f -- "$SNAPSHOT_WORK/dotconfig/fcitx5/conf/cached_layouts"
for config_file in \
    mimeapps.list kdeglobals kwinrc kwinrulesrc kglobalshortcutsrc kcminputrc \
    kscreenlockerrc powerdevilrc plasma-org.kde.plasma.desktop-appletsrc user-dirs.dirs; do
    if [ -f "$HOME/.config/$config_file" ]; then
        cp -a "$HOME/.config/$config_file" "$SNAPSHOT_WORK/dotconfig/$config_file"
    fi
done

# Export only non-secret, explicitly selected GNOME appearance and shortcut
# settings. Do not copy the binary dconf database or custom command strings.
gnome_settings=(
    "org.gnome.desktop.interface|color-scheme"
    "org.gnome.desktop.interface|gtk-theme"
    "org.gnome.desktop.interface|icon-theme"
    "org.gnome.desktop.interface|cursor-theme"
    "org.gnome.desktop.interface|cursor-size"
    "org.gnome.desktop.interface|font-name"
    "org.gnome.desktop.interface|monospace-font-name"
    "org.gnome.desktop.background|picture-uri"
    "org.gnome.desktop.background|picture-uri-dark"
    "org.gnome.desktop.wm.preferences|num-workspaces"
    "org.gnome.desktop.wm.preferences|button-layout"
    "org.gnome.desktop.wm.keybindings|close"
    "org.gnome.desktop.wm.keybindings|toggle-fullscreen"
    "org.gnome.desktop.wm.keybindings|toggle-maximized"
    "org.gnome.desktop.wm.keybindings|switch-to-workspace-left"
    "org.gnome.desktop.wm.keybindings|switch-to-workspace-right"
    "org.gnome.desktop.wm.keybindings|move-to-workspace-left"
    "org.gnome.desktop.wm.keybindings|move-to-workspace-right"
    "org.gnome.settings-daemon.plugins.media-keys|screensaver"
    "org.gnome.shell.keybindings|toggle-overview"
)
for number in {1..9}; do
    gnome_settings+=("org.gnome.desktop.wm.keybindings|switch-to-workspace-$number")
    gnome_settings+=("org.gnome.desktop.wm.keybindings|move-to-workspace-$number")
    gnome_settings+=("org.gnome.shell.keybindings|switch-to-application-$number")
done
gnome_state="$SNAPSHOT_WORK/dotconfig/gnome-selected-gsettings.tsv"
: > "$gnome_state"
if command -v gsettings >/dev/null 2>&1; then
    for setting in "${gnome_settings[@]}"; do
        schema="${setting%%|*}"
        key="${setting#*|}"
        if value="$(gsettings get "$schema" "$key" 2>> "$LOG_FILE")"; then
            printf '%s\t%s\t%s\n' "$schema" "$key" "$value" >> "$gnome_state"
        else
            printf 'GNOME setting unavailable for snapshot: %s %s\n' "$schema" "$key" >> "$LOG_FILE"
        fi
    done
else
    rm -f -- "$gnome_state"
    printf 'gsettings is unavailable; no GNOME preference text was added.\n' >> "$LOG_FILE"
fi
show_ok

show_step 5 "$TOTAL" "Preparing helpers and baby-step tools"
mkdir -p "$SNAPSHOT_WORK/local-bin"
for helper_name in \
    apply-theme-profile clean-stray-sessions niri-session-guarded \
    mango-session-guarded sway-session-guarded plasma-session-guarded \
    save-noctalia-profile save-theme-profile sync-active-theme \
    noctalia-greeter-sync-smart mango-animation steam obs obs-safe \
    obs-fix-recording-paths hypr-active-window-screenshot \
    hypr-noctalia-notification-owner hypr-session-ready slogout; do
    if [ -f "$HOME/.local/bin/$helper_name" ]; then
        cp -a "$HOME/.local/bin/$helper_name" "$SNAPSHOT_WORK/local-bin/$helper_name"
    fi
done

if ! prepare_custom_service_sources "$BABY_STEP_DIR/custom-service-manifest.tsv" \
    "$HOME" "$SNAPSHOT_WORK/dotconfig" "$SNAPSHOT_WORK/local-bin" \
    "$SNAPSHOT_WORK/custom-files"; then
    show_failed
    fatal "Custom-service source coverage failed; the repository is unchanged"
fi

mkdir -p "$SNAPSHOT_WORK/baby-step/lib"
for baby_file in \
    README.txt system-summary.txt system-summary-for-ai.md \
    check-system.sh rebuild-system.sh update-system.sh \
    backup-config.sh update-and-push.sh sync-wallpapers.sh \
    custom-service-manifest.tsv required-build-inputs.json \
    tests/backup-destination-safety-test.sh \
    tests/clean-stray-sessions-test.sh tests/update-receipt-test.sh \
    tests/backup-source-coverage-test.sh tests/backup-production-integration-test.sh \
    tests/custom-service-restore-test.sh tests/publication-safety-test.py; do
    if [ -f "$BABY_STEP_DIR/$baby_file" ]; then
        mkdir -p "$SNAPSHOT_WORK/baby-step/$(dirname -- "$baby_file")"
        cp -a "$BABY_STEP_DIR/$baby_file" "$SNAPSHOT_WORK/baby-step/$baby_file"
    fi
done
cp -a "$BABY_STEP_DIR/lib/common.sh" "$SNAPSHOT_WORK/baby-step/lib/common.sh"
cp -a "$BABY_STEP_DIR/lib/source-manifest.sh" "$SNAPSHOT_WORK/baby-step/lib/source-manifest.sh"
cp -a "$BABY_STEP_DIR/lib/source-validation.sh" "$SNAPSHOT_WORK/baby-step/lib/source-validation.sh"
cp -a "$BABY_STEP_DIR/lib/destination-safety.sh" "$SNAPSHOT_WORK/baby-step/lib/destination-safety.sh"
cp -a "$BABY_STEP_DIR/lib/custom-service-manifest.sh" \
    "$SNAPSHOT_WORK/baby-step/lib/custom-service-manifest.sh"
cp -a "$BABY_STEP_DIR/lib/publication-check.py" \
    "$SNAPSHOT_WORK/baby-step/lib/publication-check.py"
show_ok

show_step 6 "$TOTAL" "Updating the recoverable repository snapshot"
for snapshot_pair in \
    "$SNAPSHOT_WORK/nixos:$BACKUP_REPO/nixos" \
    "$SNAPSHOT_WORK/dotconfig:$BACKUP_REPO/dotfiles/.config" \
    "$SNAPSHOT_WORK/local-bin:$BACKUP_REPO/dotfiles/.local/bin" \
    "$SNAPSHOT_WORK/baby-step:$BACKUP_REPO/baby-step"; do
    prepared="${snapshot_pair%%:*}"
    destination="${snapshot_pair#*:}"
    if ! preview_tree "$prepared" "$destination"; then
        show_failed
        fatal "Could not preview the configuration snapshot; the repository is unchanged"
    fi
done

if ! preview_file "$SNAPSHOT_WORK/custom-files/.hermes/agy_bridge.py" \
    "$BACKUP_REPO/dotfiles/.hermes/agy_bridge.py"; then
    show_failed
    fatal "Could not preview the custom Hermes helper; the repository is unchanged"
fi

if [ "$SNAPSHOT_CHANGES" -eq 0 ]; then
    show_ok
    record_success snapshot "Snapshot already matches sources in $BACKUP_REPO"
    write_maintenance_state "Configuration snapshot" "Already current; no repository files replaced" \
        "Source validation and snapshot comparison" "Only logs and maintenance state" \
        "Git commit and push have not yet run"
    printf '\nSUCCESS: The repository snapshot already matches the selected sources.\n'
    printf 'No repository files were replaced, committed, or pushed.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

printf '\nReview the additions, modifications, and removals above.\n'
printf 'Type SNAPSHOT to replace these repository folders, or press Enter to stop: '
read -r replacement_confirmation
if [ "$replacement_confirmation" != "SNAPSHOT" ]; then
    fatal "Snapshot replacement was not confirmed. The repository is unchanged."
fi

contract_digest_after="$(source_contract_digest "$BABY_STEP_DIR/required-build-inputs.json")" ||
    fatal "The NixOS resource contract changed or became unreadable after build"
if [ "$contract_digest_after" != "$required_contract_digest" ]; then
    fatal "The NixOS resource contract changed after build; repository destinations were not replaced"
fi
if ! backup_validate_path "$BABY_STEP_DIR" directory 0 ||
   ! backup_validate_path "$BACKUP_DIR" directory 0 ||
   ! backup_validate_path "$BACKUP_DIR/hardware-configuration.previous.nix" file 1 ||
   ! backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/nixos" directory ||
   ! backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.config" directory ||
   ! backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.local/bin" directory ||
   ! backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/baby-step" directory ||
   ! backup_validate_destination "$BACKUP_REPO" "$BACKUP_REPO/dotfiles/.hermes/agy_bridge.py" file; then
    fatal "A backup or recovery destination changed after preview; no destination was replaced"
fi
rollback_root="$(mktemp -d "$BACKUP_DIR/repository-previous.XXXXXX")" ||
    fatal "Could not create a private repository recovery directory"
if ! backup_validate_private_directory "$rollback_root" ||
   [ -n "$(find "$rollback_root" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    fatal "The repository recovery directory is not a new private empty directory"
fi

if [ -f "$NIXOS_DIR/hardware-configuration.nix" ]; then
    cp -a "$NIXOS_DIR/hardware-configuration.nix" \
        "$BACKUP_DIR/hardware-configuration.previous.nix"
fi

printf '\nPrevious repository files will be preserved under:\n  %s\n' "$rollback_root"
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
if ! replace_file "$SNAPSHOT_WORK/custom-files/.hermes/agy_bridge.py" \
    "$BACKUP_REPO/dotfiles/.hermes/agy_bridge.py"; then
    show_failed
    fatal "Could not replace the custom Hermes helper"
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
