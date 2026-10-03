BABY-STEP: SEE WHAT IS HAPPENING
===============================
Run these commands as your normal user. The update/rebuild tools request sudo
only when activation needs it. Do not put sudo in front of the scripts.

Each maintenance command shows:
  [03/09] [##........] Current stage
  [RUN]   The operation starting now
  [WAIT]  Still running, with elapsed time (every 10 seconds)
  [EXIT]  The actual command exit code
  [OK] / [WARNING] / [FAILED] / [SKIPPED]  Stage outcome and explanation

The bar tracks stages, not a guessed download/build percentage. Long command
output appears live and is saved in a private, uniquely named log. Colors appear
in a normal terminal; redirected output stays plain. NO_COLOR=1 disables color.
BABY_STEP_COLOR=always/never selects color explicitly. NO_COLOR takes precedence.
Warnings explain their cause on screen. A skipped physical test is not a failure.

SOURCE SELECTION
----------------
A private ~/baby-step/state/nixos-source.path chooses the reviewed flake source.
On this repaired laptop it points to /etc/nixos/gen129-recovery. A fresh install
uses /etc/nixos. An explicit NIXOS_DIR overrides it. Invalid pointers fail closed.
Flake references use path: so required untracked inputs are included without
staging them. Never blindly build the old parent tree on this laptop.

CHECK THE COMPUTER
------------------
~/baby-step/check-system.sh

Checks complete NixOS evaluation, services, network/DNS, audio enumeration,
desktop configuration, session entries, input and disk state. It shows running,
booted and profile paths separately. Staged next-boot state and dirty Git work
are not automatically defects. Exit 0 = these checks passed; 1 = warnings or
skips; 2 = failed checks. Failed unit names are shown, with full detail in the log.
This does not log into every desktop, listen to audio, press keys or test a lock.

BUILD THE CURRENT CONFIGURATION
-------------------------------
~/baby-step/rebuild-system.sh --build-only

Evaluates and builds with live output, verifies the candidate exists and source
has not changed, and leaves the running generation alone. Nix store/cache and
local log/state files can change. It does not upgrade inputs.

BUILD AND ACTIVATE THE CURRENT CONFIGURATION
-------------------------------------------
~/baby-step/rebuild-system.sh

Builds first, previews activation, switches to the exact built store path, then
checks the resulting active path and services. Service warnings are not hidden.

UPDATE NIXOS
------------
~/baby-step/update-system.sh --check-only
  Prerequisites and flake-target detection only; no input update/build/activation.

~/baby-step/update-system.sh
  Unique lock before-image -> input update -> evaluation -> visible build ->
  dry activation -> exact candidate switch -> boot-entry/fallback checks -> health.
  A failed pre-activation update restores its own lock when identity still matches.
  Later lock edits or an uncertain interrupted update are preserved for review.
  Before-images are kept under ~/baby-step/backups/flake.lock.previous.*.
  Flatpak updates may run; firmware work refreshes/checks metadata only.

SAVE CONFIGURATION LOCALLY
--------------------------
~/baby-step/backup-config.sh --check-only
  Creates a disposable source snapshot, validates assets and full system parity,
  and builds it offline. The repository, real receipts and hardware backup stay
  untouched. Temporary work and Nix store/cache artifacts may be created.

~/baby-step/backup-config.sh
  Validates, previews changes, asks for SNAPSHOT, preserves previous repository
  copies, then replaces the selected trees. No commit or push. Existing staged
  Git work is not reset. An already-current snapshot is a no-op.
  All active utilities, shared libraries and regression tests are included.

UPDATE AND PUBLISH TO GITHUB
---------------------------
~/baby-step/update-and-push.sh --check-only
  Runs current-source backup/build validation and update prerequisites. No remote
  fetch, input update, activation, staging, commit or push. Log/state files change.

~/baby-step/update-and-push.sh
  Verifies local/remote state, updates, snapshots, scans the staged tree, reviews
  publication and pushes only after the retained SNAPSHOT/PUSH prompts.

~/baby-step/update-and-push.sh --backup-only
  Requires declared source to equal the active system; no input/package update.

~/baby-step/update-and-push.sh --resume-backup
  Requires the prior completed update receipt to still match live source/lock
  hashes and the active system. It refuses stale or missing receipts.

Existing staged work needs its own review and is preserved. None of these checks
proves interactive behavior in all desktop sessions.

COPY WALLPAPERS WITHOUT DELETING DESTINATION-ONLY FILES
-----------------------------------------------------
~/baby-step/sync-wallpapers.sh upload --check-only
~/baby-step/sync-wallpapers.sh download --check-only
~/baby-step/sync-wallpapers.sh upload
~/baby-step/sync-wallpapers.sh download
~/baby-step/sync-wallpapers.sh status

Uses rclone copy, with visible transfer progress. Unlike the old sync behavior,
files existing only at the destination are preserved. Matching filenames may be
updated by a real copy. A missing upload source is refused; a download preview
does not create the local folder. A failed remote query exits nonzero.
Configure the gdrive remote with rclone config once if it is not already present.

GENERATE A PRIVATE INVENTORY REPORT
----------------------------------
~/baby-step/generate-system-audit.sh --quick
~/baby-step/generate-system-audit.sh
~/baby-step/generate-system-audit.sh --output /absolute/path/NEW-report.md

Writes a dated mode-600 report under ~/baby-step/reports by default. It preserves
existing reports and refuses an existing --output target. Captures have timeouts,
progress and error markers. Unknown environment variables and assistant config
contents are omitted. Separate system-summary files are not automatically refreshed.
Default inventory reports are excluded from Git publication, including legacy
system-audit*.md reports. Custom output paths need the same private handling.
A recorded report is evidence to interpret, not a certification of system health.

CHECK THE SCRIPTS THEMSELVES
---------------------------
~/baby-step/run-tests.sh --list
~/baby-step/run-tests.sh --quick
~/baby-step/run-tests.sh

Quick runs 16 isolated suites. Full runs 18, including offline builds from
restored disposable source snapshots. Tests never activate a real generation,
replace a real backup, publish to GitHub or transfer wallpapers. A test failure
is reported while independent suites continue. Fixtures do not replace real
physical/interactive acceptance.

MINECRAFT HELPER (CURRENT NIRI SESSION ONLY)
-----------------------------------------
~/baby-step/launch_mc_and_spawn.py --help
~/baby-step/launch_mc_and_spawn.py --check-only
~/baby-step/launch_mc_and_spawn.py --no-spawn
~/baby-step/launch_mc_and_spawn.py

Inherits the current session socket, reuses a unique game window, waits for fresh
Crazy-Fools connection/welcome evidence, verifies focus and unlocked state, then
sends /spawn. Missing logs are waited for; rotated logs are followed. Failed input,
join timeout and an unconfirmed teleport are not reported as success. No automatic
retry. Custom --instance and --log select another instance; welcome verification
currently recognizes Crazy-Fools only. The global input helper has a focus-change
race: do not change focus while it types. Other desktops fail with an explanation.

LOGS, RECOVERY AND HISTORY
-------------------------
Detailed private logs: ~/baby-step/logs/
Local state markers:   ~/baby-step/state/
Snapshots/before-images: ~/baby-step/backups/
Old audit scripts and reports are preserved historical evidence, not current tools.

If activation failed, inspect the log and actual system paths before another try.
For a known bad activated generation: sudo nixos-rebuild switch --rollback
For a failed boot: select a retained older generation in systemd-boot.
Do not delete recovery generations while troubleshooting.
Migration guide: ~/nixos-config/docs/MIGRATION-INSTALL.md
Deployment helper: ~/nixos-config/scripts/bootstrap-nixos.sh
