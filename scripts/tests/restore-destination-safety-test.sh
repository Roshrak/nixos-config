#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_helper="$repo_root/scripts/lib/custom-service-restore.sh"
scratch="$(mktemp -d /tmp/restore-destination-safety-test.XXXXXXXX)"
chmod 0700 "$scratch"
cleanup() {
    case "$scratch" in
        /tmp/restore-destination-safety-test.*)
            rm -rf -- "$scratch"
            ;;
        *) printf 'Refusing unexpected fixture cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT
uid="$(id -u)"
gid="$(id -g)"

make_fixture() {
    local root="$1" repo="$1/repository" dotfiles="$1/repository/dotfiles"
    mkdir -p "$repo/scripts/lib" "$repo/baby-step" \
        "$dotfiles/.hermes" "$dotfiles/.local/bin" \
        "$dotfiles/.config/systemd/user" "$dotfiles/.config/other"
    cp -- "$source_helper" "$repo/scripts/lib/custom-service-restore.sh"
    cp -- "$repo_root/baby-step/custom-service-manifest.tsv" \
        "$repo/baby-step/custom-service-manifest.tsv"
    cp -- "$repo_root/dotfiles/.hermes/agy_bridge.py" "$dotfiles/.hermes/agy_bridge.py"
    cp -- "$repo_root/dotfiles/.local/bin/mc_chat_responder.py" "$dotfiles/.local/bin/mc_chat_responder.py"
    cp -- "$repo_root/dotfiles/.config/systemd/user/agy-bridge.service" \
        "$dotfiles/.config/systemd/user/agy-bridge.service"
    cp -- "$repo_root/dotfiles/.config/systemd/user/mc-chat-responder.service" \
        "$dotfiles/.config/systemd/user/mc-chat-responder.service"
    printf 'selected config\n' > "$dotfiles/.config/other/config"
    printf 'selected bootstrap helper\n' > "$repo/baby-step/helper.sh"
    chmod 0755 "$repo/scripts/lib/custom-service-restore.sh"
}

run_stage() {
    local repo="$1" home="$2" backup="$3" list_dir="${4:-}"
    . "$repo/scripts/lib/custom-service-restore.sh"
    run_root() { "$@"; }
    if [ -n "$list_dir" ]; then CUSTOM_RESTORE_PREFLIGHT_DIR="$list_dir"; fi
    deploy_selected_user_configuration "$repo" "$home" "$backup" "$uid" "$gid" \
        "$repo/baby-step/custom-service-manifest.tsv"
}

# A .config ancestor link must be rejected before the helper, .local, or any
# user configuration is installed.
root="$scratch/ancestor-link"
make_fixture "$root"
repo="$root/repository"
home="$root/target/home/aesc"
outside="$root/outside-config"
mkdir -p "$home/.hermes" "$outside"
chmod 0700 "$home" "$home/.hermes"
printf 'private outside sentinel\n' > "$outside/sentinel"
before="$(sha256sum "$outside/sentinel" | awk '{print $1}')"
ln -s "$outside" "$home/.config"
if run_stage "$repo" "$home" "$root/recovery" > "$root/out.stdout" 2> "$root/out.stderr"; then
    printf 'linked .config ancestor was accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$outside/sentinel" | awk '{print $1}')" = "$before"
test ! -e "$outside/systemd"
test ! -e "$home/.local"
test ! -e "$home/.hermes/agy_bridge.py"
printf 'Ancestor symlink is rejected before target or sibling writes: PASS\n'

# Repeat confinement checks for other mapped parents and recovery roots.
for linked_parent in .local baby-step; do
    root="$scratch/ancestor-$linked_parent"
    make_fixture "$root"
    repo="$root/repository"
    home="$root/target/home/aesc"
    outside="$root/outside"
    mkdir -p "$home/.hermes" "$outside"
    chmod 0700 "$home" "$home/.hermes"
    printf 'outside sentinel\n' > "$outside/sentinel"
    before="$(sha256sum "$outside/sentinel" | awk '{print $1}')"
    ln -s "$outside" "$home/$linked_parent"
    if run_stage "$repo" "$home" "$root/recovery" > "$root/out.stdout" 2> "$root/out.stderr"; then
        printf 'linked %s parent was accepted\n' "$linked_parent" >&2
        exit 1
    fi
    test "$(sha256sum "$outside/sentinel" | awk '{print $1}')" = "$before"
    test ! -e "$outside/helper.sh"
    test ! -e "$outside/bin"
done
printf 'Linked .local and baby-step destinations are rejected without sibling writes: PASS\n'

root="$scratch/recovery-link"
make_fixture "$root"
repo="$root/repository"
home="$root/target/home/aesc"
outside="$root/outside-recovery"
mkdir -p "$home/.hermes" "$outside"
chmod 0700 "$home" "$home/.hermes"
printf 'recovery sentinel\n' > "$outside/sentinel"
before="$(sha256sum "$outside/sentinel" | awk '{print $1}')"
mkdir -p "$root/target/var/backups"
ln -s "$outside" "$root/target/var/backups/bootstrap"
if run_stage "$repo" "$home" "$root/target/var/backups/bootstrap/custom" \
    > "$root/out.stdout" 2> "$root/out.stderr"; then
    printf 'linked recovery ancestor was accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$outside/sentinel" | awk '{print $1}')" = "$before"
test ! -e "$home/.hermes/agy_bridge.py"
printf 'Linked recovery destination is rejected before restore: PASS\n'

# A failed/partial find producer must fail closed before creating target files.
root="$scratch/find-failure"
make_fixture "$root"
repo="$root/repository"
home="$root/target/home/aesc"
mkdir -p "$home/.hermes" "$root/bin"
chmod 0700 "$home" "$home/.hermes"
cat > "$root/bin/find" <<'STUB'
#!/usr/bin/env bash
printf 'partial-name\0'
exit 77
STUB
chmod 0700 "$root/bin/find"
old_path="$PATH"
PATH="$root/bin:$PATH"
export PATH
if run_stage "$repo" "$home" "$root/recovery" > "$root/out.stdout" 2> "$root/out.stderr"; then
    printf 'partial source enumeration was accepted\n' >&2
    exit 1
fi
PATH="$old_path"
export PATH
test ! -e "$home/.hermes/agy_bridge.py"
test ! -e "$home/.local"
printf 'Partial source enumeration failure is observed before deployment: PASS\n'

# An unchanged existing home retains its mode/owner; a newly created home is
# private. Test each case against a fresh isolated target.
for home_mode in 700 750 755; do
    root="$scratch/home-$home_mode"
    make_fixture "$root"
    repo="$root/repository"
    home="$root/target/home/aesc"
    mkdir -p "$home"
    chmod "$home_mode" "$home"
    before="$(stat -c '%a:%u:%g' "$home")"
    run_stage "$repo" "$home" "$root/recovery" > "$root/out.stdout" 2> "$root/out.stderr"
    test "$(stat -c '%a:%u:%g' "$home")" = "$before"
done
root="$scratch/new-home"
make_fixture "$root"
repo="$root/repository"
home="$root/target/home/aesc"
mkdir -p "$(dirname -- "$home")"
run_stage "$repo" "$home" "$root/recovery" > "$root/out.stdout" 2> "$root/out.stderr"
test "$(stat -c '%a:%u:%g' "$home")" = "700:$uid:$gid"
printf 'Existing home modes are preserved and new home remains 0700: PASS\n'

# Reuse an early preflight record and prove that a later source edit is caught
# before the target receives any files.
root="$scratch/source-change"
make_fixture "$root"
repo="$root/repository"
home="$root/target/home/aesc"
mkdir -p "$home" "$root/preflight"
chmod 0700 "$home" "$root/preflight"
. "$repo/scripts/lib/custom-service-restore.sh"
run_root() { "$@"; }
CUSTOM_RESTORE_PREFLIGHT_DIR="$root/preflight"
preflight_selected_user_configuration "$repo" "$home" "$root/recovery" \
    "$uid" "$gid" "$repo/baby-step/custom-service-manifest.tsv"
printf 'changed after preflight\n' >> "$repo/dotfiles/.config/other/config"
if deploy_selected_user_configuration "$repo" "$home" "$root/recovery" \
    "$uid" "$gid" "$repo/baby-step/custom-service-manifest.tsv" \
    > "$root/out.stdout" 2> "$root/out.stderr"; then
    printf 'changed source tree was accepted after preflight\n' >&2
    exit 1
fi
test ! -e "$home/.hermes/agy_bridge.py"
test ! -e "$home/.local"
printf 'Changed selected source tree is rejected before deployment: PASS\n'

printf 'Selected-user destination safety suite: PASS\n'
