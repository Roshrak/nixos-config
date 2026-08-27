#!/usr/bin/env bash
# make-backup.sh — Phase 1 rollback point creator for the multi-DE project.
# Usage: make-backup.sh [label]
set -euo pipefail

LABEL="${1:-$(date +%Y%m%d-%H%M)}"
DEST="$HOME/rice plan/multi-de/backups"
STAMP="$(date '+%Y-%m-%d %H:%M')"
OUT="$DEST/backup-$LABEL.tar.gz"

mkdir -p "$DEST"

TAR_EXCLUDES=(
    --exclude="$HOME/.local/share/Steam"
    --exclude="$HOME/.local/share/PrismLauncher"
    --exclude="$DEST"
    --exclude="*/Cache"
    --exclude="*/Code Cache"
    --exclude="*/GPUCache"
)

echo "Creating $OUT ..."
tar -czf "$OUT" \
    "${TAR_EXCLUDES[@]}" \
    -C "$HOME" \
    .config \
    .local/share \
    .local/bin \
    -C / etc/nixos

printf 'label: %s\ncreated: %s\nfile: %s\nsize: %s\n' \
    "$LABEL" "$STAMP" "$OUT" "$(du -h "$OUT" | cut -f1)" \
    >> "$DEST/BACKUPS.log"

echo "OK. Recorded in $DEST/BACKUPS.log"
ls -lh "$DEST"
