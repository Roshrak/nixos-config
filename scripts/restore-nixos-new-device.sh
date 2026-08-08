#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this as the normal user that will use the desktop."
  echo "The script will use sudo when required."
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: This saved flake is currently designed for x86_64-linux."
  echo "Detected: $(uname -m)"
  exit 1
fi

FRESH_HW="/etc/nixos/hardware-configuration.nix"

test -f "$FRESH_HW" || {
  echo "ERROR: $FRESH_HW does not exist."
  echo
  echo "Install NixOS fresh on THIS computer first."
  echo "Do not use the old computer's hardware-configuration.nix."
  exit 1
}

STAMP="$(date +%F-%H%M%S)"
HW_BACKUP="$HOME/hardware-configuration.NEW-PC.$STAMP.nix"
SYSTEM_BACKUP="/etc/nixos.before-github-restore-$STAMP"
REPO="$HOME/nixos-config"

sudo cp -a "$FRESH_HW" "$HW_BACKUP"
sudo chown "$USER":"$(id -gn)" "$HW_BACKUP"

echo "============================================================"
echo "1. NEW MACHINE HARDWARE FILE SAVED"
echo "============================================================"
echo "$HW_BACKUP"
echo
echo "This file came from THIS PC and will be restored after copying"
echo "the reusable GitHub configuration."

echo
echo "============================================================"
echo "2. GET THE GITHUB REPOSITORY"
echo "============================================================"

if [ -d "$REPO/.git" ]; then
  echo "Existing repository found: $REPO"
  git -C "$REPO" pull --rebase --autostash
else
  echo
  echo "Enter your GitHub repository."
  echo "Example: yourname/nixos-config"
  read -r -p 'Repository: ' GH_REPO

  test -n "$GH_REPO" || {
    echo "ERROR: repository was empty."
    exit 1
  }

  if command -v gh >/dev/null 2>&1; then
    gh auth status --hostname github.com || gh auth login
    gh repo clone "$GH_REPO" "$REPO"
  else
    echo
    echo "GitHub CLI is not installed."
    echo "Using a temporary Nix shell with git + gh."
    nix shell nixpkgs#git nixpkgs#gh -c bash -lc \
      "gh auth status --hostname github.com || gh auth login; gh repo clone '$GH_REPO' '$REPO'"
  fi
fi

if [ -f "$REPO/nixos/flake.nix" ]; then
  SRC="$REPO/nixos"
else
  SRC="$REPO"
fi

test -f "$SRC/flake.nix" || {
  echo "ERROR: No flake.nix found in $SRC"
  exit 1
}

echo
echo "============================================================"
echo "3. BACK UP THE FRESH /etc/nixos"
echo "============================================================"

sudo cp -a /etc/nixos "$SYSTEM_BACKUP"
echo "$SYSTEM_BACKUP"

echo
echo "============================================================"
echo "4. RESTORE REUSABLE NIXOS CONFIG"
echo "============================================================"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy the saved reusable config to a temporary directory.
tar -C "$SRC" -cf - . |
  tar -C "$TMP" --no-same-owner -xf -

# Absolutely refuse an old hardware file even if one somehow exists.
rm -f "$TMP/hardware-configuration.nix"

# Replace /etc/nixos content, then put the fresh hardware file back.
sudo find /etc/nixos -mindepth 1 -maxdepth 1 -exec rm -rf {} +
sudo tar -C "$TMP" -cf - . |
  sudo tar -C /etc/nixos -xf -

sudo install -o root -g root -m 0644 \
  "$HW_BACKUP" \
  /etc/nixos/hardware-configuration.nix

echo "Fresh machine hardware file restored:"
echo "  /etc/nixos/hardware-configuration.nix"

echo
echo "============================================================"
echo "5. RESTORE USER CONFIG"
echo "============================================================"

if [ -d "$REPO/dotfiles/.config" ]; then
  mkdir -p "$HOME/.config"
  cp -a "$REPO/dotfiles/.config/." "$HOME/.config/"
fi

if [ -d "$REPO/dotfiles/.local/bin" ]; then
  mkdir -p "$HOME/.local/bin"
  cp -a "$REPO/dotfiles/.local/bin/." "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/"* 2>/dev/null || true
fi

if [ -d "$REPO/dotfiles/.local/share/applications" ]; then
  mkdir -p "$HOME/.local/share/applications"
  cp -a "$REPO/dotfiles/.local/share/applications/." \
    "$HOME/.local/share/applications/"
fi

echo
echo "============================================================"
echo "6. SHOW NEW HARDWARE + POSSIBLE MACHINE-SPECIFIC SETTINGS"
echo "============================================================"

echo
echo "--- CPU ---"
lscpu | grep -E 'Architecture|Vendor ID|Model name' || true

echo
echo "--- GPU ---"
if command -v lspci >/dev/null 2>&1; then
  lspci | grep -Ei 'VGA|3D|Display' || true
else
  nix shell nixpkgs#pciutils -c lspci |
    grep -Ei 'VGA|3D|Display' || true
fi

echo
echo "--- Hardware-specific words inside restored Nix files ---"
grep -RniE \
  'intel|nvidia|amdgpu|iHD|modesetting|videoDrivers|updateMicrocode' \
  /etc/nixos \
  --include='*.nix' || true

echo
echo "IMPORTANT:"
echo "  hardware-configuration.nix is from THIS new PC."
echo "  CPU/GPU settings in other .nix files may still be specific"
echo "  to the old Intel Tonelico laptop."

echo
echo "============================================================"
echo "7. BUILD FIRST — DO NOT SWITCH YET"
echo "============================================================"

sudo nixos-rebuild build --flake /etc/nixos#tonelico

echo
echo "BUILD SUCCEEDED."
echo
echo "Review the CPU/GPU information above."
echo
echo "If this new PC has AMD or NVIDIA hardware, make sure the old"
echo "Intel-specific settings have been adjusted before switching."
echo
read -r -p 'Type SWITCH to activate the restored configuration: ' ANSWER

if [ "$ANSWER" != "SWITCH" ]; then
  echo
  echo "Stopped safely after a successful build."
  echo "Nothing was switched."
  echo
  echo "Edit /etc/nixos as needed, then run:"
  echo "  sudo nixos-rebuild build --flake /etc/nixos#tonelico"
  echo "  sudo nixos-rebuild switch --flake /etc/nixos#tonelico"
  exit 0
fi

sudo nixos-rebuild switch --flake /etc/nixos#tonelico

echo
echo "============================================================"
echo "RESTORE COMPLETE"
echo "============================================================"
echo
echo "Reboot:"
echo "  sudo reboot"
echo
echo "After reboot test graphics, Wi-Fi, Bluetooth, audio,"
echo "suspend/resume, Mango, Noctalia, Steam, OBS and external displays."
