#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this normally, not with sudo."
  exit 1
fi

NIX_DIR="/etc/nixos"
REPO="$HOME/nixos-config"
STAMP="$(date +%F-%H%M%S)"
LOCK_BACKUP="$NIX_DIR/flake.lock.before-update-$STAMP"

test -f "$NIX_DIR/flake.nix" || {
  echo "ERROR: Missing $NIX_DIR/flake.nix"
  exit 1
}

test -d "$REPO/.git" || {
  echo "ERROR: $REPO is not your Git repository."
  exit 1
}

command -v git >/dev/null || {
  echo "ERROR: git is not installed."
  exit 1
}

command -v gh >/dev/null || {
  echo "ERROR: GitHub CLI (gh) is not installed."
  exit 1
}

echo "============================================================"
echo "1. UPDATE NIXOS AND FLAKE INPUTS"
echo "============================================================"

cd "$NIX_DIR"

sudo cp -a flake.lock "$LOCK_BACKUP"
echo "Saved old lock file:"
echo "  $LOCK_BACKUP"

sudo nix flake update

echo
echo "Building before activation..."
sudo nixos-rebuild build --flake .#tonelico

echo
echo "Activating the successful build..."
sudo nixos-rebuild switch --flake .#tonelico

echo
echo "============================================================"
echo "2. UPDATE NON-NIX SYSTEM ITEMS"
echo "============================================================"

if command -v flatpak >/dev/null 2>&1; then
  echo
  echo "Updating Flatpak applications..."
  if ! flatpak update -y; then
    echo "WARNING: Flatpak update failed or was cancelled."
  fi
fi

if command -v nvim >/dev/null 2>&1 &&
   [ -d "$HOME/.config/nvim" ]; then
  echo
  echo "Updating LazyVim plugins..."
  if ! timeout 300 nvim --headless "+Lazy! sync" +qa; then
    echo "WARNING: LazyVim plugin update did not finish successfully."
  fi
fi

if command -v fwupdmgr >/dev/null 2>&1; then
  echo
  echo "Refreshing firmware metadata..."
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates || true
  echo "Firmware updates are listed only; they are not installed automatically."
fi

echo
echo "============================================================"
echo "3. AUTOMATIC HEALTH CHECKS"
echo "============================================================"

CHECK_FAILED=0

echo
echo "--- Current generation ---"
readlink -f /run/current-system
uname -r

echo
echo "--- Failed system services ---"
SYSTEM_FAILED="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
if [ -n "$SYSTEM_FAILED" ]; then
  printf '%s\n' "$SYSTEM_FAILED"
  CHECK_FAILED=1
else
  echo "OK: no failed system services"
fi

echo
echo "--- Failed user services ---"
USER_FAILED="$(systemctl --user --failed --no-legend --plain 2>/dev/null || true)"
if [ -n "$USER_FAILED" ]; then
  printf '%s\n' "$USER_FAILED"
  CHECK_FAILED=1
else
  echo "OK: no failed user services"
fi

echo
echo "--- Mango configuration ---"
if mango -c "$HOME/.config/mango/config.conf" -p; then
  echo "OK: Mango config parses"
else
  echo "FAILED: Mango config"
  CHECK_FAILED=1
fi

echo
echo "--- Noctalia ---"
if noctalia msg status; then
  echo "OK: Noctalia responds"
else
  echo "FAILED: Noctalia"
  CHECK_FAILED=1
fi

echo
echo "--- Audio ---"
if wpctl get-volume @DEFAULT_AUDIO_SINK@; then
  echo "OK: default audio output exists"
else
  echo "FAILED: no default audio output"
  CHECK_FAILED=1
fi

echo
echo "--- Network ---"
nmcli -t -f DEVICE,TYPE,STATE device status || true

echo
echo "--- Greeter ---"
printf "greetd: "
systemctl is-enabled greetd.service 2>/dev/null || true
printf "sddm:   "
systemctl is-enabled sddm.service 2>/dev/null || true

echo
echo "--- Important commands ---"
for CMD in \
  chromium kitty obs prismlauncher steam \
  nvim fetch noctalia mango wpctl
do
  if command -v "$CMD" >/dev/null 2>&1; then
    printf "OK      %-18s %s\n" "$CMD" "$(command -v "$CMD")"
  else
    printf "MISSING %-18s\n" "$CMD"
    CHECK_FAILED=1
  fi
done

echo
echo "--- Root disk ---"
df -h /

echo
echo "--- Recent generations ---"
sudo nixos-rebuild list-generations | tail -n 8

echo
echo "============================================================"
echo "4. CONFIRM BEFORE GITHUB UPLOAD"
echo "============================================================"

if [ "$CHECK_FAILED" -ne 0 ]; then
  echo "WARNING: One or more automatic checks failed."
fi

echo
echo "Quickly confirm these yourself:"
echo "  - Chromium and Kitty open"
echo "  - audio and laptop volume keys work"
echo "  - Noctalia bar and launcher work"
echo "  - screenshots go to ~/Pictures/Screenshots"
echo "  - OBS records to ~/Videos/OBS"
echo
read -r -p 'Type PUSH to sync the newest working setup to GitHub: ' ANSWER

if [ "$ANSWER" != "PUSH" ]; then
  echo "GitHub upload cancelled."
  echo "The system update itself is already active."
  exit 0
fi

echo
echo "============================================================"
echo "5. SYNC CURRENT SETUP TO THE EXISTING GITHUB REPOSITORY"
echo "============================================================"

gh auth status --hostname github.com
gh auth setup-git

cd "$REPO"
git pull --rebase --autostash origin main

echo
echo "Copying reusable NixOS files..."
sudo cp -a \
  "$NIX_DIR/flake.nix" \
  "$NIX_DIR/flake.lock" \
  "$NIX_DIR/configuration.nix" \
  "$NIX_DIR/apps-and-lotus.nix" \
  "$REPO/"

sudo chown -R "$USER":"$(id -gn)" "$REPO"

echo
echo "Ensuring hardware-configuration.nix is never uploaded..."
grep -qxF '/hardware-configuration.nix' "$REPO/.gitignore" ||
  printf '\n/hardware-configuration.nix\n' >> "$REPO/.gitignore"

git rm -f --ignore-unmatch hardware-configuration.nix
rm -f "$REPO/hardware-configuration.nix"

echo
echo "Copying current desktop and editor settings..."
mkdir -p \
  "$REPO/dotfiles/.config" \
  "$REPO/dotfiles/.local/bin" \
  "$REPO/dotfiles/.local/share/applications" \
  "$REPO/docs" \
  "$REPO/scripts"

for APP in mango kitty noctalia fcitx5 nvim fastfetch; do
  rm -rf "$REPO/dotfiles/.config/$APP"

  if [ -d "$HOME/.config/$APP" ]; then
    cp -a "$HOME/.config/$APP" \
      "$REPO/dotfiles/.config/"
  fi
done

for FILE in user-dirs.dirs mimeapps.list; do
  if [ -f "$HOME/.config/$FILE" ]; then
    cp -a "$HOME/.config/$FILE" \
      "$REPO/dotfiles/.config/"
  fi
done

echo
echo "Copying OBS path helpers..."
for FILE in obs obs-safe obs-fix-recording-paths; do
  if [ -e "$HOME/.local/bin/$FILE" ]; then
    cp -aL "$HOME/.local/bin/$FILE" \
      "$REPO/dotfiles/.local/bin/"
  fi
done

find "$HOME/.local/share/applications" \
  -maxdepth 1 \
  -type f \
  -iname '*obs*.desktop' \
  -exec cp -a {} "$REPO/dotfiles/.local/share/applications/" \; \
  2>/dev/null || true

echo
echo "Copying current guides and helper scripts..."
if [ -f "$HOME/Downloads/nixos-mango-command-guide-v4.txt" ]; then
  cp -a \
    "$HOME/Downloads/nixos-mango-command-guide-v4.txt" \
    "$REPO/docs/nixos-command-guide.txt"
fi

if [ -f "$HOME/MANGO-KEYS.txt" ]; then
  cp -a "$HOME/MANGO-KEYS.txt" "$REPO/docs/"
fi

for FILE in \
  setup-media-folders.sh \
  install-lazyvim-and-backup.sh \
  update-system-and-push.sh
do
  if [ -f "$HOME/Downloads/$FILE" ]; then
    cp -a "$HOME/Downloads/$FILE" "$REPO/scripts/"
  fi
done

echo
echo "Checking for obvious secrets..."
if grep -RniE \
  'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|password[[:space:]]*=[[:space:]]*"[^"]+"|psk[[:space:]]*=[[:space:]]*"[^"]+"' \
  "$REPO" \
  --exclude-dir=.git
then
  echo
  echo "ERROR: A possible secret was found. Nothing was committed or pushed."
  exit 1
fi

echo
echo "Committing the newest setup..."
cd "$REPO"
git add -A
git status --short

if git diff --cached --quiet; then
  echo "Nothing changed, so there is nothing new to upload."
else
  git commit -m "Update system and sync working config $STAMP"
  git push origin main
fi

echo
echo "============================================================"
echo "SUCCESS"
echo "============================================================"
echo "Updated system and GitHub repository:"
git remote get-url origin

echo
echo "Hardware configuration:"
git ls-files --error-unmatch hardware-configuration.nix 2>/dev/null \
  && echo "ERROR: hardware-configuration.nix is tracked" \
  || echo "OK: hardware-configuration.nix is not on GitHub"

test -f "$NIX_DIR/hardware-configuration.nix" \
  && echo "OK: the active hardware file remains in /etc/nixos"

echo
echo "Reboot if the kernel, graphics stack, firmware, bootloader, or greeter changed:"
echo "  sudo reboot"
