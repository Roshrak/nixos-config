#!/usr/bin/env bash
# Compatibility entry point for the retired single-host restore helper.

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

printf '%s\n' \
    'NOTICE: restore-nixos-new-device.sh now uses the safe multi-host bootstrap.' \
    'Read docs/MIGRATION-INSTALL.md before deploying a new machine.'

exec "$script_directory/bootstrap-nixos.sh" "$@"
