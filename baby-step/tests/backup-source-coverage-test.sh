#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d /tmp/backup-source-coverage-test.XXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/backup-source-coverage-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$test_dir/../lib/source-manifest.sh"
. "$test_dir/../lib/source-validation.sh"

source_root="$scratch/source"
snapshot="$scratch/snapshot"
mkdir -p "$source_root" \
    "$source_root/deep/nixos/desktop/hyprland" \
    "$source_root/deep/nixos/desktop/autosleep" \
    "$source_root/deep/nixos/desktop/gnome-window-rules/schemas" \
    "$source_root/fonts/nested"
printf 'fixture flake\n' > "$source_root/flake.nix"
printf 'fixture lock\n' > "$source_root/flake.lock"
printf '{ }\n' > "$source_root/deep/nixos/configuration.nix"
printf 'return {}\n' > "$source_root/deep/nixos/desktop/hyprland/hyprland.lua"
printf 'def fixture(): return True\n' > "$source_root/deep/nixos/desktop/autosleep/policy.py"
printf 'export default {}\n' > "$source_root/deep/nixos/desktop/gnome-window-rules/extension.js"
printf '{"name":"fixture"}\n' > "$source_root/deep/nixos/desktop/gnome-window-rules/metadata.json"
printf '<schema/>\n' > "$source_root/deep/nixos/desktop/gnome-window-rules/schemas/settings.xml"
printf 'font fixture\n' > "$source_root/fonts/nested/test.ttf"
printf 'cache\n' > "$source_root/deep/runtime.cache"
printf 'do not copy\n' > "$source_root/.env"
printf 'do not copy\n' > "$source_root/deep/provider-secret.json"
mkdir -p "$source_root/.git" "$source_root/backup-old"
printf 'not source\n' > "$source_root/.git/ignored.nix"
printf 'not source\n' > "$source_root/backup-old/ignored.nix"
ln -s /nix/store/nonexistent-result "$source_root/result"

manifest="$scratch/manifest.nul"
nixos_source_manifest "$source_root" > "$manifest"
contains_path() { grep -zFqx -- "$1" "$manifest"; }
for required in \
    flake.nix flake.lock deep/nixos/configuration.nix \
    deep/nixos/desktop/autosleep/policy.py \
    deep/nixos/desktop/hyprland/hyprland.lua \
    deep/nixos/desktop/gnome-window-rules/extension.js \
    deep/nixos/desktop/gnome-window-rules/metadata.json \
    deep/nixos/desktop/gnome-window-rules/schemas/settings.xml fonts/nested/test.ttf; do
    contains_path "$required" || {
        printf 'Required nested source missing from manifest: %s\n' "$required" >&2
        exit 1
    }
done
for excluded in deep/runtime.cache .env deep/provider-secret.json .git/ignored.nix backup-old/ignored.nix; do
    if contains_path "$excluded"; then
        printf 'Excluded or non-source file entered manifest: %s\n' "$excluded" >&2
        exit 1
    fi
done

copy_manifest() {
    local root="$1" target="$2" relative
    mkdir -p "$target"
    while IFS= read -r -d '' relative; do
        mkdir -p "$target/$(dirname -- "$relative")"
        cp -- "$root/$relative" "$target/$relative"
    done < <(nixos_source_manifest "$root")
}
copy_manifest "$source_root" "$snapshot"
while IFS= read -r -d '' relative; do
    cmp -s -- "$source_root/$relative" "$snapshot/$relative"
done < "$manifest"
printf 'Nested source coverage and byte-identical snapshot: PASS\n'

# An isolated flake proves that a referenced source omission fails before any
# backup replacement can occur.
eval_root="$scratch/eval-source"
eval_snapshot="$scratch/eval-snapshot"
mkdir -p "$eval_root/assets/deep" "$eval_root/hyprland"
cat > "$eval_root/flake.nix" <<'NIX'
{
  outputs = _:
    let
      extension = builtins.readFile ./assets/deep/extension.js;
      metadata = builtins.readFile ./assets/deep/metadata.json;
      hyprland = builtins.readFile ./hyprland/hyprland.lua;
      sourceHash = builtins.substring 0 8
        (builtins.hashString "sha256" (extension + metadata + hyprland));
    in {
      nixosConfigurations.tonelico.config.system.build.toplevel.outPath =
        "/nix/store/audit-fixture-" + sourceHash;
    };
}
NIX
printf 'export default {}\n' > "$eval_root/assets/deep/extension.js"
printf '{"fixture":true}\n' > "$eval_root/assets/deep/metadata.json"
printf 'return {}\n' > "$eval_root/hyprland/hyprland.lua"
copy_manifest "$eval_root" "$eval_snapshot"
full_eval="$(nix eval --offline --no-write-lock-file --raw \
    "path:$eval_snapshot#nixosConfigurations.tonelico.config.system.build.toplevel.outPath")"
[[ "$full_eval" == /nix/store/audit-fixture-* ]]

old_backup="$scratch/existing-backup"
mkdir -p "$old_backup"
printf 'preserve original\n' > "$old_backup/sentinel"
missing_snapshot="$scratch/missing-snapshot"
cp -a "$eval_snapshot" "$missing_snapshot"
rm -- "$missing_snapshot/assets/deep/extension.js"
if nix eval --offline --no-write-lock-file --raw \
    "path:$missing_snapshot#nixosConfigurations.tonelico.config.system.build.toplevel.outPath" \
    > "$scratch/missing-eval.out" 2> "$scratch/missing-eval.err"; then
    printf 'Flake evaluation accepted an omitted imported asset\n' >&2
    exit 1
fi
test "$(cat "$old_backup/sentinel")" = 'preserve original'
printf 'Missing imported asset rejected; existing backup preserved: PASS\n'

# Symlinked sources, loops, and unreadable source modes fail closed.
outside="$scratch/outside.lua"
printf 'outside\n' > "$outside"
ln -s "$outside" "$source_root/untrusted.lua"
if nixos_source_manifest "$source_root" > /dev/null 2> "$scratch/symlink.err"; then
    printf 'External source symlink was accepted\n' >&2
    exit 1
fi
rm -- "$source_root/untrusted.lua"
ln -s loop.lua "$source_root/loop.lua"
if nixos_source_manifest "$source_root" > /dev/null 2> "$scratch/loop.err"; then
    printf 'Symlink loop was accepted\n' >&2
    exit 1
fi
rm -- "$source_root/loop.lua"
chmod 000 "$source_root/deep/nixos/configuration.nix"
if nixos_source_manifest "$source_root" > /dev/null 2> "$scratch/unreadable.err"; then
    chmod 644 "$source_root/deep/nixos/configuration.nix"
    printf 'Unreadable source mode was accepted\n' >&2
    exit 1
fi
chmod 644 "$source_root/deep/nixos/configuration.nix"
printf 'External symlink, loop, and unreadable source rejection: PASS\n'

# Exercise the production resource-contract validator against each declared
# input independently in both source and snapshot trees.
contract_root="$scratch/contract-source"
contract_snapshot="$scratch/contract-snapshot"
contract="$scratch/required-build-inputs.json"
cat > "$contract" <<'JSON'
{
  "schema": 1,
  "common": ["flake.nix", "flake.lock", "configuration.nix"],
  "hosts": {"fixture": [
    "hosts/fixture/host.nix",
    "hosts/fixture/default.nix",
    "hosts/fixture/hardware-configuration.nix"
  ]}
}
JSON
mkdir -p "$contract_root/hosts/fixture"
for relative in \
    flake.nix flake.lock configuration.nix \
    hosts/fixture/host.nix hosts/fixture/default.nix \
    hosts/fixture/hardware-configuration.nix; do
    printf 'fixture %s\n' "$relative" > "$contract_root/$relative"
done
copy_manifest "$contract_root" "$contract_snapshot"
validate_required_build_inputs "$contract_root" fixture "$contract" \
    "$test_dir/../lib/source-manifest.sh"
validate_required_build_inputs "$contract_snapshot" fixture "$contract" \
    "$test_dir/../lib/source-manifest.sh"

for relative in $(jq -r '.common[], .hosts.fixture[]' "$contract"); do
    for omission in source snapshot both; do
        case "$omission" in
            source)
                source_case="$scratch/source-missing"
                snapshot_case="$scratch/snapshot-missing"
                cp -a "$contract_root" "$source_case"
                cp -a "$contract_snapshot" "$snapshot_case"
                rm -- "$source_case/$relative"
                ;;
            snapshot)
                source_case="$scratch/source-missing"
                snapshot_case="$scratch/snapshot-missing"
                cp -a "$contract_root" "$source_case"
                cp -a "$contract_snapshot" "$snapshot_case"
                rm -- "$snapshot_case/$relative"
                ;;
            both)
                source_case="$scratch/source-missing"
                snapshot_case="$scratch/snapshot-missing"
                cp -a "$contract_root" "$source_case"
                cp -a "$contract_snapshot" "$snapshot_case"
                rm -- "$source_case/$relative" "$snapshot_case/$relative"
                ;;
        esac
        rejected=0
        if [ "$omission" != snapshot ] && ! validate_required_build_inputs \
            "$source_case" fixture "$contract" "$test_dir/../lib/source-manifest.sh" \
            > /dev/null 2>&1; then
            rejected=1
        elif [ "$omission" = snapshot ] && ! validate_required_build_inputs \
            "$snapshot_case" fixture "$contract" "$test_dir/../lib/source-manifest.sh" \
            > /dev/null 2>&1; then
            rejected=1
        fi
        [ "$rejected" -eq 1 ] || {
            printf 'Required input omission was accepted: %s (%s)\n' "$relative" "$omission" >&2
            exit 1
        }
        rm -rf -- "$source_case" "$snapshot_case"
    done
done
printf 'Production resource gate rejects every declared source/snapshot omission: PASS\n'

# Repeat the omission matrix with every path from the shipped production
# contract, using small inert fixture bytes so this remains independent of the
# live NixOS source and does not copy user configuration.
actual_contract="$test_dir/../required-build-inputs.json"
actual_source="$scratch/actual-contract-source"
actual_snapshot="$scratch/actual-contract-snapshot"
mkdir -p "$actual_source"
while IFS= read -r relative; do
    mkdir -p "$actual_source/$(dirname -- "$relative")"
    printf 'fixture input %s\n' "$relative" > "$actual_source/$relative"
done < <(jq -r '.common[], .hosts.tonelico[]' "$actual_contract")
copy_manifest "$actual_source" "$actual_snapshot"
validate_required_build_inputs "$actual_source" tonelico "$actual_contract" \
    "$test_dir/../lib/source-manifest.sh"
validate_required_build_inputs "$actual_snapshot" tonelico "$actual_contract" \
    "$test_dir/../lib/source-manifest.sh"
while IFS= read -r relative; do
    source_case="$scratch/actual-source-missing"
    snapshot_case="$scratch/actual-snapshot-missing"
    cp -a "$actual_source" "$source_case"
    rm -- "$source_case/$relative"
    if validate_required_build_inputs "$source_case" tonelico "$actual_contract" \
        "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
        printf 'Shipped source contract accepted source-only omission: %s\n' "$relative" >&2
        exit 1
    fi
    rm -rf -- "$source_case"

    cp -a "$actual_snapshot" "$snapshot_case"
    rm -- "$snapshot_case/$relative"
    if validate_required_build_inputs "$snapshot_case" tonelico "$actual_contract" \
        "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
        printf 'Shipped source contract accepted snapshot-only omission: %s\n' "$relative" >&2
        exit 1
    fi
    rm -rf -- "$snapshot_case"

    cp -a "$actual_source" "$source_case"
    cp -a "$actual_snapshot" "$snapshot_case"
    rm -- "$source_case/$relative" "$snapshot_case/$relative"
    if verify_nixos_snapshot "$source_case" "$snapshot_case" tonelico \
        "$actual_contract" "$test_dir/../lib/source-manifest.sh" \
        > "$scratch/actual-both-missing.out" 2> "$scratch/actual-both-missing.err"; then
        printf 'Shipped source contract accepted both-missing input: %s\n' "$relative" >&2
        exit 1
    fi
    grep -Fq "Required build input is missing or unreadable: $relative" \
        "$scratch/actual-both-missing.err" || {
        cat "$scratch/actual-both-missing.err" >&2
        printf 'Both-missing input failed before the expected contract gate: %s\n' "$relative" >&2
        exit 1
    }
    rm -rf -- "$source_case" "$snapshot_case"
done < <(jq -r '.common[], .hosts.tonelico[]' "$actual_contract")
printf 'Shipped contract rejects every source-only, snapshot-only, and both-missing resource: PASS\n'

bad_contract="$scratch/bad-contract.json"
for bad_path in '/absolute/file' '../escape' 'hosts/../escape'; do
    jq --arg path "$bad_path" '.common[0] = $path' "$contract" > "$bad_contract"
    if validate_required_build_inputs "$contract_root" fixture "$bad_contract" \
        "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
        printf 'Unsafe contract path was accepted: %s\n' "$bad_path" >&2
        exit 1
    fi
done
jq '.common += ["flake.nix"]' "$contract" > "$bad_contract"
if validate_required_build_inputs "$contract_root" fixture "$bad_contract" \
    "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
    printf 'Duplicate contract path was accepted\n' >&2
    exit 1
fi
if validate_required_build_inputs "$contract_root" unknown "$contract" \
    "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
    printf 'Unknown contract host was accepted\n' >&2
    exit 1
fi
chmod 000 "$contract_root/hosts/fixture/host.nix"
if validate_required_build_inputs "$contract_root" fixture "$contract" \
    "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
    chmod 644 "$contract_root/hosts/fixture/host.nix"
    printf 'Unreadable required contract input was accepted\n' >&2
    exit 1
fi
chmod 644 "$contract_root/hosts/fixture/host.nix"
mv "$contract_root/hosts/fixture" "$contract_root/hosts/fixture-real"
ln -s fixture-real "$contract_root/hosts/fixture"
if validate_required_build_inputs "$contract_root" fixture "$contract" \
    "$test_dir/../lib/source-manifest.sh" > /dev/null 2>&1; then
    printf 'Symlinked required contract ancestor was accepted\n' >&2
    exit 1
fi
rm -- "$contract_root/hosts/fixture"
mv -- "$contract_root/hosts/fixture-real" "$contract_root/hosts/fixture"

# jq can validate the schema successfully and then fail after producing a
# partial path list. The producer's status must reach the public validator.
jq_bin="$scratch/partial-jq-bin"
mkdir -m 0700 "$jq_bin"
real_jq="$(command -v jq)"
cat > "$jq_bin/jq" <<'JQWRAPPER'
#!/usr/bin/env bash
if [[ " $* " == *" -er "* ]]; then
    printf 'flake.nix\n'
    exit 77
fi
exec "$AUDIT_REAL_JQ" "$@"
JQWRAPPER
chmod 755 "$jq_bin/jq"
if AUDIT_REAL_JQ="$real_jq" PATH="$jq_bin:$PATH" \
    validate_required_build_inputs "$contract_root" fixture "$contract" \
        "$test_dir/../lib/source-manifest.sh" \
        > "$scratch/partial-enumeration.out" 2> "$scratch/partial-enumeration.err"; then
    printf 'Partial resource enumeration with jq exit 77 was accepted\n' >&2
    exit 1
fi
grep -Fq 'Source resource contract enumeration failed.' \
    "$scratch/partial-enumeration.err" || {
    cat "$scratch/partial-enumeration.err" >&2
    printf 'Partial jq failure did not report enumeration failure\n' >&2
    exit 1
}
printf 'Partial required-resource enumeration with nonzero producer status rejected: PASS\n'
printf 'Unsafe contract paths, duplicates, unknown hosts, permissions, and symlinks rejected: PASS\n'

# A real Nix build must still block the gate when a directory-only child is
# absent but not individually declared. The wrapper fixes only the two eval
# answers for this focused fallback test; the no-link build is delegated to
# the real offline Nix executable and is expected to fail in the builder.
build_source="$scratch/unlisted-build-child-source"
build_snapshot="$scratch/unlisted-build-child-snapshot"
build_bin="$scratch/nix-wrapper-bin"
build_contract="$scratch/unlisted-build-child-contract.json"
build_manifest="$test_dir/../lib/source-manifest.sh"
mkdir -p "$build_source/assets" "$build_source/hosts/tonelico" \
    "$build_snapshot" "$build_bin"
cp -- "$actual_contract" "$build_contract"
case "$(uname -m)" in
    x86_64) build_system=x86_64-linux ;;
    aarch64) build_system=aarch64-linux ;;
    *) printf 'Unsupported fixture build architecture\n' >&2; exit 1 ;;
esac
cat > "$build_source/flake.nix" <<NIX
{
  outputs = _:
    let
      toplevel = derivation {
        name = "unlisted-directory-child-negative-test";
        system = "$build_system";
        builder = "/bin/sh";
        args = [ "-c" "test -f \${./assets}/extension.bin || { printf missing-extension.bin >&2; exit 42; }; printf present > \$out" ];
      };
    in {
      nixosConfigurations.tonelico.config.system.build.toplevel = toplevel;
    };
}
NIX
cat > "$build_source/flake.lock" <<'JSON'
{"nodes":{"root":{"inputs":{}}},"root":"root","version":7}
JSON
printf '{ }\n' > "$build_source/configuration.nix"
printf '{ }\n' > "$build_source/hosts/tonelico/host.nix"
printf '{ }\n' > "$build_source/hosts/tonelico/default.nix"
printf '{ }\n' > "$build_source/hosts/tonelico/hardware-configuration.nix"
printf 'fixture build directory\n' > "$build_source/assets/README.md"
printf 'present in source only\n' > "$build_source/assets/extension.bin"
while IFS= read -r relative; do
    case "$relative" in flake.nix|flake.lock|configuration.nix|hosts/tonelico/*) continue ;; esac
    mkdir -p "$build_source/$(dirname -- "$relative")"
    printf 'required fixture input %s\n' "$relative" > "$build_source/$relative"
done < <(jq -r '.common[], .hosts.tonelico[]' "$build_contract")
while IFS= read -r -d '' relative; do
    mkdir -p "$build_snapshot/$(dirname -- "$relative")"
    cp -- "$build_source/$relative" "$build_snapshot/$relative"
done < <(nixos_source_manifest "$build_source")
test -f "$build_source/assets/extension.bin"
test ! -e "$build_snapshot/assets/extension.bin"
validate_required_build_inputs "$build_source" tonelico "$build_contract" "$build_manifest"
validate_required_build_inputs "$build_snapshot" tonelico "$build_contract" "$build_manifest"
real_nix="$(command -v nix)"
cat > "$build_bin/nix" <<'NIXWRAPPER'
#!/usr/bin/env bash
if [ "${1:-}" = eval ]; then
    printf '/nix/store/audit-fixed-toplevel\n'
    exit 0
fi
exec "$AUDIT_REAL_NIX" "$@"
NIXWRAPPER
chmod 755 "$build_bin/nix"
build_sentinel="$scratch/build-target-sentinel"
printf 'unchanged backup sentinel\n' > "$build_sentinel"
build_sentinel_before="$(sha256sum "$build_sentinel" | awk '{print $1}')"
set +e
AUDIT_REAL_NIX="$real_nix" PATH="$build_bin:$PATH" \
    verify_nixos_snapshot "$build_source" "$build_snapshot" tonelico \
        "$build_contract" "$build_manifest" \
        > "$scratch/unlisted-build.stdout" 2> "$scratch/unlisted-build.stderr"
build_status=$?
set -e
if [ "$build_status" -eq 0 ]; then
    printf 'Undeclared missing directory child passed the real no-link build gate\n' >&2
    exit 1
fi
grep -Fq 'extension.bin' "$scratch/unlisted-build.stderr" || {
    cat "$scratch/unlisted-build.stderr" >&2
    printf 'No-link build failed for a reason other than the missing directory child\n' >&2
    exit 1
}
test "$(sha256sum "$build_sentinel" | awk '{print $1}')" = "$build_sentinel_before"
printf 'Real offline no-link build rejects an undeclared missing directory child before replacement: PASS\n'

resolved_toplevel="$(evaluate_nixos_toplevel /etc/nixos tonelico)"
[[ "$resolved_toplevel" == /nix/store/* ]] || {
    printf 'Production host selector returned an invalid path\n' >&2
    exit 1
}
if evaluate_nixos_toplevel /etc/nixos '../tonelico' > /dev/null 2>&1; then
    printf 'Unsafe host selector was accepted\n' >&2
    exit 1
fi
invalid_flake="$scratch/invalid-selector-flake"
mkdir -p "$invalid_flake"
printf '{ outputs = _:\n' > "$invalid_flake/flake.nix"
if evaluate_nixos_toplevel "$invalid_flake" fixture \
    > "$scratch/invalid-expression.out" 2> "$scratch/invalid-expression.err"; then
    printf 'Invalid Nix expression was accepted by the production selector\n' >&2
    exit 1
fi
grep -Fq 'NixOS toplevel evaluation failed for host fixture.' \
    "$scratch/invalid-expression.err" || {
    cat "$scratch/invalid-expression.err" >&2
    printf 'Invalid Nix expression failure was not propagated by the production selector\n' >&2
    exit 1
}
timeout_bin="$scratch/timeout-wrapper-bin"
mkdir -p "$timeout_bin"
cat > "$timeout_bin/timeout" <<'TIMEOUTWRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AUDIT_TIMEOUT_ARGUMENTS"
exit 124
TIMEOUTWRAPPER
chmod 755 "$timeout_bin/timeout"
set +e
AUDIT_TIMEOUT_ARGUMENTS="$scratch/timeout-arguments" \
    PATH="$timeout_bin:$PATH" \
    evaluate_nixos_toplevel /etc/nixos tonelico \
    > "$scratch/timeout-evaluation.out" 2> "$scratch/timeout-evaluation.err"
timeout_status=$?
set -e
if [ "$timeout_status" -eq 0 ] ||
   [ "$(sed -n '1p' "$scratch/timeout-arguments")" != 120 ] ||
   [ "$(sed -n '2p' "$scratch/timeout-arguments")" != nix ]; then
    printf 'Production selector did not propagate its bounded timeout invocation\n' >&2
    exit 1
fi
grep -Fq 'NixOS toplevel evaluation failed for host tonelico.' \
    "$scratch/timeout-evaluation.err" || {
    cat "$scratch/timeout-evaluation.err" >&2
    printf 'Production selector failed to propagate a timeout result\n' >&2
    exit 1
}
if timeout 120 nix eval --offline --no-write-lock-file --raw \
    'path:/etc/nixos#tonelico.config.system.build.toplevel.outPath' \
    > "$scratch/old-selector.out" 2> "$scratch/old-selector.err"; then
    printf 'Historical selector without nixosConfigurations unexpectedly evaluated\n' >&2
    exit 1
fi
printf 'Production flake selector resolves a toplevel and rejects unsafe host keys: PASS\n'
printf 'Invalid Nix expression and bounded evaluation timeout both fail closed: PASS\n'

mismatched_snapshot="$scratch/contract-mismatched-snapshot"
cp -a "$contract_snapshot" "$mismatched_snapshot"
printf 'different selected input bytes\n' > "$mismatched_snapshot/flake.nix"
if verify_nixos_snapshot "$contract_root" "$mismatched_snapshot" fixture \
    "$contract" "$test_dir/../lib/source-manifest.sh" \
    > "$scratch/parity.out" 2> "$scratch/parity.err"; then
    printf 'Source/snapshot selected-input byte mismatch was accepted\n' >&2
    exit 1
fi
grep -Fq 'Required build input differs between source and prepared snapshot: flake.nix' \
    "$scratch/parity.err" || {
    cat "$scratch/parity.err" >&2
    printf 'Selected-input parity mismatch failed before the expected byte comparison\n' >&2
    exit 1
}
printf 'Selected-input byte parity mismatch is rejected before Nix evaluation/build: PASS\n'
