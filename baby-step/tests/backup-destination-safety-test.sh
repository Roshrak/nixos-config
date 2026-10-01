#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$script_dir/lib/destination-safety.sh"
scratch="$(mktemp -d /tmp/backup-destination-safety-test.XXXXXXXX)"
chmod 0700 "$scratch"
cleanup() {
    case "$scratch" in
        /tmp/backup-destination-safety-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected fixture cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

repo="$scratch/repository"
outside="$scratch/outside"
mkdir -p "$repo/dotfiles" "$outside/bin"
printf 'outside sentinel\n' > "$outside/bin/sentinel"
before="$(sha256sum "$outside/bin/sentinel" | awk '{print $1}')"
ln -s "$outside" "$repo/dotfiles/.local"
for path in "$repo/dotfiles/.local/bin"; do
    if backup_validate_destination "$repo" "$path" directory; then
        printf 'unsafe destination accepted: %s\n' "$path" >&2
        exit 1
    fi
done
if backup_validate_path "$repo/../outside" directory 0; then
    printf 'non-normalized repository root accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$outside/bin/sentinel" | awk '{print $1}')" = "$before"

rm -- "$repo/dotfiles/.local"
mkdir -p "$repo/dotfiles/.local/bin" "$repo/nixos"
printf 'original link target\n' > "$scratch/link-target"
ln -s "$scratch/link-target.missing" "$repo/dotfiles/dangling"
if backup_validate_destination "$repo" "$repo/dotfiles/dangling" file; then
    printf 'dangling link accepted as a file destination\n' >&2
    exit 1
fi
test -L "$repo/dotfiles/dangling"
test "$(readlink "$repo/dotfiles/dangling")" = "$scratch/link-target.missing"
backup_validate_destination "$repo" "$repo/dotfiles/.local/bin" directory
backup_validate_destination "$repo" "$repo/nixos" directory
backup_validate_destination "$repo" "$repo/missing/child" directory

# A newline in a component must not make the here-string path parser validate
# only a safe prefix while later filesystem calls use a symlinked real path.
printf 'safe truncated prefix\n' > "$scratch/safe"
newline_link="$scratch/"$'safe\nlinked'
ln -s "$outside/bin" "$newline_link"
malformed_path="$newline_link/sentinel"
if backup_validate_path "$malformed_path" file 1; then
    printf 'newline-containing symlink path accepted\n' >&2
    exit 1
fi
test -L "$newline_link"
test "$(sha256sum "$outside/bin/sentinel" | awk '{print $1}')" = "$before"

printf 'non-directory ancestor\n' > "$repo/not-a-directory"
if backup_validate_path "$repo/not-a-directory/child" directory 1; then
    printf 'non-directory ancestor accepted\n' >&2
    exit 1
fi
printf 'Normalized paths, path type, missing suffix, ancestor and dangling-link checks: PASS\n'

recovery="$scratch/recovery"
mkdir -m 0700 "$recovery"
backup_validate_private_directory "$recovery"
printf 'retained earlier recovery entry\n' > "$recovery/previous"
backup_validate_private_directory "$recovery"
if [ "$(stat -c '%a:%u:%g' "$recovery")" != "700:$(id -u):$(id -g)" ]; then
    printf 'recovery root mode/owner changed\n' >&2
    exit 1
fi
backup_validate_rename_filesystem "$repo/nixos" "$repo" "$recovery"
printf 'Private recovery identity and same-filesystem rename preconditions: PASS\n'

printf 'Backup destination safety helpers: PASS\n'
