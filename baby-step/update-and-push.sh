#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

check_only=0
case "${1:-}" in
    "") ;;
    --check-only) check_only=1 ;;
    -h|--help)
        printf 'Safely update NixOS, snapshot configuration, commit, and push.\n'
        printf 'Run: %s\n' "$HOME/baby-step/update-and-push.sh"
        printf 'Safety checks only: %s --check-only\n' "$HOME/baby-step/update-and-push.sh"
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

printf 'Preparing a safe update and GitHub backup.\n\n'

show_step 1 "$TOTAL" "Checking Git identity, branch, and remote"
if ! require_commands git nix jq rg awk; then
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
show_ok

show_step 2 "$TOTAL" "Checking the NixOS flake and backup sources"
if detect_flake_target && "$SCRIPT_DIR/backup-config.sh" --check-only \
       >> "$LOG_FILE" 2>&1; then
    show_ok
    printf '  Using: %s\n' "$FLAKE_TARGET"
else
    show_failed
    fatal "NixOS or configuration backup safety checks failed"
fi

show_step 3 "$TOTAL" "Checking for remote Git changes"
if run_logged "Git fetch" git -C "$BACKUP_REPO" fetch --quiet origin main; then
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
        show_failed
        fatal "Local unpushed commits need review before this tool can continue."
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
if ! git -C "$BACKUP_REPO" add --dry-run -A -- \
    nixos baby-step dotfiles scripts >> "$LOG_FILE" 2>&1; then
    fatal "Repository staging paths could not be validated"
fi

if [ "$check_only" -eq 1 ]; then
    if ! "$SCRIPT_DIR/update-system.sh" --check-only >> "$LOG_FILE" 2>&1; then
        fatal "System update safety checks failed"
    fi
    printf '\nSUCCESS: Update-and-push safety checks passed.\n'
    printf 'No system configuration or packages were changed. Nothing was committed or pushed.\n'
    printf 'Only maintenance log and state files were updated.\n'
    printf 'Detailed log: %s\n' "$LOG_FILE"
    exit 0
fi

show_step 4 "$TOTAL" "Updating and verifying the computer"
if "$SCRIPT_DIR/update-system.sh" >> "$LOG_FILE" 2>&1; then
    show_ok
else
    show_failed
    fatal "System update failed. Nothing will be committed or pushed."
fi

show_step 5 "$TOTAL" "Snapshotting important configuration"
if "$SCRIPT_DIR/backup-config.sh" >> "$LOG_FILE" 2>&1; then
    show_ok
else
    show_failed
    fatal "Configuration snapshot failed. Nothing will be committed or pushed."
fi

show_step 6 "$TOTAL" "Staging and inspecting safe repository paths"
if ! git -C "$BACKUP_REPO" add -A -- \
    nixos baby-step dotfiles scripts >> "$LOG_FILE" 2>&1; then
    show_failed
    fatal "Could not stage the configuration snapshot"
fi

unexpected_path=0
if ! staged_paths="$(git -C "$BACKUP_REPO" diff --cached --name-only \
        2>> "$LOG_FILE")"; then
    show_failed
    fatal "Could not inspect staged paths. Nothing was committed or pushed."
fi
while IFS= read -r staged_path; do
    [ -n "$staged_path" ] || continue
    case "$staged_path" in
        nixos/*|baby-step/*|dotfiles/.config/*|dotfiles/.local/bin/*|\
        dotfiles/.local/share/applications/*|dotfiles/.local/share/desktop-look-toggle/*|\
        scripts/*)
            ;;
        *)
            printf 'Unexpected staged path: %s\n' "$staged_path" >> "$LOG_FILE"
            unexpected_path=1
            ;;
    esac
done <<< "$staged_paths"
if [ "$unexpected_path" -ne 0 ]; then
    show_failed
    fatal "An unexpected file is staged. Nothing was committed or pushed."
fi

if ! git -C "$BACKUP_REPO" diff --cached --check >> "$LOG_FILE" 2>&1; then
    show_failed
    fatal "Staged files contain Git whitespace errors. Nothing was committed or pushed."
fi

secret_name=0
while IFS= read -r staged_path; do
    [ -n "$staged_path" ] || continue
    case "$staged_path" in
        */id_rsa|*/id_ed25519|*/credentials|*/credentials.*|*/.env|*/.env.*|\
        */id_ecdsa|*/.netrc|*/auth.json|*.key|*.pem|*.p12|*.pfx)
            secret_name=1
            ;;
    esac
done <<< "$staged_paths"
if [ "$secret_name" -ne 0 ]; then
    show_failed
    fatal "A secret-like filename is staged. Its contents were not displayed."
fi

git -C "$BACKUP_REPO" diff --cached -U0 --no-ext-diff | rg -i \
   "^\\+[^+].*(access[_-]?token[[:space:]]*=|refresh[_-]?token[[:space:]]*=|api[_-]?key[[:space:]]*=|client[_-]?secret[[:space:]]*=|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|password[[:space:]]*=[[:space:]]*[\\\"'][^\\\"']{4,})" \
   >/dev/null
scan_status=("${PIPESTATUS[@]}")
if [ "${scan_status[0]}" -ne 0 ] || [ "${scan_status[1]}" -gt 1 ]; then
    show_failed
    fatal "The staged-secret scan could not run reliably. Nothing was committed or pushed."
fi
if [ "${scan_status[1]}" -eq 0 ]; then
    show_failed
    fatal "Possible secret content is staged. Its value was not displayed."
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
    printf '\nStopped safely. The system update remains active.\n'
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
write_maintenance_state "Update and GitHub backup" "Update, snapshot, commit, and push succeeded" \
    "System update, health check, snapshot, secret check, commit, verified push" \
    "NixOS generation, configuration repository, GitHub origin/main" "None"

printf '\nSUCCESS: The computer was updated and the configuration was saved to GitHub.\n'
printf 'Detailed log: %s\n' "$LOG_FILE"
