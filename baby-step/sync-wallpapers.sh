#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WALLPAPER_DIR="$HOME/Pictures/Wallpapers"
REMOTE_NAME="gdrive"
REMOTE_PATH="Wallpapers"

show_help() {
    cat << 'HELP'
SYNC WALLPAPERS WITH GOOGLE DRIVE

Usage:
  ~/baby-step/sync-wallpapers.sh upload    (or push)
  ~/baby-step/sync-wallpapers.sh download  (or pull)
  ~/baby-step/sync-wallpapers.sh status

Commands:
  upload / push     Uploads local wallpapers from ~/Pictures/Wallpapers to Google Drive
  download / pull   Downloads all wallpapers from Google Drive to ~/Pictures/Wallpapers
  status            Checks Google Drive connection and lists remote wallpaper files

First time setup:
  If you haven't linked Google Drive yet, run:
    rclone config
  and create a remote named "gdrive" of type "drive".
HELP
}

check_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        printf 'ERROR: rclone is not installed. Please rebuild your NixOS system first.\n' >&2
        exit 1
    fi
}

check_remote() {
    if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
        printf '====================================================\n'
        printf 'GOOGLE DRIVE IS NOT YET LINKED IN RCLONE\n'
        printf '====================================================\n\n'
        printf 'Please link your Google Drive once by following these steps:\n\n'
        printf '1. Run this command in your terminal:\n'
        printf '   rclone config\n\n'
        printf '2. Type: n  (New remote)\n'
        printf '3. Name: gdrive\n'
        printf '4. Storage type: drive  (or the number for Google Drive)\n'
        printf '5. Leave "client_id" and "client_secret" blank (press Enter twice)\n'
        printf '6. Scope: 1  (Full access to all files)\n'
        printf '7. Leave service account credentials blank (press Enter)\n'
        printf '8. Edit advanced config: n  (press Enter)\n'
        printf '9. Use web browser to authenticate: y  (a browser will open to log into Google)\n'
        printf '10. Confirm and save: y\n\n'
        printf 'After completing that, rerun:\n'
        printf '   ~/baby-step/sync-wallpapers.sh upload\n\n'
        exit 1
    fi
}

case "${1:-}" in
    upload|push)
        check_rclone
        check_remote
        mkdir -p "$WALLPAPER_DIR"
        printf 'Uploading wallpapers from %s to Google Drive (%s:%s)...\n' \
            "$WALLPAPER_DIR" "$REMOTE_NAME" "$REMOTE_PATH"
        rclone sync "$WALLPAPER_DIR" "${REMOTE_NAME}:${REMOTE_PATH}" \
            -P --fast-list --transfers=4
        printf '\nSUCCESS: Wallpapers uploaded to Google Drive.\n'
        ;;
    download|pull)
        check_rclone
        check_remote
        mkdir -p "$WALLPAPER_DIR"
        printf 'Downloading wallpapers from Google Drive (%s:%s) to %s...\n' \
            "$REMOTE_NAME" "$REMOTE_PATH" "$WALLPAPER_DIR"
        rclone sync "${REMOTE_NAME}:${REMOTE_PATH}" "$WALLPAPER_DIR" \
            -P --fast-list --transfers=4
        printf '\nSUCCESS: Wallpapers downloaded from Google Drive.\n'
        ;;
    status)
        check_rclone
        check_remote
        printf 'Checking Google Drive connection and wallpaper collection...\n\n'
        printf 'Local folder:  %s (%s)\n' "$WALLPAPER_DIR" "$(du -sh "$WALLPAPER_DIR" 2>/dev/null | awk '{print $1}')"
        printf 'Remote folder: %s:%s\n\n' "$REMOTE_NAME" "$REMOTE_PATH"
        rclone size "${REMOTE_NAME}:${REMOTE_PATH}" || true
        ;;
    -h|--help|help)
        show_help
        exit 0
        ;;
    "")
        show_help
        exit 0
        ;;
    *)
        printf 'ERROR: Unknown command "%s"\n\n' "$1" >&2
        show_help
        exit 2
        ;;
esac
