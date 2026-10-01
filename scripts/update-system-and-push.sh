#!/usr/bin/env bash
# Compatibility entry point; maintained implementation lives in baby-step.
set -euo pipefail
if [ "${1:-}" = --sync-only ]; then
    shift
    set -- --backup-only "$@"
fi
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="$HOME/baby-step/update-and-push.sh"
if [ ! -x "$target" ]; then
    target="$script_dir/../baby-step/update-and-push.sh"
fi
if [ ! -x "$target" ]; then
    printf 'ERROR: Install the maintained baby-step/update-and-push.sh first.\n' >&2
    exit 1
fi
exec "$target" "$@"
