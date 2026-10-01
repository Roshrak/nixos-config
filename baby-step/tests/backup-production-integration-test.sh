#!/usr/bin/env bash
set -eEuo pipefail
trap 'status=$?; printf "Production integration failed at line %s: %s (status %s)\\n" \
    "${BASH_LINENO[0]}" "$BASH_COMMAND" "$status" >&2; exit "$status"' ERR

scratch="$(mktemp -d /tmp/backup-production-integration-test.XXXXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/backup-production-integration-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT
chmod 700 "$scratch"

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
baby_step_dir="$(cd -- "$test_dir/.." && pwd)"
backup_script="$baby_step_dir/backup-config.sh"
fixture_home="$scratch/home"
fixture_baby_step="$fixture_home/baby-step"
fixture_repo="$fixture_home/nixos-config"
fixture_nixos="$scratch/nixos-source"
stub_bin="$scratch/bin"
. "$baby_step_dir/lib/source-manifest.sh"
mkdir -p "$fixture_home/.config/mango" "$fixture_home/.config/hypr" \
    "$fixture_home/.config/systemd/user" "$fixture_home/.hermes" \
    "$fixture_home/.local/bin" "$fixture_baby_step/backups" \
    "$fixture_baby_step/lib" "$fixture_baby_step/tests" \
    "$fixture_repo/nixos" "$fixture_repo/dotfiles/.hermes" \
    "$fixture_repo/dotfiles/.local/bin" "$stub_bin"

mkdir -p "$fixture_nixos"
while IFS= read -r -d '' relative; do
    mkdir -p "$fixture_nixos/$(dirname -- "$relative")"
    cp -a --no-preserve=ownership "/etc/nixos/$relative" "$fixture_nixos/$relative"
done < <(nixos_source_manifest /etc/nixos)

cp -- "$baby_step_dir/custom-service-manifest.tsv" \
    "$fixture_baby_step/custom-service-manifest.tsv"
cp -- "$baby_step_dir/required-build-inputs.json" \
    "$fixture_baby_step/required-build-inputs.json"
for maintenance_file in common.sh source-manifest.sh source-validation.sh destination-safety.sh custom-service-manifest.sh publication-check.py; do
    cp -- "$baby_step_dir/lib/$maintenance_file" "$fixture_baby_step/lib/$maintenance_file"
done
for test_file in backup-destination-safety-test.sh clean-stray-sessions-test.sh update-receipt-test.sh \
    backup-source-coverage-test.sh backup-production-integration-test.sh \
    custom-service-restore-test.sh; do
    cp -- "$baby_step_dir/tests/$test_file" "$fixture_baby_step/tests/$test_file"
done
printf 'fixture mango config\n' > "$fixture_home/.config/mango/config.conf"
printf 'fixture hyprland config\n' > "$fixture_home/.config/hypr/hyprland.lua"
printf 'fixture Hermes helper\n' > "$fixture_home/.hermes/agy_bridge.py"
printf 'fixture chat helper\n' > "$fixture_home/.local/bin/mc_chat_responder.py"
printf 'fixture Hermes unit\n' > "$fixture_home/.config/systemd/user/agy-bridge.service"
printf 'fixture chat unit\n' > "$fixture_home/.config/systemd/user/mc-chat-responder.service"
runtime_fixture="$fixture_home/.config/theme-profiles/fixture/noctalia-state"
mkdir -p "$runtime_fixture/.catalog"
outside_clipboard="$scratch/outside-clipboard"
mkdir "$outside_clipboard"
printf 'private fixture sentinel\n' > "$outside_clipboard/sentinel"
ln -s "$outside_clipboard" "$runtime_fixture/clipboard"
printf 'generated catalog\n' > "$runtime_fixture/.catalog/generated.json"
printf '{}\n' > "$runtime_fixture/.noctalia-cache.json"
printf 'fixture seed\n' > "$runtime_fixture/settings.toml"
printf 'preserve this backup target\n' > "$fixture_repo/dotfiles/.hermes/agy_bridge.py"
printf 'preserve local backup target\n' > "$fixture_repo/dotfiles/.local/bin/original-sentinel"
printf 'preserve NixOS backup target\n' > "$fixture_repo/nixos/original-sentinel"
printf 'preserve hardware backup\n' > \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix"

for command_name in mango niri noctalia Hyprland; do
    cat > "$stub_bin/$command_name" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod 755 "$stub_bin/$command_name"
done
cat > "$stub_bin/gsettings" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod 755 "$stub_bin/gsettings"

git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name 'Audit Fixture'
git -C "$fixture_repo" config user.email 'audit-fixture@example.invalid'
git -C "$fixture_repo" add -- dotfiles/.hermes/agy_bridge.py \
    dotfiles/.local/bin/original-sentinel nixos/original-sentinel
git -C "$fixture_repo" -c user.name='Audit Fixture' \
    -c user.email='audit-fixture@example.invalid' commit -qm 'fixture baseline'
index_before="$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')"
hardware_before="$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')"
backup_before="$(sha256sum "$fixture_repo/dotfiles/.hermes/agy_bridge.py" | awk '{print $1}')"

set +e
env HOME="$fixture_home" \
    BABY_STEP_DIR="$fixture_baby_step" \
    BACKUP_REPO="$fixture_repo" \
    NIXOS_DIR="$fixture_nixos" \
    PATH="$stub_bin:$PATH" \
    "$backup_script" --check-only > "$scratch/backup.stdout" 2> "$scratch/backup.stderr"
backup_status=$?
set -e
if [ "$backup_status" -ne 0 ]; then
    cat "$scratch/backup.stdout" >&2
    cat "$scratch/backup.stderr" >&2
    latest_log="$(find "$fixture_baby_step/logs" -maxdepth 1 -type f -name 'backup-*.log' -print -quit 2>/dev/null || true)"
    if [ -n "$latest_log" ]; then sed -n '1,180p' "$latest_log" >&2; fi
    printf 'Production backup --check-only failed with status %s\n' "$backup_status" >&2
    exit 1
fi

grep -Fq 'Source coverage, evaluation, and offline build passed.' "$scratch/backup.stdout"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before"
test "$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')" = "$hardware_before"
test "$(sha256sum "$fixture_repo/dotfiles/.hermes/agy_bridge.py" | awk '{print $1}')" = "$backup_before"
test -z "$(git -C "$fixture_repo" status --porcelain)"
if find "$fixture_baby_step/state" -maxdepth 1 -type d -name 'snapshot.*' -print -quit | grep -q .; then
    printf 'Temporary snapshot was not cleaned after check-only\n' >&2
    exit 1
fi
check_log="$(find "$fixture_baby_step/logs" -maxdepth 1 -type f -name 'backup-*.log' \
    -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
built_line="$(rg -m1 'Prepared NixOS snapshot evaluated and built: /nix/store/' "$check_log" || true)"
if [ -z "$built_line" ]; then
    printf 'Production log lacks the realized candidate toplevel evidence\n' >&2
    exit 1
fi
printf 'Production evidence: %s\n' "$built_line"
printf 'Actual backup entry point selects, validates, and builds a disposable snapshot; targets unchanged: PASS\n'

# Exercise the actual production entry point against unsafe destinations. A
# tiny Nix selector shim keeps these refusal-path tests independent of flake
# evaluation/build work; no successful check can reach the build stage here.
preflight_bin="$scratch/preflight-bin"
mkdir -m 0700 "$preflight_bin"
cat > "$preflight_bin/nix" <<'NIXPREFLIGHT'
#!/usr/bin/env bash
case " $* " in
    *" --json "*) printf '["tonelico"]\n' ;;
    *) printf '%s\n' "$AUDIT_FIXTURE_HOST" ;;
esac
NIXPREFLIGHT
chmod 755 "$preflight_bin/nix"
run_unsafe_check_only() {
    local label="$1" status
    if env HOME="$fixture_home" \
        BABY_STEP_DIR="$fixture_baby_step" \
        BACKUP_REPO="$fixture_repo" \
        NIXOS_DIR="$fixture_nixos" \
        AUDIT_FIXTURE_HOST="$(hostname)" \
        PATH="$preflight_bin:$stub_bin:$PATH" \
        "$backup_script" --check-only > "$scratch/$label.stdout" \
        2> "$scratch/$label.stderr"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        printf 'Production backup entry point accepted unsafe fixture destination: %s\n' "$label" >&2
        exit 1
    fi
    grep -Fq 'A backup or recovery destination is unsafe' "$scratch/$label.stderr" || {
        cat "$scratch/$label.stdout" "$scratch/$label.stderr" >&2
        printf 'Unsafe fixture was not rejected by destination preflight: %s\n' "$label" >&2
        exit 1
    }
}

outside_local="$scratch/outside-local"
mkdir -p "$outside_local/bin"
printf 'outside .local sentinel\n' > "$outside_local/bin/sentinel"
outside_local_before="$(sha256sum "$outside_local/bin/sentinel" | awk '{print $1}')"
local_tree_digest() (
    cd -- "$1"
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
)
tree_digest() {
    (
        printf 'root %s\n' "$(stat -c '%a:%u:%g:%F' -- "$1")"
        cd -- "$1"
        find . -printf '%P\t%y\t%m\t%U:%G\t%l\n' | sort
        find . -type f -print0 | sort -z | xargs -0 -r sha256sum
    ) | sha256sum | awk '{print $1}'
}
local_tree_before="$(local_tree_digest "$fixture_repo/dotfiles/.local")"
mv -- "$fixture_repo/dotfiles/.local" "$scratch/original-local-tree"
ln -s "$outside_local" "$fixture_repo/dotfiles/.local"
run_unsafe_check_only symlink-ancestor
test -L "$fixture_repo/dotfiles/.local"
test "$(readlink "$fixture_repo/dotfiles/.local")" = "$outside_local"
test "$(sha256sum "$outside_local/bin/sentinel" | awk '{print $1}')" = "$outside_local_before"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before"
test "$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')" = "$hardware_before"
rm -- "$fixture_repo/dotfiles/.local"
mv -- "$scratch/original-local-tree" "$fixture_repo/dotfiles/.local"
local_tree_after="$(local_tree_digest "$fixture_repo/dotfiles/.local")"
test "$local_tree_after" = "$local_tree_before"
printf 'Actual backup entry point rejects ancestor symlink without changing sibling or repository state: PASS\n'

mv -- "$fixture_repo/nixos" "$scratch/original-nixos-tree"
ln -s "$scratch/missing-nixos-target" "$fixture_repo/nixos"
run_unsafe_check_only dangling-leaf
test -L "$fixture_repo/nixos"
test "$(readlink "$fixture_repo/nixos")" = "$scratch/missing-nixos-target"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before"
test "$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')" = "$hardware_before"
rm -- "$fixture_repo/nixos"
mv -- "$scratch/original-nixos-tree" "$fixture_repo/nixos"
printf 'Actual backup entry point rejects dangling destination symlink and preserves it: PASS\n'

# Force the required-path jq producer to return a partial list and status 77
# through the real --check-only entry point. Nix selection is stubbed only to
# keep this early-failure case bounded; the production validator is unchanged.
partial_jq_bin="$scratch/partial-jq-bin"
mkdir -m 0700 "$partial_jq_bin"
real_jq="$(command -v jq)"
cat > "$partial_jq_bin/jq" <<'JQPARTIAL'
#!/usr/bin/env bash
for argument in "$@"; do
    if [ "$argument" = -er ]; then
        printf 'flake.nix\n'
        exit 77
    fi
done
exec "$AUDIT_REAL_JQ" "$@"
JQPARTIAL
chmod 755 "$partial_jq_bin/jq"
repo_tree_before_partial="$(tree_digest "$fixture_repo")"
git_status_before_partial="$(git -C "$fixture_repo" status --porcelain=v1 -z | sha256sum | awk '{print $1}')"
index_before_partial="$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')"
if env HOME="$fixture_home" \
    BABY_STEP_DIR="$fixture_baby_step" \
    BACKUP_REPO="$fixture_repo" \
    NIXOS_DIR="$fixture_nixos" \
    AUDIT_FIXTURE_HOST="$(hostname)" \
    AUDIT_REAL_JQ="$real_jq" \
    PATH="$preflight_bin:$partial_jq_bin:$stub_bin:$PATH" \
    "$backup_script" --check-only > "$scratch/partial-jq.stdout" \
    2> "$scratch/partial-jq.stderr"; then
    printf 'Actual backup check-only accepted partial jq enumeration\n' >&2
    exit 1
else
    partial_jq_status=$?
fi
test "$partial_jq_status" -ne 0
partial_jq_log="$(find "$fixture_baby_step/logs" -maxdepth 1 -type f -name 'backup-*.log' \
    -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
grep -Fq 'Source resource contract enumeration failed.' "$partial_jq_log"
test "$(tree_digest "$fixture_repo")" = "$repo_tree_before_partial"
test "$(git -C "$fixture_repo" status --porcelain=v1 -z | sha256sum | awk '{print $1}')" = \
    "$git_status_before_partial"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before_partial"
test "$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')" = "$hardware_before"
if find "$fixture_baby_step/state" -maxdepth 1 -type d -name 'snapshot.*' -print -quit | grep -q .; then
    printf 'Temporary snapshot leaked after actual producer failure\n' >&2
    exit 1
fi
printf 'Actual backup entry point rejects partial jq enumeration; repository, index, hardware and temp state unchanged: PASS\n'

# Now exercise the confirmed replacement path only against this disposable
# repository. The explicit fixture token never reaches the real backup tree.
index_before_transaction="$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')"
set +e
printf 'SNAPSHOT\n' | env HOME="$fixture_home" \
    BABY_STEP_DIR="$fixture_baby_step" \
    BACKUP_REPO="$fixture_repo" \
    NIXOS_DIR="$fixture_nixos" \
    PATH="$stub_bin:$PATH" \
    "$backup_script" > "$scratch/transaction.stdout" 2> "$scratch/transaction.stderr"
transaction_status=$?
set -e
if [ "$transaction_status" -ne 0 ]; then
    cat "$scratch/transaction.stdout" >&2
    cat "$scratch/transaction.stderr" >&2
    latest_log="$(find "$fixture_baby_step/logs" -maxdepth 1 -type f -name 'backup-*.log' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
    if [ -n "$latest_log" ]; then sed -n '1,220p' "$latest_log" >&2; fi
    printf 'Confirmed disposable backup transaction failed with status %s\n' "$transaction_status" >&2
    exit 1
fi
grep -Fq 'SUCCESS: Important configuration was copied to the Git backup.' \
    "$scratch/transaction.stdout"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before_transaction"
test "$(cat "$fixture_repo/dotfiles/.hermes/agy_bridge.py")" = 'fixture Hermes helper'
test "$(sha256sum "$fixture_nixos/flake.nix" | awk '{print $1}')" = \
    "$(sha256sum "$fixture_repo/nixos/flake.nix" | awk '{print $1}')"
cmp -s "$baby_step_dir/lib/source-validation.sh" \
    "$fixture_repo/baby-step/lib/source-validation.sh"
cmp -s "$baby_step_dir/lib/destination-safety.sh" \
    "$fixture_repo/baby-step/lib/destination-safety.sh"
cmp -s "$baby_step_dir/required-build-inputs.json" \
    "$fixture_repo/baby-step/required-build-inputs.json"
test -f "$fixture_repo/baby-step/tests/backup-production-integration-test.sh"
test -f "$fixture_repo/baby-step/tests/backup-destination-safety-test.sh"
cmp -s "$fixture_nixos/desktop/hyprland/hyprland.lua" \
    "$fixture_repo/dotfiles/.config/hypr/hyprland.lua"
test "$(cat "$fixture_home/.config/hypr/hyprland.lua")" = 'fixture hyprland config'
printf 'Prepared Hyprland Lua matches declared source; personal live copy unchanged: PASS\n'
# Generated/private state is removed only from the prepared copy. Live links,
# their outside target, and reusable settings must remain byte-for-byte intact.
prepared_runtime="$fixture_repo/dotfiles/.config/theme-profiles/fixture/noctalia-state"
test ! -e "$prepared_runtime/clipboard"
test ! -L "$prepared_runtime/clipboard"
test ! -e "$prepared_runtime/.catalog"
test ! -e "$prepared_runtime/.noctalia-cache.json"
cmp -s "$runtime_fixture/settings.toml" "$prepared_runtime/settings.toml"
test -L "$runtime_fixture/clipboard"
test -f "$runtime_fixture/.catalog/generated.json"
test -f "$runtime_fixture/.noctalia-cache.json"
test "$(cat "$outside_clipboard/sentinel")" = 'private fixture sentinel'
cmp -s "$baby_step_dir/lib/publication-check.py" "$fixture_repo/baby-step/lib/publication-check.py"
printf 'Prepared runtime exclusions preserve live clipboard target and source settings: PASS\n'
rollback_root="$(sed -n 's/^Previous repository copies are recoverable from: //p' \
    "$scratch/transaction.stdout")"
test -n "$rollback_root"
test "$(cat "$rollback_root/dotfiles/.hermes/agy_bridge.py")" = 'preserve this backup target'
test "$(sha256sum \
    "$fixture_baby_step/backups/hardware-configuration.previous.nix" | awk '{print $1}')" = "$hardware_before"
test -z "$(git -C "$fixture_repo" diff --cached --name-only)"
printf 'Confirmed disposable backup transaction replaced fixture trees, preserved rollback copy, left index unstaged: PASS\n'

# Make a harmless fixture-only edit, commit the first tree, then force the
# second tree's original rename to fail. Cleanup must restore the first tree.
printf 'synthetic post-snapshot work\n' > "$fixture_repo/nixos/review-dirty-sentinel"
repo_tree_before_rollback="$(tree_digest "$fixture_repo")"
git_status_before_rollback="$(git -C "$fixture_repo" status --porcelain=v1 -z | sha256sum | awk '{print $1}')"
index_before_rollback="$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')"
rollback_mv_bin="$scratch/rollback-mv-bin"
mkdir -m 0700 "$rollback_mv_bin"
real_mv="$(command -v mv)"
cat > "$rollback_mv_bin/mv" <<'MVFAILSECOND'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$AUDIT_MV_TRACE"
printf '\n' >> "$AUDIT_MV_TRACE"
if [ "${1:-}" = -- ] &&
   [ "${2:-}" = "$BACKUP_REPO/dotfiles/.config" ] &&
   [[ "${3:-}" == "$BABY_STEP_DIR"/backups/repository-previous.*/dotfiles/.config ]]; then
    printf 'injected second-tree original rename failure\n' >&2
    exit 76
fi
exec "$AUDIT_REAL_MV" "$@"
MVFAILSECOND
chmod 755 "$rollback_mv_bin/mv"
if printf 'SNAPSHOT\n' | env HOME="$fixture_home" \
    BABY_STEP_DIR="$fixture_baby_step" \
    BACKUP_REPO="$fixture_repo" \
    NIXOS_DIR="$fixture_nixos" \
    AUDIT_REAL_MV="$real_mv" \
    AUDIT_MV_TRACE="$scratch/rollback-mv.trace" \
    PATH="$rollback_mv_bin:$stub_bin:$PATH" \
    "$backup_script" > "$scratch/rollback.stdout" 2> "$scratch/rollback.stderr"; then
    printf 'Injected second-tree rename failure unexpectedly succeeded\n' >&2
    exit 1
else
    rollback_status=$?
fi
test "$rollback_status" -ne 0
grep -Fq 'injected second-tree original rename failure' "$scratch/rollback.stderr"
grep -Fq 'Could not replace the repository user configuration snapshot' \
    "$scratch/rollback.stderr"
grep -Fq "$fixture_repo/nixos" "$scratch/rollback-mv.trace"
test "$(tree_digest "$fixture_repo")" = "$repo_tree_before_rollback"
test "$(git -C "$fixture_repo" status --porcelain=v1 -z | sha256sum | awk '{print $1}')" = \
    "$git_status_before_rollback"
test "$(sha256sum "$fixture_repo/.git/index" | awk '{print $1}')" = "$index_before_rollback"
test "$(cat "$fixture_repo/nixos/review-dirty-sentinel")" = 'synthetic post-snapshot work'
if [ -L "$fixture_repo/nixos" ] || [ -L "$fixture_repo/dotfiles/.config" ]; then
    printf 'Rollback changed fixture destination types\n' >&2
    exit 1
fi
printf 'Second-tree rename failure restores the first tree exactly and preserves index/status: PASS\n'
