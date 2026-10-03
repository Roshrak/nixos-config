#!/usr/bin/env bash
# All maintenance mutation happens in disposable fixtures, never the real system.
set -uo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
mode=full
[ "$#" -le 1 ] || { printf 'ERROR: Use one option at a time.\n' >&2; exit 2; }
case "${1:-}" in
    '') ;;
    --quick) mode=quick ;;
    --list) mode=list ;;
    -h|--help)
        printf 'Usage: %s [--quick|--list]\n' "$0"
        printf 'Full: all isolated tests, including offline builds of disposable source exports.\n'
        printf 'Quick: skip the two source/build suites; never activate, publish or transfer wallpapers.\n'
        exit 0 ;;
    *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
tests=(maintenance-feedback-test.py maintenance-workflow-test.py wallpaper-sync-test.py
       audit-report-test.py minecraft-helper-test.py backup-destination-safety-test.sh
       backup-pinned-rename-test.py clean-stray-sessions-test.sh custom-service-restore-test.sh
       publication-safety-test.py update-receipt-test.sh autosleep-test.py
       cleanup-retention-test.py hermes-public-source-test.py
       legacy-publication-wrapper-test.py source-routing-test.py)
if [ "$mode" != quick ]; then tests+=(backup-source-coverage-test.sh backup-production-integration-test.sh); fi
if [ "$mode" = list ]; then printf '%s\n' "${tests[@]}"; exit 0; fi
start_log tests
show_banner "Maintenance tests: $mode" 'Production scripts are tested with disposable data and command shims'
require_commands bash python3 nix jq git timeout || fatal 'A test prerequisite is missing'
passed=0; failed=0; index=0
export AUTOSLEEP_TEST_SOURCE="$NIXOS_DIR/desktop/autosleep.py"
export NIXOS_TEST_SOURCE="$NIXOS_DIR"
autosleep_python=''
if command -v autosleep >/dev/null 2>&1; then
    # Read the immutable Nix wrapper; do not invoke autosleep against the desktop.
    autosleep_python="$(sed -n 's#^exec \(/nix/store/[^ ]*/bin/python3\) .*#\1#p' "$(command -v autosleep)")"
fi
for name in "${tests[@]}"; do
    index=$((index + 1))
    show_step "$index" "${#tests[@]}" "$name"
    case "$name" in *.py) runner=python3 ;; *) runner=bash ;; esac
    if [ "$name" = autosleep-test.py ] && [ -x "$autosleep_python" ]; then
        runner="$autosleep_python"
    fi
    if run_logged "$name" timeout 900 "$runner" "$SCRIPT_DIR/tests/$name"; then
        passed=$((passed + 1)); show_ok
    else
        status=$?
        failed=$((failed + 1)); show_failed "Suite exit: $status. Continuing independent suites."
    fi
done
skipped=0
[ "$mode" != quick ] || skipped=2
show_summary 'TEST RUN FINISHED' "$passed suites passed; $failed failed; $skipped intentionally skipped. Real desktop acceptance is separate."
[ "$failed" -eq 0 ]
