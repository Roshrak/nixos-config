#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d /tmp/update-receipt-test.XXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/update-receipt-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

export BABY_STEP_DIR="$scratch/baby-step"
export NIXOS_DIR="$scratch/nixos"
mkdir -p "$NIXOS_DIR/assets/deep" "$NIXOS_DIR/fonts"
printf '{ outputs = _: {}; }\n' > "$NIXOS_DIR/flake.nix"
printf 'locked inputs fixture\n' > "$NIXOS_DIR/flake.lock"
printf '{ }\n' > "$NIXOS_DIR/configuration.nix"
printf 'return {}\n' > "$NIXOS_DIR/assets/deep/window.lua"
printf 'export default {}\n' > "$NIXOS_DIR/assets/deep/extension.js"
printf '{"fixture":true}\n' > "$NIXOS_DIR/assets/deep/metadata.json"
printf '<schema/>\n' > "$NIXOS_DIR/assets/deep/settings.xml"
printf 'font fixture\n' > "$NIXOS_DIR/fonts/test.ttf"

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$test_dir/../lib/common.sh"

test_generation=120
test_active_system=/nix/store/system-fixture-120
readlink() {
    if [ "${1:-}" = -f ] && [ "${2:-}" = /run/current-system ]; then
        printf '%s\n' "$test_active_system"
    else
        command readlink "$@"
    fi
}
current_generation() { printf '%s\n' "$test_generation"; }

assert_digest_changes() {
    local path="$1" initial changed
    initial="$(configuration_source_digest)"
    printf '\nasset change\n' >> "$NIXOS_DIR/$path"
    changed="$(configuration_source_digest)"
    [ "$initial" != "$changed" ] || {
        printf 'Source digest did not change for %s\n' "$path" >&2
        exit 1
    }
}

for source_path in \
    configuration.nix assets/deep/window.lua assets/deep/extension.js \
    assets/deep/metadata.json assets/deep/settings.xml fonts/test.ttf; do
    assert_digest_changes "$source_path"
done
printf 'Actual digest changes for Nix, Lua, JS, JSON, XML, and font inputs: PASS\n'

run_id=fixture-run-120
write_update_receipt "$run_id" warning
receipt="$STATE_DIR/update-success-receipt.txt"
test "$(receipt_value "$receipt" schema)" = 2
validate_update_receipt "$run_id"
printf 'Matching run, active system, source, lock, and schema v2: PASS\n'

if validate_update_receipt different-run; then
    printf 'Mismatched run ID was accepted\n' >&2
    exit 1
fi
printf 'Mismatched run ID: rejected\n'

test_generation=121
if validate_update_receipt "$run_id"; then
    printf 'Changed generation was accepted\n' >&2
    exit 1
fi
test_generation=120
printf 'Changed generation: rejected\n'

test_active_system=/nix/store/system-fixture-changed
if validate_update_receipt "$run_id"; then
    printf 'Changed active system was accepted\n' >&2
    exit 1
fi
test_active_system=/nix/store/system-fixture-120
printf 'Changed active system: rejected\n'

printf 'Lua-only change\n' >> "$NIXOS_DIR/assets/deep/window.lua"
if validate_update_receipt "$run_id"; then
    printf 'Changed Lua source was accepted\n' >&2
    exit 1
fi
printf 'Asset-only source change invalidates receipt: rejected\n'

printf 'modified locked inputs fixture\n' > "$NIXOS_DIR/flake.lock"
if validate_update_receipt "$run_id"; then
    printf 'Changed flake lock was accepted\n' >&2
    exit 1
fi
printf 'Changed flake lock: rejected\n'

# Unknown runtime/cache files and the generated result pointer are excluded.
digest_before_cache="$(configuration_source_digest)"
mkdir -p "$NIXOS_DIR/runtime-cache"
printf 'cache state\n' > "$NIXOS_DIR/runtime-cache/state.bin"
ln -s /nix/store/nonexistent-result "$NIXOS_DIR/result"
digest_after_cache="$(configuration_source_digest)"
test "$digest_before_cache" = "$digest_after_cache"
rm -- "$NIXOS_DIR/result"
printf 'Runtime cache and generated result link do not invalidate digest: PASS\n'

chmod 000 "$NIXOS_DIR/assets/deep/window.lua"
if configuration_source_digest > /dev/null 2>&1; then
    chmod 644 "$NIXOS_DIR/assets/deep/window.lua"
    printf 'Unreadable source was accepted by the digest\n' >&2
    exit 1
fi
chmod 644 "$NIXOS_DIR/assets/deep/window.lua"
printf 'Unreadable source: rejected\n'

printf 'outside\n' > "$scratch/outside.lua"
ln -s "$scratch/outside.lua" "$NIXOS_DIR/assets/deep/linked.lua"
if configuration_source_digest > /dev/null 2>&1; then
    rm -- "$NIXOS_DIR/assets/deep/linked.lua"
    printf 'Retargetable source symlink was accepted\n' >&2
    exit 1
fi
rm -- "$NIXOS_DIR/assets/deep/linked.lua"
printf 'Source symlink: rejected\n'

chmod 644 "$receipt"
if validate_update_receipt "$run_id"; then
    printf 'Insecure receipt permissions were accepted\n' >&2
    exit 1
fi
chmod 600 "$receipt"
printf 'Receipt mode validation: rejected insecure mode\n'

sed -i 's/^schema=2$/schema=1/' "$receipt"
if validate_update_receipt "$run_id"; then
    printf 'Previous receipt schema was accepted\n' >&2
    exit 1
fi
printf 'Previous receipt schema: rejected\n'

sed -i 's/^schema=1$/schema=2/' "$receipt"
printf 'health=passed\n' >> "$receipt"
if validate_update_receipt "$run_id"; then
    printf 'Duplicate receipt key was accepted\n' >&2
    exit 1
fi
printf 'Duplicate receipt key: rejected\n'

write_update_receipt next-run passed
validate_update_receipt next-run
printf 'Fresh v2 receipt after source changes: PASS\n'
