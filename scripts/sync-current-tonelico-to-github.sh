#!/usr/bin/env bash
# Deprecated compatibility command. Snapshot only; never updates flake inputs.
set -euo pipefail
case "$#:${1:-}" in
    0:) set -- --backup-only ;;
    1:--check-only) set -- --check-only ;;
    1:--help|1:-h) set -- --help ;;
    *) printf 'Usage: %s [--check-only|--help]\n' "${0##*/}" >&2; exit 64 ;;
esac
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="$HOME/baby-step/update-and-push.sh"
if [ ! -x "$target" ] || [ -L "$target" ]; then
    target="$script_dir/../baby-step/update-and-push.sh"
fi
if [ ! -f "$target" ] || [ ! -x "$target" ] || [ -L "$target" ]; then
    printf 'ERROR: Maintained baby-step/update-and-push.sh is unavailable; nothing changed.\n' >&2
    exit 1
fi
printf 'Deprecated publisher: delegating to the maintained snapshot-only flow.\n' >&2
exec "$target" "$@"
