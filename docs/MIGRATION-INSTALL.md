# Complete NixOS migration, installation, and multi-host guide

This guide explains how to reproduce this system on fresh hardware while keeping
each machine's generated hardware settings separate. It is written for a
beginner and uses the repository's tested bootstrap script.

## The short version

The normal workflow is:

```text
clone repository
→ generate hardware configuration for the target machine
→ run bootstrap-nixos.sh
→ build and switch, or run nixos-install
→ test the machine
→ commit the new host profile
```

The bootstrap script is:

```text
scripts/bootstrap-nixos.sh
```

It validates the repository, discovers or creates the selected host, imports the
correct hardware file, evaluates the flake, backs up old configuration, deploys
system and selected user files, and optionally builds, switches, or installs.

## Important safety boundary

Disk partitioning and formatting are deliberately not automated by this
repository. Choosing the wrong disk can permanently destroy personal data.

For a completely fresh installation, first use the NixOS installer to create and
mount the target filesystems under `/mnt`. The examples below begin only after:

- the intended root filesystem is mounted at `/mnt`;
- the intended EFI partition is mounted at `/mnt/boot`;
- networking works in the installer; and
- you have confirmed you are not formatting the wrong disk.

If those steps are unfamiliar, stop and ask an AI or experienced person for a
machine-specific partitioning walkthrough. Show them
`baby-step/system-summary-for-ai.md` and do not guess device names.

## Repository layout

The canonical deployable system lives in `nixos/`:

```text
nixos/
├── flake.nix
├── flake.lock
├── configuration.nix
├── apps-and-lotus.nix
├── claude-code.nix
├── comic-mono.nix
├── wave75-via.nix
├── windows-vm.nix
├── desktop/
│   ├── niri.nix
│   └── plasma.nix
├── fonts/
│   └── comic-mono/
└── hosts/
    ├── README.md
    └── tonelico/
        ├── host.nix
        ├── hardware-configuration.nix
        └── default.nix
```

Other repository directories:

```text
dotfiles/       selected user configuration and helper scripts
baby-step/      beginner maintenance tools and system summaries
scripts/        bootstrap and older maintenance/migration helpers
docs/           documentation and historical plans
```

## Shared files versus host-specific files

| Kind | Location | Share across machines? | Purpose |
| --- | --- | --- | --- |
| Flake inputs and host discovery | `nixos/flake.nix`, `flake.lock` | Yes | Pins inputs and discovers complete host directories automatically. |
| General NixOS configuration | `nixos/configuration.nix` | Yes | Networking, audio, shared graphics defaults, desktop foundations, packages, and services. |
| Shared application modules | `nixos/*.nix` | Usually | Fcitx5 Lotus, Claude Code, fonts, optional keyboard and VM modules. |
| Desktop modules | `nixos/desktop/` | Yes | Plasma, Niri, greetd/Noctalia integration, portals, and session handling. |
| Selected user configuration | `dotfiles/` | Yes, for user `aesc` | Mango, Niri, Noctalia, Kitty, Neovim, Fcitx5, themes, and helpers. |
| Maintenance tools | `baby-step/` | Yes | Health, update, backup, rebuild, and Git workflows. |
| Host metadata | `nixos/hosts/NAME/host.nix` | No | Hostname, architecture, primary-user deployment metadata, and optional modules. |
| Generated hardware | `nixos/hosts/NAME/hardware-configuration.nix` | No | Filesystem UUIDs, boot modules, platform, and discovered hardware for that installation. |
| Host tuning | `nixos/hosts/NAME/default.nix` | No | CPU/GPU vendor settings, special drivers, and machine-specific services. |

Do not copy one machine's `hardware-configuration.nix` onto unrelated hardware.
Generate it on the destination machine or mounted destination filesystem.

The current Tonelico host has Intel-only media acceleration and `thermald` in
`nixos/hosts/tonelico/default.nix`. Those settings are no longer forced onto new
AMD, NVIDIA, ARM, or generic hosts.

## How host discovery works

Every immediate directory under `nixos/hosts/` becomes a flake configuration
when both of these files exist:

```text
host.nix
hardware-configuration.nix
```

The directory name is the flake attribute. For example:

```text
nixos/hosts/tonelico/
```

creates:

```text
/etc/nixos#tonelico
```

Its `host.nix` sets the actual hostname to `tonelico-nix`. The two names do not
need to match.

Adding a future host does not require manually editing `flake.nix`. The bootstrap
script creates the directory and metadata, and the flake discovers it.

## What the bootstrap script changes

Before changing anything, the script:

1. Validates required repository files and commands.
2. Validates the host/flake name, hostname, platform, and hardware module.
3. Builds a complete candidate in a temporary directory.
4. Evaluates the candidate hostname and full system derivation.
5. Shows the exact deployment plan.
6. Requires typing `DEPLOY` unless `--yes` was supplied.

During deployment it:

1. Preserves the selected host profile in `nixos/hosts/NAME/`.
2. Places an exact candidate at the target's `/etc/nixos`.
3. Moves the previous `/etc/nixos` to a timestamped recoverable backup.
4. Preserves an existing `/etc/nixos/.git` recovery history.
5. Stages the exact deployed candidate in that local recovery repository so
   Git-backed flakes can see new host files; it does not commit or push.
6. Validates the deployed flake and restores the previous directory if this
   validation unexpectedly fails.
7. Backs up and deploys selected dotfiles, helpers, and baby-step tools.
8. On installer targets, copies the cloned Git repository into
   `/home/aesc/nixos-config` for use after reboot.
9. Optionally builds, switches, or installs.

The script is idempotent. Running the same command again compares the candidate
with the target and reports `ALREADY CURRENT` instead of replacing it again.

## Script options

Show built-in help:

```bash
cd ~/nixos-config
./scripts/bootstrap-nixos.sh --help
```

Important options:

```text
--host NAME          flake attribute and host directory
--hostname NAME      actual operating-system hostname
--create-host        create a new host profile
--hardware FILE      import a generated hardware-configuration.nix
--target-root PATH   / for this system, /mnt during installation
--dry-run            validate and show the plan; change nothing
--build              build but do not activate
--switch             build first, then activate the running system
--install            build and run nixos-install under the target root
--yes                skip typing DEPLOY
--no-user-config     do not restore dotfiles or baby-step tools
--no-copy-repository do not copy the clone into the installed user's home
```

With no final action option, the script prepares files only and activates
nothing.

## Recipe 1: completely new machine from the NixOS installer

This recipe creates a new host named `new-laptop`. Replace that name with a short
unique name containing only letters, numbers, periods, underscores, plus signs,
or hyphens.

### Step 1: generate fresh hardware configuration

After mounting the destination root at `/mnt` and EFI partition at `/mnt/boot`,
run:

```bash
sudo nixos-generate-config --root /mnt
```

Press Enter. Wait for it to finish.

Check that the hardware file exists:

```bash
test -s /mnt/etc/nixos/hardware-configuration.nix && echo SUCCESS
```

If it prints `SUCCESS`, continue. If it prints nothing or shows an error, stop.

### Step 2: clone the repository

Run:

```bash
git clone https://github.com/Roshrak/nixos-config.git /tmp/nixos-config
```

If `git` is not available, run:

```bash
nix shell nixpkgs#git -c git clone https://github.com/Roshrak/nixos-config.git /tmp/nixos-config
```

Enter the repository:

```bash
cd /tmp/nixos-config
```

### Step 3: perform a dry run

Copy this command, replacing both instances of `new-laptop` if needed:

```bash
./scripts/bootstrap-nixos.sh \
  --target-root /mnt \
  --host new-laptop \
  --hostname new-laptop \
  --create-host \
  --hardware /mnt/etc/nixos/hardware-configuration.nix \
  --dry-run
```

This changes nothing. It must finish with:

```text
SUCCESS: Dry-run validation passed. Nothing was changed.
```

If it says `ERROR`, stop and show the complete error to an AI.

### Step 4: review host-specific hardware tuning

The new file produced in the candidate is a generic host module. Before using
proprietary NVIDIA drivers or unusual hardware, add only the proven settings to:

```text
nixos/hosts/new-laptop/default.nix
```

For ordinary Intel or AMD graphics, the generic shared Mesa configuration is a
safe starting point. Do not copy Tonelico's Intel tuning to AMD or NVIDIA.

### Step 5: deploy and install

Run the same command with `--install` instead of `--dry-run`:

```bash
./scripts/bootstrap-nixos.sh \
  --target-root /mnt \
  --host new-laptop \
  --hostname new-laptop \
  --create-host \
  --hardware /mnt/etc/nixos/hardware-configuration.nix \
  --install
```

The script displays its plan. Read the paths. If they are correct, type:

```text
DEPLOY
```

and press Enter.

The script evaluates and builds before running `nixos-install`. It may ask for a
password required by the installer. Wait until it prints `SUCCESS`.

### Step 6: reboot and test

When installation finishes:

```bash
sudo reboot
```

Remove the installer USB when the firmware or installer asks.

After login, check the system:

```bash
~/baby-step/check-system.sh
```

Test Wi-Fi, DNS, Bluetooth, speakers, microphone, suspend/resume, graphics,
Mango, Niri, Plasma, Noctalia, screenshots, Steam, OBS, and external displays.

The repository clone should now be available at:

```text
/home/aesc/nixos-config
```

The new host files will be uncommitted until reviewed and pushed.

## Recipe 2: add a new host from an already running NixOS machine

This is useful when NixOS is already installed with a temporary/default
configuration and you want to add it to this repository.

### Step 1: clone

Open Terminal and run:

```bash
git clone https://github.com/Roshrak/nixos-config.git ~/nixos-config
```

If the directory already exists, do not clone over it. Check it instead:

```bash
git -C ~/nixos-config status --short --branch
```

### Step 2: generate a hardware snapshot

Run:

```bash
sudo nixos-generate-config --show-hardware-config > ~/hardware-configuration.NEW-HOST.nix
```

Confirm it exists:

```bash
test -s ~/hardware-configuration.NEW-HOST.nix && echo SUCCESS
```

### Step 3: dry-run the new host

Example for a host called `work-laptop`:

```bash
cd ~/nixos-config
./scripts/bootstrap-nixos.sh \
  --host work-laptop \
  --hostname work-laptop \
  --create-host \
  --hardware ~/hardware-configuration.NEW-HOST.nix \
  --dry-run
```

### Step 4: prepare or build

Prepare files without activating:

```bash
./scripts/bootstrap-nixos.sh \
  --host work-laptop \
  --hostname work-laptop \
  --create-host \
  --hardware ~/hardware-configuration.NEW-HOST.nix
```

Or build without activating:

```bash
./scripts/bootstrap-nixos.sh \
  --host work-laptop \
  --hostname work-laptop \
  --create-host \
  --hardware ~/hardware-configuration.NEW-HOST.nix \
  --build
```

The `--build` command is the recommended first real test. If it fails, no new
generation is activated.

### Step 5: switch only after the build succeeds

After reviewing hardware-specific settings:

```bash
./scripts/bootstrap-nixos.sh \
  --host work-laptop \
  --hostname work-laptop \
  --hardware ~/hardware-configuration.NEW-HOST.nix \
  --switch
```

The script runs a build first and switches only if that build succeeds.

## Recipe 3: reinstall the existing Tonelico host

Use this only for the Acer Swift SFG16-72 that owns the `tonelico` profile, or
after deliberately reviewing its Intel host module for replacement hardware.

From the installer, generate a fresh file:

```bash
sudo nixos-generate-config --root /mnt
```

Clone and enter the repository:

```bash
git clone https://github.com/Roshrak/nixos-config.git /tmp/nixos-config
cd /tmp/nixos-config
```

Dry-run:

```bash
./scripts/bootstrap-nixos.sh \
  --target-root /mnt \
  --host tonelico \
  --hardware /mnt/etc/nixos/hardware-configuration.nix \
  --dry-run
```

Install after the dry run succeeds:

```bash
./scripts/bootstrap-nixos.sh \
  --target-root /mnt \
  --host tonelico \
  --hardware /mnt/etc/nixos/hardware-configuration.nix \
  --install
```

The saved host metadata supplies hostname `tonelico-nix`; do not change the
flake target to `#tonelico-nix`.

Passing the freshly generated hardware file causes the bootstrap script to:

- back up the repository's previous Tonelico hardware file if it differs;
- import the freshly generated file into `nixos/hosts/tonelico/`;
- keep a conventional root copy under deployed `/etc/nixos`;
- use only the host-scoped copy in the active flake.

## Updating hardware configuration after a disk or hardware change

Generate a new hardware file, but do not overwrite the saved host file manually.
Pass the new file to a dry run:

```bash
sudo nixos-generate-config --show-hardware-config > ~/hardware-configuration.NEW.nix
cd ~/nixos-config
./scripts/bootstrap-nixos.sh \
  --host tonelico \
  --hardware ~/hardware-configuration.NEW.nix \
  --dry-run
```

Then inspect the difference:

```bash
diff -u \
  nixos/hosts/tonelico/hardware-configuration.nix \
  ~/hardware-configuration.NEW.nix
```

Filesystem UUID changes are expected after repartitioning. Unexpected removal of
boot, encryption, RAID, or filesystem settings should be reviewed before
deployment.

## Enabling optional modules for a new host

`host.nix` may contain an `extraModules` list. Tonelico currently opts into its
VIA keyboard and VM modules:

```nix
extraModules = [
  ../../wave75-via.nix
  ../../windows-vm.nix
];
```

A new host starts with an empty list. Add only what the new machine should use.
The modules can also be made shared later if every machine needs them.

## Re-running the script

Running the same command again is safe. The script:

- compares source and destination files;
- does not rewrite an identical repository host profile;
- reports `ALREADY CURRENT` for an identical `/etc/nixos` candidate;
- backs up a destination before replacing a changed entry;
- never automatically commits or pushes;
- never activates anything unless `--switch` or `--install` was requested.

Use `--dry-run` whenever uncertain.

## Backups and rollback

For the currently running system, backups are placed under:

```text
~/baby-step/backups/bootstrap-TIMESTAMP
```

The old system configuration directory is moved to a path like:

```text
/etc/nixos.before-bootstrap-TIMESTAMP-PID
```

For an installer target, backups are placed under:

```text
/mnt/var/backups/nixos-bootstrap/TIMESTAMP
```

and the old target configuration is moved beside `/mnt/etc/nixos`.

If a build fails, no generation is activated. The deployed source files may have
changed, but the previous source directory is preserved at the printed backup
path.

If a newly switched generation breaks while Terminal works:

```bash
sudo nixos-rebuild switch --rollback
```

If the login screen cannot be reached, reboot and choose an older generation in
the systemd-boot menu.

## Git after creating or importing a host

The bootstrap script deliberately does not commit or push hardware changes.
Review them first:

```bash
cd ~/nixos-config
git status --short --branch
git diff -- nixos/hosts
```

Hardware files contain disk/filesystem identifiers but should never contain
passwords, private keys, authentication tokens, Wi-Fi secrets, or encryption
recovery keys.

After review, the baby-step Git workflow can save the full current configuration:

```bash
~/baby-step/update-and-push.sh
```

That workflow checks Git identity, builds before switching, snapshots selected
configuration, scans staged additions for obvious secrets, commits, pushes
without force, and verifies the remote commit.

## Files that must never be blindly migrated

Do not automatically copy or commit:

- private SSH or GPG keys;
- browser profiles, cookies, or password databases;
- API keys or login tokens;
- Wi-Fi secrets;
- disk encryption keys or recovery phrases;
- `/etc/shadow` or password hashes;
- entire home directories, caches, Steam libraries, or VM disks.

The repository and bootstrap script intentionally deploy configuration rather
than personal data.

## Troubleshooting checklist

If bootstrap reports an error:

1. Read the first `ERROR:` line.
2. Do not run random cleanup or force commands.
3. Check whether it says that anything was activated.
4. Copy the complete output into an AI conversation.
5. Attach `baby-step/system-summary-for-ai.md`.
6. Include the exact command you ran and whether the target was `/` or `/mnt`.

Useful read-only commands:

```bash
./scripts/bootstrap-nixos.sh --help
nix flake show ./nixos
nix eval --json ./nixos#nixosConfigurations --apply builtins.attrNames
git status --short --branch
```

For the current Tonelico host, the correct explicit target remains:

```text
/etc/nixos#tonelico
```
