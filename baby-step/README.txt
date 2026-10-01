CHECK IF MY COMPUTER IS OK
Run:
~/baby-step/check-system.sh

This checks configuration and system health. It does not log into and test all
seven desktop sessions for you. Each session still needs an interactive smoke
test after a desktop or system change.

UPDATE MY COMPUTER
Run:
~/baby-step/update-system.sh

UPDATE AND SAVE MY CONFIG TO GITHUB
Run:
~/baby-step/update-and-push.sh

This verifies the automated checks before backup. It does not prove every
desktop session passed its interactive smoke test.

SAVE THE ALREADY-ACTIVE CONFIGURATION TO GITHUB WITHOUT UPGRADING
Run:
~/baby-step/update-and-push.sh --backup-only

This checks that the declared system equals the active system, checks health,
prepares a recoverable snapshot, scans the staged publication tree, and asks for
SNAPSHOT and PUSH. It does not update flake inputs or packages. Existing staged
Git work must be reviewed separately; the tool refuses to overwrite it.

READ MY COMPUTER SUMMARY
Simple version:
~/baby-step/system-summary.txt

DETAILED SUMMARY FOR AN AI
Give the AI this file:
~/baby-step/system-summary-for-ai.md

AUDIT AND SYSTEM REVIEW RECORDS
Current full system snapshot:
~/baby-step/system-audit.md

Latest full-audit and follow-up records (local, not uploaded):
~/baby-step/full-audit-2026-10-01/

Older audit records:
~/baby-step/reports/

INSTALL OR MOVE TO ANOTHER COMPUTER
Read this guide first:
~/nixos-config/docs/MIGRATION-INSTALL.md

Safe deployment script:
~/nixos-config/scripts/bootstrap-nixos.sh

IF SOMETHING FAILS
Do not run random commands.
Copy the ERROR message and show it to Codex or ChatGPT.
Detailed logs are stored in:
~/baby-step/logs

IMPORTANT
Run these commands as your normal user.
Do not put sudo in front of them.
The update tools will ask for your password when it is actually needed.
Nothing appears while you type your password. That is normal. Press Enter.

REBUILD WITHOUT DOWNLOADING UPDATES
Run:
~/baby-step/rebuild-system.sh

SAVE CONFIG LOCALLY WITHOUT COMMITTING OR PUSHING
Run:
~/baby-step/backup-config.sh

The script previews changes before replacing the repository snapshot. Type
SNAPSHOT only after reviewing them; press Enter to leave the repository alone.
An already-current snapshot is a no-op. This script never commits or pushes.

Run update-and-push.sh --check-only for local safety checks. Check-only skips
remote fetch, so it does not refresh GitHub ahead/behind status and does not
update Nix inputs, change the system, commit, or push.

SYNC WALLPAPERS WITH GOOGLE DRIVE
Upload:
~/baby-step/sync-wallpapers.sh upload

Download to a new machine:
~/baby-step/sync-wallpapers.sh download

IF A NEW SYSTEM WAS ACTIVATED AND THEN BROKE
Open Terminal.
Copy this command:
sudo nixos-rebuild switch --rollback
Paste it.
Press Enter.
Type your password and press Enter.
Then stop and show Codex or ChatGPT what happened.

IF THE COMPUTER CANNOT REACH THE LOGIN SCREEN
Restart the computer.
In the boot menu, choose an older NixOS generation.
Do not delete old generations while troubleshooting.

The tools automatically detect the flake configuration.
You do not need to remember that the current target is /etc/nixos#tonelico.
