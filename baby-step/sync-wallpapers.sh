#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

show_help() {
    cat <<'HELP'
Copy wallpapers to or from Google Drive without deleting destination-only files.

Usage:
  ~/baby-step/sync-wallpapers.sh upload   [--check-only]
  ~/baby-step/sync-wallpapers.sh download [--check-only]
  ~/baby-step/sync-wallpapers.sh status

Aliases: push = upload; pull = download.
--check-only previews a transfer with rclone --dry-run; it changes no wallpapers.
Matching filenames may be updated during a real copy. Destination-only files stay.
Uploads refuse a missing local source instead of creating an empty source.
Run rclone config once to create a Google Drive remote named gdrive.
HELP
}
command_name="${1:-help}"
case "$command_name" in
    -h|--help|help) [ "$#" -le 1 ] || exit 2; show_help; exit 0 ;;
    upload|push) command_name=upload ;;
    download|pull) command_name=download ;;
    status) ;;
    *) printf 'ERROR: Unknown command: %s\n' "$command_name" >&2; show_help >&2; exit 2 ;;
esac
[ "$#" -le 2 ] || { printf 'ERROR: Too many arguments.\n' >&2; exit 2; }
check_only=0
if [ "$#" -eq 2 ]; then
    [ "$2" = --check-only ] && [ "$command_name" != status ] || {
        printf 'ERROR: Only upload/download accept --check-only.\n' >&2; exit 2;
    }
    check_only=1
fi
WALLPAPER_DIR="${BABY_STEP_WALLPAPER_DIR:-$HOME/Pictures/Wallpapers}"
REMOTE_NAME="${BABY_STEP_WALLPAPER_REMOTE:-gdrive}"
[[ "$REMOTE_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { printf 'ERROR: Invalid rclone remote name.\n' >&2; exit 2; }
REMOTE="${REMOTE_NAME}:Wallpapers"
start_log "wallpapers-$command_name"
acquire_maintenance_lock
show_banner "Wallpapers: $command_name" 'Non-deleting copy; existing matching names may be updated'
show_step 1 3 'Checking rclone and the configured remote'
require_commands rclone grep du || fatal 'Install rclone before using wallpaper transfers'
remotes="$(rclone listremotes 2>> "$LOG_FILE")" || fatal 'Could not read rclone remote configuration'
if ! grep -Fx "$REMOTE_NAME:" <<< "$remotes" >/dev/null; then
    fatal "Remote $REMOTE_NAME is not configured. Run rclone config, create that remote, and try again."
fi
show_ok
show_detail "Local: $WALLPAPER_DIR"
show_detail "Remote: $REMOTE"
show_step 2 3 'Checking the source and selecting the operation'
if [ "$command_name" = upload ]; then
    [ -d "$WALLPAPER_DIR" ] || fatal 'Local wallpaper source is missing; nothing was transferred'
    source="$WALLPAPER_DIR"; destination="$REMOTE"
elif [ "$command_name" = download ]; then
    source="$REMOTE"; destination="$WALLPAPER_DIR"
    if [ "$check_only" -eq 0 ]; then mkdir -p -- "$WALLPAPER_DIR" || fatal 'Could not prepare the wallpaper destination'; fi
else
    if [ -d "$WALLPAPER_DIR" ]; then
        show_detail "Local usage: $(du -sh -- "$WALLPAPER_DIR" | cut -f1)"
    else
        show_detail 'Local folder is absent; status will not create it.'
    fi
fi
show_ok
if [ "$command_name" = status ]; then
    show_step 3 3 'Querying the remote collection'
    run_logged 'Google Drive wallpaper size and file count' rclone size "$REMOTE" || fatal 'Remote status query failed; connection is not verified'
    show_ok
    show_summary 'REMOTE STATUS QUERY COMPLETED' 'Transfer and content verification were not performed.'
    exit 0
fi
show_step 3 3 "$(if [ "$check_only" -eq 1 ]; then printf 'Previewing'; else printf 'Copying'; fi) wallpapers"
options=(--fast-list --transfers=4)
if [ -t 1 ]; then options+=(--progress); else options+=(--stats 5s --stats-one-line --stats-log-level NOTICE); fi
[ "$check_only" -eq 0 ] || options+=(--dry-run)
run_logged "Wallpaper $command_name" rclone copy "$source" "$destination" "${options[@]}" || fatal 'Wallpaper copy failed; some files may have transferred. See the output above.'
show_ok
if [ "$check_only" -eq 1 ]; then
    show_summary 'PREVIEW COMPLETED — NO WALLPAPERS CHANGED' 'A dry run does not prove a future real transfer will succeed.'
else
    show_summary 'WALLPAPER COPY COMPLETED' 'rclone returned success. Destination-only files were preserved; playback/visual acceptance was not tested.'
fi
