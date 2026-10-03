#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

check_only=0
resume_backup=0
backup_only=0
[ "$#" -le 1 ] || { printf 'ERROR: Use one option at a time.\n' >&2; exit 2; }
case "${1:-}" in
    "") ;;
    --check-only) check_only=1 ;;
    --resume-backup) resume_backup=1 ;;
    --backup-only) backup_only=1 ;;
    -h|--help)
        printf 'Safely update NixOS, snapshot configuration, commit, and push.\n'
        printf 'Run: %s\n' "$HOME/baby-step/update-and-push.sh"
        printf 'Safety checks only: %s --check-only\n' "$HOME/baby-step/update-and-push.sh"
        printf 'Resume backup after a successful update: %s --resume-backup\n' \
            "$HOME/baby-step/update-and-push.sh"
        printf 'Publish the already-active configuration without updates: %s --backup-only\n' \
            "$HOME/baby-step/update-and-push.sh"
        printf 'Use --resume-backup only when the previous run completed the system update.\n'
        exit 0
        ;;
    *)
        printf 'ERROR: Unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    printf 'ERROR: Run this as your normal user, not with sudo.\n' >&2
    exit 1
fi

start_log "update-and-push"
acquire_maintenance_lock
TOTAL=8
[ "$check_only" -eq 0 ] || TOTAL=4

show_banner 'NixOS update and GitHub backup' 'Preflight -> verify system -> snapshot -> review publication -> commit -> verify push'
printf 'Live progress will be shown below; full output is also saved to:\n  %s\n\n' \
    "$LOG_FILE"

show_step 1 "$TOTAL" "Checking Git identity, branch, and remote"
if ! require_commands git nix jq rg awk python3; then
    show_failed
    fatal "Git or Nix is missing"
fi
if [ ! -d "$BACKUP_REPO/.git" ]; then
    show_failed
    fatal "Git backup repository is missing: $BACKUP_REPO"
fi

git_name="$(git -C "$BACKUP_REPO" config --get user.name || true)"
git_email="$(git -C "$BACKUP_REPO" config --get user.email || true)"
if [ -z "$git_name" ] || [ -z "$git_email" ]; then
    show_failed
    printf '\nI need your GitHub/Git email address before I can commit.\n' >&2
    printf 'Nothing was updated, committed, or pushed.\n' >&2
    exit 1
fi

branch="$(git -C "$BACKUP_REPO" branch --show-current)"
remote_url="$(git -C "$BACKUP_REPO" remote get-url origin 2>/dev/null || true)"
remote_push_url="$(git -C "$BACKUP_REPO" remote get-url --push origin 2>/dev/null || true)"
if [ "$branch" != "main" ]; then
    show_failed
    fatal "Expected Git branch main, found: ${branch:-detached HEAD}"
fi
case "$remote_url" in
    https://github.com/Roshrak/nixos-config|https://github.com/Roshrak/nixos-config.git|\
    git@github.com:Roshrak/nixos-config|git@github.com:Roshrak/nixos-config.git|\
    https://*@github.com/Roshrak/nixos-config|https://*@github.com/Roshrak/nixos-config.git)
        ;;
    *)
        show_failed
        fatal "The origin remote is not the expected GitHub backup repository"
        ;;
esac
case "$remote_push_url" in
    https://github.com/Roshrak/nixos-config|https://github.com/Roshrak/nixos-config.git|\
    git@github.com:Roshrak/nixos-config|git@github.com:Roshrak/nixos-config.git|\
    https://*@github.com/Roshrak/nixos-config|https://*@github.com/Roshrak/nixos-config.git)
        ;;
    *)
        show_failed
        fatal "The origin push destination is not the expected GitHub backup repository"
        ;;
esac
if [ "$check_only" -eq 0 ]; then
    git -C "$BACKUP_REPO" diff --cached --quiet
    staged_status=$?
    case "$staged_status" in
        0) ;;
        1) fatal "Existing staged work needs its own review; it was not overwritten and no update was started" ;;
        *) fatal "Could not verify the existing Git index" ;;
    esac
fi
show_ok

show_step 2 "$TOTAL" "Checking the NixOS flake and backup sources"
printf '\n  Backup-source checks:\n'
if detect_flake_target && "$SCRIPT_DIR/backup-config.sh" --check-only \
       2>&1 | tee -a "$LOG_FILE"; then
    show_ok
    printf '  Using: %s\n' "$FLAKE_TARGET"
else
    show_failed
    fatal "NixOS or configuration backup safety checks failed"
fi

show_step 3 "$TOTAL" "Checking for remote Git changes"
if [ "$check_only" -eq 1 ]; then
    printf 'Remote fetch skipped in check-only mode.\n'
    printf 'Remote ahead/behind status was not refreshed.\n' >> "$LOG_FILE"
    show_warning
elif run_logged "Git fetch" git -C "$BACKUP_REPO" fetch --quiet origin main; then
    if ! ahead_behind="$(git -C "$BACKUP_REPO" rev-list --left-right --count \
            HEAD...origin/main 2>> "$LOG_FILE")"; then
        show_failed
        fatal "Could not compare local and GitHub commits; system update was not started"
    fi
    read -r local_ahead remote_ahead <<< "$ahead_behind"
    if ! [[ "$local_ahead" =~ ^[0-9]+$ && "$remote_ahead" =~ ^[0-9]+$ ]]; then
        show_failed
        fatal "Git returned an invalid local/remote comparison"
    fi
    if [ "$remote_ahead" -ne 0 ]; then
        show_failed
        fatal "GitHub has newer commits. Stop and ask for help before updating."
    fi
    if [ "$local_ahead" -ne 0 ]; then
        printf '\nLocal commits not yet on origin/main (%s):\n' "$local_ahead"
        git -C "$BACKUP_REPO" log --oneline --decorate origin/main..HEAD
        printf '\nTheir committed diff summary:\n'
        git -C "$BACKUP_REPO" diff --stat origin/main..HEAD
        if [ "$check_only" -eq 0 ]; then
            if [ "$resume_backup" -eq 1 ]; then
                printf '\nReview these commits before continuing to the backup review.\n'
            else
                printf '\nReview these commits before continuing the system update.\n'
            fi
            printf 'Type CONTINUE to proceed, or press Enter to stop: '
            read -r ahead_confirmation
            if [ "$ahead_confirmation" != "CONTINUE" ]; then
                show_failed
                fatal "Stopped safely because local commits were not approved."
            fi
        fi
    fi
    printf 'Local commits ahead of origin: %s\n' "$local_ahead" >> "$LOG_FILE"
    show_ok
else
    show_failed
    fatal "Could not contact the GitHub repository; system update was not started"
fi

for required_path in nixos baby-step dotfiles scripts; do
    [ -d "$BACKUP_REPO/$required_path" ] ||
        fatal "Required repository path is missing: $required_path"
done
publication_paths=(nixos baby-step dotfiles scripts docs README.md .gitignore)
for optional_path in installation wallpapers .gitattributes; do
    if [ -e "$BACKUP_REPO/$optional_path" ]; then
        publication_paths+=("$optional_path")
    fi
done
if ! git -C "$BACKUP_REPO" add --dry-run -A -- \
    "${publication_paths[@]}" >> "$LOG_FILE" 2>&1; then
    fatal "Repository staging paths could not be validated"
fi

if [ "$check_only" -eq 1 ]; then
    show_step 4 "$TOTAL" 'Checking update prerequisites without updating'
    if ! run_logged 'Update prerequisite check' "$SCRIPT_DIR/update-system.sh" --check-only; then
        fatal "System update safety checks failed"
    fi
    show_ok
    printf '\nSUCCESS: Update-and-push safety checks passed.\n'
    printf 'No system configuration or packages were changed. Nothing was committed or pushed.\n'
    printf 'Only maintenance log and state files were updated.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

show_step 4 "$TOTAL" "Verifying the computer before publication"
if [ "$backup_only" -eq 1 ]; then
    source_system="$(nix eval --offline --no-write-lock-file --raw \
        "${FLAKE_TARGET%#*}#nixosConfigurations.$FLAKE_ATTR.config.system.build.toplevel.outPath" \
        2>> "$LOG_FILE")" || fatal "Could not evaluate the configuration selected for publication"
    active_system="$(readlink -f /run/current-system)" || fatal "Could not identify the active system"
    [ "$source_system" = "$active_system" ] ||
        fatal "The declared configuration differs from the active system; build and activate it before --backup-only"
    health_status=0
    run_logged 'Pre-publication health check' "$SCRIPT_DIR/check-system.sh" || health_status=$?
    case "$health_status" in
        0) show_ok ;;
        1) show_warning ;;
        *) fatal "Health checks could not complete; nothing will be published" ;;
    esac
    printf 'BACKUP ONLY: active system matches declared configuration; inputs were not updated.\n'
elif [ "$resume_backup" -eq 1 ]; then
    pending_run="$STATE_DIR/pending-update-run.txt"
    if [ ! -f "$pending_run" ] || [ -L "$pending_run" ] ||
       [ "$(stat -c '%u:%a' "$pending_run" 2>/dev/null)" != "$(id -u):600" ]; then
        show_failed
        fatal "No private update-run receipt exists; backup resume is not verified"
    fi
    IFS= read -r update_run_id < "$pending_run" || update_run_id=""
    if ! validate_update_receipt "$update_run_id"; then
        show_failed
        fatal "The previous system update cannot be verified against the active generation and current configuration"
    fi
    printf '\n  Verified completed update run: %s\n' "$update_run_id"
    printf '  Active generation and configuration hashes match its health receipt.\n'
    printf 'BACKUP ONLY (no rebuild in this invocation)\n'
else
    update_run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    pending_run="$STATE_DIR/pending-update-run.txt"
    pending_tmp="$(mktemp "$STATE_DIR/.pending-update-run.XXXXXX")" ||
        fatal "Could not prepare the update-run receipt"
    if ! printf '%s\n' "$update_run_id" > "$pending_tmp" ||
       ! chmod 600 "$pending_tmp" || ! mv -f -- "$pending_tmp" "$pending_run"; then
        rm -f -- "$pending_tmp"
        fatal "Could not save the update-run receipt"
    fi
    printf '\n  System-update details:\n'
    if MAINTENANCE_RUN_ID="$update_run_id" "$SCRIPT_DIR/update-system.sh" 2>&1 | tee -a "$LOG_FILE"; then
        if validate_update_receipt "$update_run_id"; then
            show_ok
        else
            show_failed
            fatal "The update returned success without a matching verified receipt"
        fi
    else
        show_failed
        fatal "System update failed. Nothing will be committed or pushed."
    fi
fi

show_step 5 "$TOTAL" "Snapshotting important configuration"
printf '\n  Configuration-snapshot details:\n'
if "$SCRIPT_DIR/backup-config.sh" 2>&1 | tee -a "$LOG_FILE"; then
    show_ok
else
    show_failed
    fatal "Configuration snapshot failed. Nothing will be committed or pushed."
fi

show_step 6 "$TOTAL" "Staging and inspecting safe repository paths"
if ! git -C "$BACKUP_REPO" add -A -- \
    "${publication_paths[@]}" >> "$LOG_FILE" 2>&1; then
    show_failed
    fatal "Could not stage the configuration snapshot"
fi

if ! git -C "$BACKUP_REPO" diff --cached --check >> "$LOG_FILE" 2>&1; then
    show_failed
    fatal "Staged files contain Git whitespace errors. Nothing was committed or pushed."
fi

if ! python3 "$SCRIPT_DIR/lib/publication-check.py" --repo "$BACKUP_REPO" \
        2>&1 | tee -a "$LOG_FILE"; then
    show_failed
    fatal "The staged publication tree failed path/content checks. Nothing was committed or pushed."
fi

staged_tree="$(git -C "$BACKUP_REPO" write-tree 2>> "$LOG_FILE")" || {
    show_failed
    fatal "Could not record the reviewed staged snapshot"
}

show_ok
printf '\nFiles ready for backup:\n'
git -C "$BACKUP_REPO" diff --cached --stat
printf '\nGit status:\n'
git -C "$BACKUP_REPO" status --short

printf '\nNothing has been committed or pushed yet.\n'
printf 'Type PUSH and press Enter to continue, or press Enter to stop: '
read -r confirmation
if [ "$confirmation" != "PUSH" ]; then
    printf '\nStopped safely. Any completed system activation remains in place.\n'
    printf 'The repository changes remain local and can be reviewed later.\n'
    exit 0
fi

show_step 7 "$TOTAL" "Committing the reviewed configuration"
current_tree="$(git -C "$BACKUP_REPO" write-tree 2>> "$LOG_FILE")" ||
    fatal "Could not recheck the staged snapshot"
if [ "$current_tree" != "$staged_tree" ]; then
    show_failed
    fatal "The staged files changed after review. Nothing was committed or pushed."
fi
if git -C "$BACKUP_REPO" diff --cached --quiet; then
    printf 'NO CHANGES\n'
else
    if run_logged "Git commit" git -C "$BACKUP_REPO" commit \
           -m "Update Tonelico NixOS configuration ($(date +%F))"; then
        show_ok
    else
        show_failed
        fatal "Git commit failed. Nothing was pushed."
    fi
fi

show_step 8 "$TOTAL" "Pushing and verifying GitHub backup"
if run_logged "Git push" git -C "$BACKUP_REPO" push origin main; then
    local_head="$(git -C "$BACKUP_REPO" rev-parse HEAD)"
    remote_head="$(git -C "$BACKUP_REPO" ls-remote origin refs/heads/main |
        awk 'NR == 1 { print $1 }')"
    if [ -n "$remote_head" ] && [ "$local_head" = "$remote_head" ]; then
        show_ok
    else
        show_failed
        fatal "Git push returned successfully, but remote verification did not match"
    fi
else
    show_failed
    fatal "Git push failed. The commit remains safe on this computer."
fi

record_success git-backup "$BACKUP_REPO -> origin/main at $local_head"
if [ "$backup_only" -eq 0 ] && [ -f "$STATE_DIR/pending-update-run.txt" ] && [ ! -L "$STATE_DIR/pending-update-run.txt" ]; then
    rm -f -- "$STATE_DIR/pending-update-run.txt"
fi
if [ "$backup_only" -eq 1 ]; then
    write_maintenance_state "GitHub backup" "Active configuration snapshot and verified push succeeded" \
        "Active/source equality, health check, snapshot, publication scan, commit, verified push" \
        "Configuration repository and GitHub origin/main; no system update" "None"
else
    write_maintenance_state "Update and GitHub backup" "Update, snapshot, commit, and push succeeded" \
        "System update, health check, snapshot, publication scan, commit, verified push" \
        "NixOS generation, configuration repository, GitHub origin/main" "None"
fi

if [ "$backup_only" -eq 1 ]; then
    printf '\nSUCCESS: The active configuration was saved to GitHub; no inputs or packages were updated.\n'
else
    printf '\nSUCCESS: The computer was updated and the configuration was saved to GitHub.\n'
fi
printf 'Automated checks do not replace interactive smoke tests in each desktop session.\n'
printf 'Detailed log: %s\n' "$LOG_FILE"
