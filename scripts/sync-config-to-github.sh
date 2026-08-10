#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this as your normal user, not with sudo."
  exit 1
fi

NIX_DIR="/etc/nixos"
REPO="$HOME/nixos-config"
STAMP="$(date +%F-%H%M%S)"
GUIDE="$HOME/Downloads/nixos-mango-command-guide-v5.txt"

test -f "$NIX_DIR/flake.nix" || {
  echo "ERROR: $NIX_DIR/flake.nix does not exist."
  exit 1
}

test -d "$REPO/.git" || {
  echo "ERROR: $REPO is not an existing Git repository."
  echo "Clone your repository there first."
  exit 1
}

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is not installed."
  exit 1
}

cd "$REPO"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

echo "============================================================"
echo "1. UPDATE LOCAL GITHUB WORKING COPY"
echo "============================================================"

if ! git pull --rebase --autostash origin "$BRANCH"; then
  echo
  echo "git pull failed. Trying GitHub CLI authentication..."

  if command -v gh >/dev/null 2>&1; then
    gh auth status --hostname github.com
    gh auth setup-git
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#gh -c gh auth status --hostname github.com
    nix shell nixpkgs#gh -c gh auth setup-git
  else
    echo "ERROR: gh is unavailable and nix cannot provide it temporarily."
    exit 1
  fi

  git pull --rebase --autostash origin "$BRANCH"
fi

echo
echo "============================================================"
echo "2. SNAPSHOT REUSABLE /etc/nixos"
echo "============================================================"

rm -rf "$REPO/nixos"
mkdir -p "$REPO/nixos"

sudo tar -C "$NIX_DIR" -cf - . |
  tar -C "$REPO/nixos" --no-same-owner -xf -

# Never preserve the machine-generated hardware file in Git.
rm -f "$REPO/nixos/hardware-configuration.nix"
find "$REPO/nixos" -maxdepth 2 -type f \
  \( -name 'flake.lock.before-*' -o -name '*.before-*' \) \
  -delete 2>/dev/null || true
rm -rf "$REPO/nixos/result" "$REPO/nixos/result-"* 2>/dev/null || true

# Keep the traditional root files updated too, so old restore commands
# and GitHub browsing remain convenient.
for F in flake.nix flake.lock configuration.nix apps-and-lotus.nix; do
  if [ -f "$NIX_DIR/$F" ]; then
    cp -a "$NIX_DIR/$F" "$REPO/$F"
  fi
done

echo
echo "Ensuring hardware-configuration.nix is excluded everywhere..."

grep -qxF '/hardware-configuration.nix' "$REPO/.gitignore" 2>/dev/null ||
  printf '\n/hardware-configuration.nix\n' >> "$REPO/.gitignore"

grep -qxF '/nixos/hardware-configuration.nix' "$REPO/.gitignore" 2>/dev/null ||
  printf '/nixos/hardware-configuration.nix\n' >> "$REPO/.gitignore"

git rm -f --ignore-unmatch hardware-configuration.nix >/dev/null 2>&1 || true
git rm -f --ignore-unmatch nixos/hardware-configuration.nix >/dev/null 2>&1 || true
rm -f "$REPO/hardware-configuration.nix"

echo
echo "============================================================"
echo "3. SNAPSHOT CURRENT USER CONFIG"
echo "============================================================"

mkdir -p \
  "$REPO/dotfiles/.config" \
  "$REPO/dotfiles/.local/bin" \
  "$REPO/dotfiles/.local/share/applications" \
  "$REPO/docs" \
  "$REPO/scripts"

for APP in mango kitty noctalia fcitx5 nvim fastfetch; do
  rm -rf "$REPO/dotfiles/.config/$APP"

  if [ -d "$HOME/.config/$APP" ]; then
    cp -a "$HOME/.config/$APP" "$REPO/dotfiles/.config/"
  fi
done

for FILE in user-dirs.dirs mimeapps.list; do
  rm -f "$REPO/dotfiles/.config/$FILE"

  if [ -f "$HOME/.config/$FILE" ]; then
    cp -a "$HOME/.config/$FILE" "$REPO/dotfiles/.config/"
  fi
done

# Custom command wrappers/helpers.
for FILE in \
  mango-animation \
  steam \
  obs \
  obs-safe \
  obs-fix-recording-paths
do
  rm -f "$REPO/dotfiles/.local/bin/$FILE"

  if [ -e "$HOME/.local/bin/$FILE" ]; then
    cp -aL "$HOME/.local/bin/$FILE" "$REPO/dotfiles/.local/bin/"
  fi
done

# Custom desktop-launcher overrides.
for FILE in steam.desktop obs.desktop com.obsproject.Studio.desktop; do
  rm -f "$REPO/dotfiles/.local/share/applications/$FILE"

  if [ -f "$HOME/.local/share/applications/$FILE" ]; then
    cp -a "$HOME/.local/share/applications/$FILE" \
      "$REPO/dotfiles/.local/share/applications/"
  fi
done

# Also collect any OBS-specific local desktop override.
find "$HOME/.local/share/applications" \
  -maxdepth 1 -type f -iname '*obs*.desktop' \
  -exec cp -a {} "$REPO/dotfiles/.local/share/applications/" \; \
  2>/dev/null || true

echo
echo "============================================================"
echo "4. COPY GUIDE + RECOVERY SCRIPTS"
echo "============================================================"

if [ -f "$GUIDE" ]; then
  cp -a "$GUIDE" "$REPO/docs/nixos-command-guide.txt"
  cp -a "$GUIDE" "$REPO/docs/nixos-mango-command-guide-v5.txt"
else
  echo "WARNING: $GUIDE was not found, so the V5 guide was not refreshed."
fi

if [ -f "$HOME/MANGO-KEYS.txt" ]; then
  cp -a "$HOME/MANGO-KEYS.txt" "$REPO/docs/"
fi

for FILE in \
  update-system-and-push.sh \
  update-system-and-push-v2.sh \
  sync-config-to-github.sh \
  restore-nixos-new-device.sh \
  setup-media-folders.sh \
  install-lazyvim-and-backup.sh
do
  if [ -f "$HOME/Downloads/$FILE" ]; then
    cp -a "$HOME/Downloads/$FILE" "$REPO/scripts/"
  fi
done

echo
echo "============================================================"
echo "5. SECRET CHECK"
echo "============================================================"

if grep -RniE \
  'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|password[[:space:]]*=[[:space:]]*"[^"]+"|psk[[:space:]]*=[[:space:]]*"[^"]+"' \
  "$REPO" \
  --exclude-dir=.git
then
  echo
  echo "ERROR: Possible secret found."
  echo "Nothing was committed or pushed."
  exit 1
fi

echo "No obvious secret pattern found."

echo
echo "============================================================"
echo "6. COMMIT + PUSH"
echo "============================================================"

cd "$REPO"
git add -A

echo
echo "Changes:"
git status --short

if git diff --cached --quiet; then
  echo
  echo "Nothing changed. GitHub is already up to date."
  exit 0
fi

git commit -m "Sync newest NixOS config $STAMP"

if ! git push origin "$BRANCH"; then
  echo
  echo "git push failed. Trying GitHub CLI authentication..."

  if command -v gh >/dev/null 2>&1; then
    gh auth status --hostname github.com
    gh auth setup-git
    git push origin "$BRANCH"
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#gh -c bash -lc \
      "gh auth status --hostname github.com && gh auth setup-git && git -C '$REPO' push origin '$BRANCH'"
  else
    exit 1
  fi
fi

echo
echo "============================================================"
echo "DONE"
echo "============================================================"
echo "Newest reusable config pushed to GitHub."
echo "hardware-configuration.nix was NOT uploaded."
echo
echo "Repository:"
echo "  $REPO"
echo
echo "Current system snapshot:"
echo "  $REPO/nixos"
echo
echo "Guide:"
echo "  $REPO/docs/nixos-command-guide.txt"
