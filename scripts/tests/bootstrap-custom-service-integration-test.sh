#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d /tmp/bootstrap-custom-service-integration-test.XXXXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/bootstrap-custom-service-integration-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT
chmod 700 "$scratch"

source_repo=/home/aesc/nixos-config
test_script="$source_repo/scripts/tests/bootstrap-custom-service-integration-test.sh"
fixture_repo="$scratch/repository"
fixture_target="$scratch/target"
fixture_home="$fixture_target/home/aesc"
uid="$(id -u)"
gid="$(id -g)"

make_fixture_repo() {
    local destination="$1"
    mkdir -p "$destination/scripts/lib" "$destination/scripts/tests" \
        "$destination/nixos" "$destination/dotfiles/.hermes" \
        "$destination/dotfiles/.local/bin" \
        "$destination/dotfiles/.config/systemd/user" \
        "$destination/baby-step"
    cp -a --no-preserve=ownership "$source_repo/nixos/." "$destination/nixos/"
    cp -- "$source_repo/scripts/bootstrap-nixos.sh" "$destination/scripts/bootstrap-nixos.sh"
    cp -- "$source_repo/scripts/lib/custom-service-restore.sh" \
        "$destination/scripts/lib/custom-service-restore.sh"
    cp -- "$source_repo/baby-step/custom-service-manifest.tsv" \
        "$destination/baby-step/custom-service-manifest.tsv"
    cp -- "$source_repo/dotfiles/.hermes/agy_bridge.py" \
        "$destination/dotfiles/.hermes/agy_bridge.py"
    cp -- "$source_repo/dotfiles/.local/bin/mc_chat_responder.py" \
        "$destination/dotfiles/.local/bin/mc_chat_responder.py"
    cp -- "$source_repo/dotfiles/.config/systemd/user/agy-bridge.service" \
        "$destination/dotfiles/.config/systemd/user/agy-bridge.service"
    cp -- "$source_repo/dotfiles/.config/systemd/user/mc-chat-responder.service" \
        "$destination/dotfiles/.config/systemd/user/mc-chat-responder.service"
    chmod 755 "$destination/scripts/bootstrap-nixos.sh"
    chmod 644 "$destination/scripts/lib/custom-service-restore.sh"
}

make_fixture_repo "$fixture_repo"
printf 'fixture secret; must not be copied\n' > "$fixture_repo/dotfiles/.hermes/.env"
printf 'fixture token; must not be copied\n' > "$fixture_repo/dotfiles/.hermes/auth.json"
mkdir -p "$fixture_repo/dotfiles/.hermes/cache"
printf 'fixture cache; must not be copied\n' > "$fixture_repo/dotfiles/.hermes/cache/sentinel"

. "$fixture_repo/scripts/lib/custom-service-restore.sh"
CUSTOM_RESTORE_INJECT=none
CUSTOM_RESTORE_DEST=""
CUSTOM_RESTORE_HOME=""
CUSTOM_RESTORE_SOURCE="$fixture_repo/dotfiles/.hermes/agy_bridge.py"
run_root() {
    if [ "$CUSTOM_RESTORE_INJECT" = rollback-copy ] &&
       [ "${1:-}" = mv ] && [ "${2:-}" = -T ] &&
       [ "${5:-}" = "$CUSTOM_RESTORE_DEST" ]; then
        "$@" || return $?
        CUSTOM_RESTORE_INJECT=rollback-copy-failed
        return 0
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = rollback-copy-failed ] &&
       [ "${1:-}" = cp ] && [[ "${4:-}" == */hermes-bridge/previous ]]; then
        CUSTOM_RESTORE_INJECT=none
        return 79
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = rename ] && [ "${1:-}" = mv ] &&
       [ "${2:-}" = -T ] && [ "${5:-}" = "$CUSTOM_RESTORE_DEST" ]; then
        CUSTOM_RESTORE_INJECT=none
        return 71
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = rename-after-move ] && [ "${1:-}" = mv ] &&
       [ "${2:-}" = -T ] && [ "${5:-}" = "$CUSTOM_RESTORE_DEST" ]; then
        "$@" || return $?
        CUSTOM_RESTORE_INJECT=none
        return 74
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = install ] && [ "${1:-}" = install ] &&
       [ "${2:-}" = -m ] && [ "${3:-}" = 0644 ] &&
       [[ "${6:-}" == "$CUSTOM_RESTORE_HOME/.hermes/.agy_bridge.py.bootstrap."* ]]; then
        CUSTOM_RESTORE_INJECT=none
        return 72
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = source-change ] && [ "${1:-}" = install ] &&
       [ "${2:-}" = -m ] && [ "${3:-}" = 0644 ] &&
       [ "${5:-}" = "$CUSTOM_RESTORE_SOURCE" ] &&
       [[ "${6:-}" == "$CUSTOM_RESTORE_HOME/.hermes/.agy_bridge.py.bootstrap."* ]]; then
        "$@" || return $?
        printf '\n# source changed during fixture failure injection\n' >> "$CUSTOM_RESTORE_SOURCE"
        CUSTOM_RESTORE_INJECT=none
        return 0
    fi
    if [ "$CUSTOM_RESTORE_INJECT" = chown ] && [ "${1:-}" = chown ] &&
       [[ "${3:-}" == "$CUSTOM_RESTORE_HOME/.hermes/.agy_bridge.py.bootstrap."* ]]; then
        CUSTOM_RESTORE_INJECT=none
        return 73
    fi
    "$@"
}

# The actual shared stage function replaces the missing consumer call in the
# real bootstrap. Use an existing target helper to prove exact rollback data.
mkdir -p "$fixture_home/.hermes"
chmod 700 "$fixture_home" "$fixture_home/.hermes"
printf 'old target helper\n' > "$fixture_home/.hermes/agy_bridge.py"
chmod 600 "$fixture_home/.hermes/agy_bridge.py"
old_hash="$(sha256sum "$fixture_home/.hermes/agy_bridge.py" | awk '{print $1}')"
old_metadata="$(stat -c '%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")"
printf 'target secret remains\n' > "$fixture_home/.hermes/.env"
target_secret_hash="$(sha256sum "$fixture_home/.hermes/.env" | awk '{print $1}')"
backup_base="$fixture_target/var/backups/bootstrap-stage-fixture"
deploy_selected_user_configuration "$fixture_repo" "$fixture_home" \
    "$backup_base" "$uid" "$gid" \
    "$fixture_repo/baby-step/custom-service-manifest.tsv"

source_hash="$(sha256sum "$fixture_repo/dotfiles/.hermes/agy_bridge.py" | awk '{print $1}')"
test "$(sha256sum "$fixture_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$source_hash"
test "$(stat -c '%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")" = "644:$uid:$gid"
test "$(sha256sum "$fixture_home/.hermes/.env" | awk '{print $1}')" = "$target_secret_hash"
cmp -s "$fixture_repo/dotfiles/.config/systemd/user/agy-bridge.service" \
    "$fixture_home/.config/systemd/user/agy-bridge.service"
recovery="$backup_base/custom-services/hermes-bridge"
test "$(sha256sum "$recovery/previous" | awk '{print $1}')" = "$old_hash"
test "$(stat -c '%a:%u:%g' "$recovery/previous")" = "$old_metadata"
grep -Fxq 'present=1' "$recovery/prior-state.txt"
grep -Fxq "sha256=$old_hash" "$recovery/prior-state.txt"
test ! -e "$fixture_home/.hermes/auth.json"
test ! -e "$fixture_home/.hermes/cache"
test -z "$(find "$fixture_home/.hermes" -maxdepth 1 -type f -name '.agy_bridge.py.*' -print -quit)"
helper_state_before_repeat="$(stat -c '%i:%Y:%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")"
restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$fixture_home" "$scratch/noop-recovery" \
    "$uid" "$gid" > /dev/null
test "$(stat -c '%i:%Y:%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")" = \
    "$helper_state_before_repeat"
test ! -e "$scratch/noop-recovery"
rollback_hermes_bridge "$backup_base/custom-services" "$fixture_home" "$uid" "$gid"
test "$(sha256sum "$fixture_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$old_hash"
test "$(stat -c '%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")" = "$old_metadata"
grep -Fxq 'rolled-back=1' "$recovery/rolled-back"
printf 'Shared production stage restores helper and unit, records prior bytes, preserves secrets: PASS\n'
printf 'Explicit transaction rollback restores prior helper bytes and metadata: PASS\n'

absence_dir_home="$scratch/absence-with-dir-home"
mkdir -p "$absence_dir_home/.hermes"
chown "$uid:$gid" "$absence_dir_home" "$absence_dir_home/.hermes"
chmod 710 "$absence_dir_home/.hermes"
absence_dir_metadata="$(stat -c '%a:%u:%g' "$absence_dir_home/.hermes")"
restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$absence_dir_home" "$scratch/absence-dir-recovery" \
    "$uid" "$gid" > /dev/null
rollback_hermes_bridge "$scratch/absence-dir-recovery" "$absence_dir_home" "$uid" "$gid" > /dev/null
test ! -e "$absence_dir_home/.hermes/agy_bridge.py"
test "$(stat -c '%a:%u:%g' "$absence_dir_home/.hermes")" = "$absence_dir_metadata"

absence_home="$scratch/absence-home"
mkdir -p "$absence_home"
chown "$uid:$gid" "$absence_home"
restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$absence_home" "$scratch/absence-recovery" \
    "$uid" "$gid" > /dev/null
rollback_hermes_bridge "$scratch/absence-recovery" "$absence_home" "$uid" "$gid" > /dev/null
test ! -e "$absence_home/.hermes"
printf 'Explicit rollback restores prior helper absence and directory metadata: PASS\n'

# Failure before the atomic rename leaves an originally absent helper absent.
failure_home="$scratch/failure-home"
mkdir -p "$failure_home"
chown "$uid:$gid" "$failure_home"
CUSTOM_RESTORE_HOME="$failure_home"
CUSTOM_RESTORE_DEST="$failure_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=rename
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$failure_home" "$scratch/failure-recovery" \
    "$uid" "$gid" > "$scratch/rename.out" 2> "$scratch/rename.err"; then
    printf 'Injected atomic rename failure was ignored\n' >&2
    exit 1
fi
test ! -e "$failure_home/.hermes/agy_bridge.py"
test ! -e "$failure_home/.hermes"
printf 'Injected rename failure rolls back to original absence: PASS\n'

# A wrapper can report failure after the filesystem rename already happened.
# The helper must detect the staged inode at the destination and restore the
# saved before-image, rather than assuming that a nonzero status means no move.
rename_after_home="$scratch/rename-after-move-home"
mkdir -p "$rename_after_home/.hermes"
chown "$uid:$gid" "$rename_after_home" "$rename_after_home/.hermes"
printf 'preserve after a reported rename failure\n' > "$rename_after_home/.hermes/agy_bridge.py"
chmod 640 "$rename_after_home/.hermes/agy_bridge.py"
rename_after_hash="$(sha256sum "$rename_after_home/.hermes/agy_bridge.py" | awk '{print $1}')"
rename_after_metadata="$(stat -c '%a:%u:%g' "$rename_after_home/.hermes/agy_bridge.py")"
CUSTOM_RESTORE_HOME="$rename_after_home"
CUSTOM_RESTORE_DEST="$rename_after_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=rename-after-move
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$rename_after_home" "$scratch/rename-after-move-recovery" \
    "$uid" "$gid" > "$scratch/rename-after-move.out" \
    2> "$scratch/rename-after-move.err"; then
    printf 'Reported rename failure after publication was accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$rename_after_home/.hermes/agy_bridge.py" | awk '{print $1}')" = \
    "$rename_after_hash"
test "$(stat -c '%a:%u:%g' "$rename_after_home/.hermes/agy_bridge.py")" = \
    "$rename_after_metadata"
test "$(sha256sum "$scratch/rename-after-move-recovery/hermes-bridge/previous" | awk '{print $1}')" = \
    "$rename_after_hash"
test -z "$(find "$rename_after_home/.hermes" -maxdepth 1 -type f -name '.agy_bridge.py.*' -print -quit)"
printf 'Reported post-rename failure is detected and exact helper before-image restored: PASS\n'

# Inject an install failure while replacing an existing helper.
install_home="$scratch/install-failure-home"
mkdir -p "$install_home/.hermes"
chown "$uid:$gid" "$install_home" "$install_home/.hermes"
printf 'keep exact old helper\n' > "$install_home/.hermes/agy_bridge.py"
chmod 640 "$install_home/.hermes/agy_bridge.py"
install_hash="$(sha256sum "$install_home/.hermes/agy_bridge.py" | awk '{print $1}')"
install_metadata="$(stat -c '%a:%u:%g' "$install_home/.hermes/agy_bridge.py")"
CUSTOM_RESTORE_HOME="$install_home"
CUSTOM_RESTORE_DEST="$install_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=install
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$install_home" "$scratch/install-recovery" \
    "$uid" "$gid" > "$scratch/install.out" 2> "$scratch/install.err"; then
    printf 'Injected helper install failure was ignored\n' >&2
    exit 1
fi
test "$(sha256sum "$install_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$install_hash"
test "$(stat -c '%a:%u:%g' "$install_home/.hermes/agy_bridge.py")" = "$install_metadata"
printf 'Injected copy failure preserves old helper bytes and metadata: PASS\n'

# Inject a chown failure after staging, again preserving the old destination.
chown_home="$scratch/chown-failure-home"
mkdir -p "$chown_home/.hermes"
chown "$uid:$gid" "$chown_home" "$chown_home/.hermes"
printf 'keep after chown failure\n' > "$chown_home/.hermes/agy_bridge.py"
chmod 600 "$chown_home/.hermes/agy_bridge.py"
chown_hash="$(sha256sum "$chown_home/.hermes/agy_bridge.py" | awk '{print $1}')"
CUSTOM_RESTORE_HOME="$chown_home"
CUSTOM_RESTORE_DEST="$chown_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=chown
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$chown_home" "$scratch/chown-recovery" \
    "$uid" "$gid" > "$scratch/chown.out" 2> "$scratch/chown.err"; then
    printf 'Injected helper chown failure was ignored\n' >&2
    exit 1
fi
test "$(sha256sum "$chown_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$chown_hash"
test "$(stat -c '%a:%u:%g' "$chown_home/.hermes/agy_bridge.py")" = "600:$uid:$gid"
printf 'Injected ownership failure preserves old helper bytes and metadata: PASS\n'

# A source mutation after staging but before commit is caught by the immediate
# source hash recheck and restores the old destination.
source_home="$scratch/source-change-home"
mkdir -p "$source_home/.hermes"
chown "$uid:$gid" "$source_home" "$source_home/.hermes"
printf 'old bytes survive source change\n' > "$source_home/.hermes/agy_bridge.py"
chmod 640 "$source_home/.hermes/agy_bridge.py"
source_change_hash="$(sha256sum "$source_home/.hermes/agy_bridge.py" | awk '{print $1}')"
source_copy="$scratch/source-before-injection.py"
cp -p "$CUSTOM_RESTORE_SOURCE" "$source_copy"
CUSTOM_RESTORE_HOME="$source_home"
CUSTOM_RESTORE_DEST="$source_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=source-change
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$source_home" "$scratch/source-change-recovery" \
    "$uid" "$gid" > "$scratch/source-change.out" 2> "$scratch/source-change.err"; then
    printf 'Source change between staging and commit was accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$source_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$source_change_hash"
cp -- "$source_copy" "$CUSTOM_RESTORE_SOURCE"
chmod 755 "$CUSTOM_RESTORE_SOURCE"
printf 'Source change during staging is rejected and old helper remains exact: PASS\n'

# Compound a post-commit verification failure with a failed recovery copy.
# The old helper must remain in the recovery journal, and the failed staging
# copy must never be renamed over either the previous or committed helper.
rollback_failure_home="$scratch/rollback-copy-home"
rollback_failure_recovery="$scratch/rollback-copy-recovery"
mkdir -p "$rollback_failure_home/.hermes"
chmod 700 "$rollback_failure_home" "$rollback_failure_home/.hermes"
printf 'previous rollback helper\n' > "$rollback_failure_home/.hermes/agy_bridge.py"
chmod 600 "$rollback_failure_home/.hermes/agy_bridge.py"
rollback_previous_hash="$(sha256sum "$rollback_failure_home/.hermes/agy_bridge.py" | awk '{print $1}')"
CUSTOM_RESTORE_HOME="$rollback_failure_home"
CUSTOM_RESTORE_DEST="$rollback_failure_home/.hermes/agy_bridge.py"
CUSTOM_RESTORE_INJECT=rollback-copy
stat() {
    if [ "$CUSTOM_RESTORE_INJECT" = rollback-copy-failed ] &&
       [ "${@: -1}" = "$CUSTOM_RESTORE_DEST" ]; then
        printf '000:%s:%s\n' "$uid" "$gid"
        return 0
    fi
    command stat "$@"
}
if restore_hermes_bridge "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    "$fixture_repo/dotfiles" "$rollback_failure_home" "$rollback_failure_recovery" \
    "$uid" "$gid" > "$scratch/rollback-copy.out" 2> "$scratch/rollback-copy.err"; then
    rollback_failure_status=0
else
    rollback_failure_status=$?
fi
test "$rollback_failure_status" -ne 0
test "$(sha256sum "$rollback_failure_recovery/hermes-bridge/previous" | awk '{print $1}')" = \
    "$rollback_previous_hash"
rollback_destination_hash="$(sha256sum "$rollback_failure_home/.hermes/agy_bridge.py" | awk '{print $1}')"
test "$rollback_destination_hash" = "$source_hash"
test "$rollback_destination_hash" != \
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
printf 'Failed recovery copy leaves committed helper intact and exact before-image recoverable: PASS\n'

# Reject unsafe target symlinks and unsupported/missing input before mutation.
unsafe_home="$scratch/unsafe-home"
outside="$scratch/outside-hermes"
mkdir -p "$unsafe_home" "$outside"
chown "$uid:$gid" "$unsafe_home"
printf 'outside sentinel\n' > "$outside/sentinel"
ln -s "$outside" "$unsafe_home/.hermes"
if preflight_custom_service_restore \
    "$fixture_repo/baby-step/custom-service-manifest.tsv" "$fixture_repo/dotfiles" \
    "$unsafe_home" "$uid" "$gid" > /dev/null 2>&1; then
    printf 'Symlinked target .hermes was accepted\n' >&2
    exit 1
fi
test "$(cat "$outside/sentinel")" = 'outside sentinel'
unsafe_config_home="$scratch/unsafe-config-home"
outside_config="$scratch/outside-config"
mkdir -p "$unsafe_config_home/.hermes" "$outside_config"
chmod 700 "$unsafe_config_home" "$unsafe_config_home/.hermes"
printf 'outside configuration sentinel\n' > "$outside_config/sentinel"
outside_config_hash="$(sha256sum "$outside_config/sentinel" | awk '{print $1}')"
ln -s "$outside_config" "$unsafe_config_home/.config"
if deploy_selected_user_configuration "$fixture_repo" "$unsafe_config_home" \
    "$scratch/unsafe-config-recovery" "$uid" "$gid" \
    "$fixture_repo/baby-step/custom-service-manifest.tsv" \
    > "$scratch/unsafe-config.out" 2> "$scratch/unsafe-config.err"; then
    printf 'Selected-user stage accepted a linked .config ancestor\n' >&2
    exit 1
fi
test "$(sha256sum "$outside_config/sentinel" | awk '{print $1}')" = "$outside_config_hash"
test ! -e "$outside_config/systemd"
test ! -e "$unsafe_config_home/.local"
printf 'Complete selected-user preflight rejects .config escape before target or sibling writes: PASS\n'

restore_safe_prefix="$scratch/restore-safe-prefix"
printf 'safe prefix\n' > "$restore_safe_prefix"
restore_newline_link="$scratch/"$'safe\nlinked'
ln -s "$outside_config" "$restore_newline_link"
if custom_restore_safe_path "$restore_newline_link/sentinel" 1; then
    printf 'Newline-containing restore path was accepted\n' >&2
    exit 1
fi
test "$(sha256sum "$outside_config/sentinel" | awk '{print $1}')" = "$outside_config_hash"
unsafe_recovery_base="$scratch/unsafe-recovery-base"
mkdir -m 0755 "$unsafe_recovery_base"
unsafe_recovery_metadata="$(stat -c '%a:%u:%g' "$unsafe_recovery_base")"
if custom_restore_validate_private_directory "$unsafe_recovery_base" "$uid" "$gid"; then
    printf 'Non-private recovery base was accepted\n' >&2
    exit 1
fi
test "$(stat -c '%a:%u:%g' "$unsafe_recovery_base")" = "$unsafe_recovery_metadata"
printf 'Restore path parser rejects newline aliases; unsafe recovery base is refused unchanged: PASS\n'

# Tree validation must inventory descendants without following links, accept
# only the repository's documented preserved links, and reject special files.
safe_obs_link="$fixture_repo/dotfiles/.local/bin/obs"
ln -s /home/aesc/.local/bin/obs-safe "$safe_obs_link"
custom_restore_validate_tree_types "$fixture_repo/dotfiles" source
rm -- "$safe_obs_link"
unapproved_link="$fixture_repo/dotfiles/.config/unapproved-link"
ln -s "$outside_config" "$unapproved_link"
if custom_restore_validate_tree_types "$fixture_repo/dotfiles" source \
    > "$scratch/unapproved-link.out" 2> "$scratch/unapproved-link.err"; then
    printf 'Nested unapproved source symlink was accepted\n' >&2
    exit 1
fi
grep -Fq "unapproved symlink: $unapproved_link" "$scratch/unapproved-link.err"
rm -- "$unapproved_link"
source_fifo="$fixture_repo/dotfiles/.config/source-fifo"
mkfifo "$source_fifo"
if custom_restore_validate_tree_types "$fixture_repo/dotfiles" source \
    > "$scratch/source-special.out" 2> "$scratch/source-special.err"; then
    printf 'Nested source special file was accepted\n' >&2
    exit 1
fi
grep -Fq "unsupported special file type 'p': $source_fifo" "$scratch/source-special.err"
rm -- "$source_fifo"
dest_tree="$scratch/destination-tree"
mkdir -p "$dest_tree"
ln -s "$outside_config" "$dest_tree/linked-subtree"
custom_restore_validate_tree_types "$dest_tree" destination
test "$(sha256sum "$outside_config/sentinel" | awk '{print $1}')" = "$outside_config_hash"
mkfifo "$dest_tree/destination-fifo"
if custom_restore_validate_tree_types "$dest_tree" destination \
    > "$scratch/destination-special.out" 2> "$scratch/destination-special.err"; then
    printf 'Nested destination special file was accepted\n' >&2
    exit 1
fi
grep -Fq "unsupported special file type 'p': $dest_tree/destination-fifo" \
    "$scratch/destination-special.err"
printf 'Nested links are inventoried without following; unapproved links and special files are refused: PASS\n'

for home_mode in 700 750 755; do
    mode_home="$scratch/home-mode-$home_mode"
    mkdir -p "$mode_home"
    chmod "$home_mode" "$mode_home"
    mode_before="$(stat -c '%a:%u:%g' "$mode_home")"
    deploy_selected_user_configuration "$fixture_repo" "$mode_home" \
        "$scratch/home-mode-recovery-$home_mode" "$uid" "$gid" \
        "$fixture_repo/baby-step/custom-service-manifest.tsv" \
        > "$scratch/home-mode-$home_mode.out" \
        2> "$scratch/home-mode-$home_mode.err"
    test "$(stat -c '%a:%u:%g' "$mode_home")" = "$mode_before"
done
printf 'Selected-user stage preserves existing home modes 0700, 0750, and 0755: PASS\n'
cp "$fixture_repo/baby-step/custom-service-manifest.tsv" "$scratch/bad-manifest.tsv"
printf '.hermes/agy_bridge.py\t/etc/passwd\tcode\n' > "$scratch/bad-manifest.tsv"
if preflight_custom_service_restore "$scratch/bad-manifest.tsv" \
    "$fixture_repo/dotfiles" "$scratch/empty-target/home/aesc" "$uid" "$gid" \
    > /dev/null 2>&1; then
    printf 'Unapproved custom-service mapping was accepted\n' >&2
    exit 1
fi
printf 'Unsafe target symlink and unapproved mapping rejected before mutation: PASS\n'

# Execute the actual bootstrap entry point with a disposable target root. No
# --build, --switch, or --install action is requested.
mkdir -p "$fixture_home/.hermes" "$fixture_target"
chmod 0700 "$fixture_home"
whole_bootstrap_home_metadata="$(stat -c '%a:%u:%g' "$fixture_home")"
# The fixture initially includes unmistakably private source sentinels. Even
# with --no-user-config, the default whole-repository copy must refuse before
# making any change under the selected target root.
private_source_target="$scratch/private-source-target"
mkdir -p "$private_source_target"
set +e
"$fixture_repo/scripts/bootstrap-nixos.sh" \
    --target-root "$private_source_target" --host tonelico --no-user-config --yes \
    > "$scratch/private-source.stdout" 2> "$scratch/private-source.stderr"
private_source_status=$?
set -e
if [ "$private_source_status" -eq 0 ] ||
   ! grep -Fq 'unmanifested private Hermes data' "$scratch/private-source.stderr"; then
    cat "$scratch/private-source.stdout" >&2
    cat "$scratch/private-source.stderr" >&2
    printf 'Whole-repository copy accepted private Hermes fixture sentinels\n' >&2
    exit 1
fi
test -z "$(find "$private_source_target" -mindepth 1 -print -quit)"
rm -rf -- "$fixture_repo/dotfiles/.hermes/.env" \
    "$fixture_repo/dotfiles/.hermes/auth.json" "$fixture_repo/dotfiles/.hermes/cache"
printf 'Repository-copy preflight rejects private Hermes data before target-root writes, including --no-user-config: PASS\n'
bootstrap_output="$scratch/bootstrap.stdout"
bootstrap_error="$scratch/bootstrap.stderr"
set +e
"$fixture_repo/scripts/bootstrap-nixos.sh" \
    --target-root "$fixture_target" --host tonelico --yes \
    > "$bootstrap_output" 2> "$bootstrap_error"
bootstrap_status=$?
set -e
if [ "$bootstrap_status" -ne 0 ]; then
    cat "$bootstrap_output" >&2
    cat "$bootstrap_error" >&2
    printf 'Disposable bootstrap integration failed with status %s\n' "$bootstrap_status" >&2
    exit 1
fi
test "$(sha256sum "$fixture_home/.hermes/agy_bridge.py" | awk '{print $1}')" = "$source_hash"
test "$(stat -c '%a:%u:%g' "$fixture_home/.hermes/agy_bridge.py")" = "644:$uid:$gid"
cmp -s "$fixture_repo/dotfiles/.config/systemd/user/agy-bridge.service" \
    "$fixture_home/.config/systemd/user/agy-bridge.service"
test "$(sha256sum "$fixture_home/.hermes/.env" | awk '{print $1}')" = "$target_secret_hash"
test ! -e "$fixture_home/.hermes/auth.json"
test ! -e "$fixture_home/.hermes/cache"
test -f "$fixture_home/nixos-config/scripts/bootstrap-nixos.sh"
test "$(stat -c '%a:%u:%g' "$fixture_home")" = "$whole_bootstrap_home_metadata"
bootstrap_recovery_root="$fixture_target/var/backups/nixos-bootstrap"
bootstrap_recovery_base="$(find "$bootstrap_recovery_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -n "$bootstrap_recovery_base"
test "$(stat -c '%a:%u:%g' "$bootstrap_recovery_base")" = "700:$uid:$gid"
cmp -s "$fixture_repo/scripts/bootstrap-nixos.sh" \
    "$fixture_home/nixos-config/scripts/bootstrap-nixos.sh"
grep -Fq '[5/7] Deploying selected user configuration... OK' "$bootstrap_output"
grep -Fq 'Hermes service was not started.' "$bootstrap_output"
printf 'Whole bootstrap entry point restores only the declared helper and unit in fixture target: PASS\n'

# Mutate the candidate back to the obsolete three-argument call and prove the
# default target-root repository-copy path detects the shared helper arity
# mismatch. Only the disposable fixture source and target are changed.
bootstrap_script="$fixture_repo/scripts/bootstrap-nixos.sh"
bootstrap_saved="$scratch/bootstrap-before-arity-mutation.sh"
cp -p -- "$bootstrap_script" "$bootstrap_saved"
python3 - "$bootstrap_script" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
current = '''    backup_and_replace_entry "$REPO_ROOT" "$TARGET_REPOSITORY" \\
        "$BACKUP_BASE/user/nixos-config" "$HOST_UID" "$HOST_GID"
'''
mutated = '''    backup_and_replace_entry "$REPO_ROOT" "$TARGET_REPOSITORY" \\
        "$BACKUP_BASE/user/nixos-config"
'''
if source.count(current) != 1:
    raise SystemExit("expected exactly one corrected repository-copy call")
path.write_text(source.replace(current, mutated, 1))
PY
arity_target="$scratch/old-arity-target"
mkdir -p "$arity_target"
set +e
"$bootstrap_script" --target-root "$arity_target" --host tonelico --yes \
    > "$scratch/old-arity.stdout" 2> "$scratch/old-arity.stderr"
arity_status=$?
set -e
cp -p -- "$bootstrap_saved" "$bootstrap_script"
if [ "$arity_status" -eq 0 ] ||
   ! grep -Fq 'usage: backup_and_replace_entry SOURCE DESTINATION BACKUP UID GID' \
       "$scratch/old-arity.stderr"; then
    cat "$scratch/old-arity.stdout" >&2
    cat "$scratch/old-arity.stderr" >&2
    printf 'Old repository-copy arity mutation was not detected by the actual bootstrap path\n' >&2
    exit 1
fi
printf 'Actual bootstrap detects the obsolete repository-copy argument count in a disposable target: PASS\n'

# Confirm preflight rejects the two required inputs before any target-root
# file is created. Each source is temporarily removed only inside the fixture.
for missing_input in helper unit; do
    case "$missing_input" in
        helper) source_input="$fixture_repo/dotfiles/.hermes/agy_bridge.py" ;;
        unit) source_input="$fixture_repo/dotfiles/.config/systemd/user/agy-bridge.service" ;;
    esac
    saved_input="$scratch/saved-$missing_input"
    mv -- "$source_input" "$saved_input"
    preflight_target="$scratch/preflight-target-$missing_input"
    mkdir -p "$preflight_target"
    set +e
    "$fixture_repo/scripts/bootstrap-nixos.sh" \
        --target-root "$preflight_target" --host tonelico --no-copy-repository --yes \
        > "$scratch/preflight-$missing_input.stdout" \
        2> "$scratch/preflight-$missing_input.stderr"
    preflight_status=$?
    set -e
    mv -- "$saved_input" "$source_input"
    if [ "$preflight_status" -eq 0 ]; then
        printf 'Bootstrap accepted missing custom-service %s\n' "$missing_input" >&2
        exit 1
    fi
    test -z "$(find "$preflight_target" -mindepth 1 -print -quit)"
done
printf 'Whole bootstrap preflight rejects missing helper/unit before target-root writes: PASS\n'

skip_target="$scratch/skip-user-config-target"
mkdir -p "$skip_target"
set +e
"$fixture_repo/scripts/bootstrap-nixos.sh" \
    --target-root "$skip_target" --host tonelico --no-user-config \
    --no-copy-repository --yes > "$scratch/skip-user-config.stdout" \
    2> "$scratch/skip-user-config.stderr"
skip_status=$?
set -e
if [ "$skip_status" -ne 0 ]; then
    cat "$scratch/skip-user-config.stdout" >&2
    cat "$scratch/skip-user-config.stderr" >&2
    printf 'No-user-config bootstrap fixture failed with status %s\n' "$skip_status" >&2
    exit 1
fi
grep -Fq 'Custom-service file restore preflight skipped by --no-user-config.' \
    "$scratch/skip-user-config.stdout"
grep -Fq '[5/7] Deploying selected user configuration... SKIPPED' \
    "$scratch/skip-user-config.stdout"
test ! -e "$skip_target/home/aesc/.hermes/agy_bridge.py"
printf '%s\n' '--no-user-config skips custom restore and does not claim service readiness: PASS'

# Reintroduce the reviewed omission in a disposable copy of the production
# library. The old behavior exits successfully and copies the unit, while the
# independent fixture assertion correctly detects the missing helper.
mutant_library="$scratch/mutant-custom-service-restore.sh"
python3 - "$fixture_repo/scripts/lib/custom-service-restore.sh" "$mutant_library" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
call = '''    restore_hermes_bridge "$manifest" "$dotfiles" "$target_home" \\
        "$backup_base/custom-services" "$target_uid" "$target_gid" || return 1
'''
if source.count(call) != 1:
    raise SystemExit("expected exactly one production restore call")
source = source.replace(call, "    : # mutation: emulate the historical missing restore call\n", 1)
start = source.find('    [ "$(sha256sum -- "$dotfiles/.hermes/agy_bridge.py"')
end = source.find('    cmp -s -- "$dotfiles/.config/systemd/user/agy-bridge.service"', start)
if start < 0 or end < 0:
    raise SystemExit("could not locate the production post-copy assertion")
source = source[:start] + source[end:]
Path(sys.argv[2]).write_text(source)
PY
mutant_home="$scratch/mutant-home"
mkdir -p "$mutant_home"
chown "$uid:$gid" "$mutant_home"
set +e
(
    . "$mutant_library"
    run_root() { "$@"; }
    deploy_selected_user_configuration "$fixture_repo" "$mutant_home" \
        "$scratch/mutant-backups" "$uid" "$gid" \
        "$fixture_repo/baby-step/custom-service-manifest.tsv"
) > "$scratch/mutant.stdout" 2> "$scratch/mutant.stderr"
mutant_status=$?
set -e
if [ "$mutant_status" -ne 0 ]; then
    printf 'Historical-omission mutation did not reproduce its successful old behavior\n' >&2
    cat "$scratch/mutant.stderr" >&2
    exit 1
fi
test -f "$mutant_home/.config/systemd/user/agy-bridge.service"
test ! -e "$mutant_home/.hermes/agy_bridge.py"
printf 'Independent assertion detects the old omission even when the mutated stage exits 0: PASS\n'
