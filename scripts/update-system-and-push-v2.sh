#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this normally, not with sudo."
  exit 1
fi

NIX_DIR="/etc/nixos"
SYNC_SCRIPT="$HOME/Downloads/sync-config-to-github.sh"
STAMP="$(date +%F-%H%M%S)"

test -f "$NIX_DIR/flake.nix" || {
  echo "ERROR: Missing $NIX_DIR/flake.nix"
  exit 1
}

echo "============================================================"
echo "1. BACK UP FLAKE LOCK"
echo "============================================================"

cd "$NIX_DIR"

if [ -f flake.lock ]; then
  sudo cp -a flake.lock "flake.lock.before-update-$STAMP"
  echo "Saved: $NIX_DIR/flake.lock.before-update-$STAMP"
else
  echo "No existing flake.lock; continuing."
fi

echo
echo "============================================================"
echo "2. UPDATE NIX FLAKE INPUTS"
echo "============================================================"

sudo nix flake update

echo
echo "============================================================"
echo "3. BUILD FIRST"
echo "============================================================"

sudo nixos-rebuild build --flake .#tonelico

echo
echo "============================================================"
echo "4. ACTIVATE SUCCESSFUL BUILD"
echo "============================================================"

sudo nixos-rebuild switch --flake .#tonelico

echo
echo "============================================================"
echo "5. UPDATE NON-NIX ITEMS"
echo "============================================================"

if command -v flatpak >/dev/null 2>&1; then
  echo
  echo "--- Flatpak ---"
  flatpak update -y || echo "WARNING: Flatpak update failed/skipped."
fi

if command -v nvim >/dev/null 2>&1 &&
   [ -d "$HOME/.config/nvim" ]; then
  echo
  echo "--- LazyVim ---"
  timeout 300 nvim --headless "+Lazy! sync" +qa ||
    echo "WARNING: LazyVim plugin sync failed/timed out."
fi

if command -v fwupdmgr >/dev/null 2>&1; then
  echo
  echo "--- Firmware metadata ---"
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates || true
  echo "Firmware was checked, not automatically installed."
fi

echo
echo "============================================================"
echo "6. HEALTH CHECK"
echo "============================================================"

WARN=0

echo
echo "--- Current system ---"
readlink -f /run/current-system
uname -r

echo
echo "--- Failed system services ---"
SYSTEM_FAILED="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
if [ -n "$SYSTEM_FAILED" ]; then
  printf '%s\n' "$SYSTEM_FAILED"
  WARN=1
else
  echo "OK"
fi

echo
echo "--- Failed user services ---"
USER_FAILED="$(systemctl --user --failed --no-legend --plain 2>/dev/null || true)"
if [ -n "$USER_FAILED" ]; then
  printf '%s\n' "$USER_FAILED"
  WARN=1
else
  echo "OK"
fi

echo
echo "--- Mango config ---"
if mango -c "$HOME/.config/mango/config.conf" -p; then
  echo "OK"
else
  echo "FAILED"
  WARN=1
fi

echo
echo "--- Noctalia ---"
noctalia msg status || {
  echo "WARNING: Noctalia did not respond."
  WARN=1
}

echo
echo "--- Audio ---"
wpctl get-volume @DEFAULT_AUDIO_SINK@ || {
  echo "WARNING: no default audio sink."
  WARN=1
}

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
for CMD in chromium kitty obs prismlauncher steam nvim \
           fetch noctalia mango wpctl; do
  if command -v "$CMD" >/dev/null 2>&1; then
    printf "OK      %-18s %s\n" "$CMD" "$(command -v "$CMD")"
  else
    printf "MISSING %-18s\n" "$CMD"
  fi
done

echo
echo "--- Disk ---"
df -h /

echo
echo "--- Recent generations ---"
sudo nixos-rebuild list-generations | tail -n 10

echo
echo "============================================================"
echo "7. MANUAL CONFIRMATION"
echo "============================================================"

[ "$WARN" -ne 0 ] &&
  echo "WARNING: one or more automatic checks need attention."

echo
echo "Quickly confirm:"
echo "  - Chromium opens"
echo "  - Kitty opens"
echo "  - audio + volume keys work"
echo "  - Noctalia bar/launcher works"
echo "  - screenshots go to ~/Pictures/Screenshots"
echo "  - OBS records to ~/Videos/OBS"
echo "  - Steam starts the way you expect"
echo
read -r -p 'Type PUSH to save this working state to GitHub: ' ANSWER

if [ "$ANSWER" != "PUSH" ]; then
  echo
  echo "GitHub upload cancelled."
  echo "The system update itself is already active."
  exit 0
fi

echo
echo "============================================================"
echo "8. SYNC NEWEST CONFIG TO GITHUB"
echo "============================================================"

if [ ! -f "$SYNC_SCRIPT" ]; then
  echo "ERROR: Missing $SYNC_SCRIPT"
  echo "Download sync-config-to-github.sh to ~/Downloads first."
  exit 1
fi

chmod +x "$SYNC_SCRIPT"
"$SYNC_SCRIPT"

echo
echo "============================================================"
echo "COMPLETE"
echo "============================================================"
echo "System updated, checked, and newest reusable config pushed."
