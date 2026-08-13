#!/usr/bin/env bash
set -Eeuo pipefail

# Sync the CURRENT Tonelico NixOS setup to the existing GitHub repository.
#
# Existing repo:
#   ~/nixos-config
#
# Captures:
#   - reusable /etc/nixos snapshot (including new modules such as tonelico-deck.nix,
#     comic-mono.nix, fonts, etc. if they currently exist)
#   - Mango / Kitty / Noctalia / Fcitx5 / Neovim / Fastfetch
#   - user-dirs + mimeapps
#   - local command wrappers and desktop overrides
#   - current recovery/update scripts
#   - all Tonelico Deck installer/repair scripts from ~/Downloads
#   - the correct Comic Mono + End-4 Kitty cursor-trail installer if present
#
# Intentionally DOES NOT upload:
#   - hardware-configuration.nix
#   - ~/.local/share/tonelico-deck runtime state
#     (pairing token, private keys/certs, logs, runtime-generated state)
#
# Nothing is force-pushed.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this normally, NOT with sudo."
  exit 1
fi

NIX_DIR="/etc/nixos"
REPO="$HOME/nixos-config"
STAMP="$(date +%F-%H%M%S)"
GUIDE="$HOME/Downloads/nixos-mango-command-guide-v5.txt"
SELF="$(readlink -f "$0")"

test -f "$NIX_DIR/flake.nix" || {
  echo "ERROR: $NIX_DIR/flake.nix does not exist."
  exit 1
}

test -d "$REPO/.git" || {
  echo "ERROR: $REPO is not your existing Git repository."
  exit 1
}

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is not installed."
  exit 1
}

cd "$REPO"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
REMOTE="$(git remote get-url origin)"

echo "============================================================"
echo " CURRENT TONELICO -> GITHUB"
echo "============================================================"
echo "Repository: $REMOTE"
echo "Branch:     $BRANCH"
echo

echo "1. Updating local working copy..."
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
    echo "ERROR: GitHub authentication is unavailable."
    exit 1
  fi

  git pull --rebase --autostash origin "$BRANCH"
fi

echo
echo "2. Snapshotting current reusable /etc/nixos..."

rm -rf "$REPO/nixos"
mkdir -p "$REPO/nixos"

sudo tar -C "$NIX_DIR" -cf - . |
  tar -C "$REPO/nixos" --no-same-owner -xf -

# Machine-specific / generated files must never be part of the reusable backup.
rm -f "$REPO/nixos/hardware-configuration.nix"

find "$REPO/nixos" -type f \
  \( -name 'flake.lock.before-*' \
     -o -name '*.before-*' \
     -o -name '*.bak' \
     -o -name '*.bak.*' \) \
  -delete 2>/dev/null || true

find "$REPO/nixos" -maxdepth 2 -type d \
  \( -name 'result' -o -name 'result-*' \) \
  -prune -exec rm -rf {} + 2>/dev/null || true

# Keep legacy root copies for convenient GitHub browsing / old restore commands.
for F in flake.nix flake.lock configuration.nix apps-and-lotus.nix; do
  if [[ -f "$NIX_DIR/$F" ]]; then
    cp -a "$NIX_DIR/$F" "$REPO/$F"
  fi
done

touch "$REPO/.gitignore"

for IGNORE in \
  '/hardware-configuration.nix' \
  '/nixos/hardware-configuration.nix' \
  '/result' \
  '/result-*' \
  '*.pem' \
  '*.key' \
  '*.p12' \
  '*.pfx' \
  '.env' \
  '.env.*'
do
  grep -qxF "$IGNORE" "$REPO/.gitignore" 2>/dev/null ||
    printf '%s\n' "$IGNORE" >>"$REPO/.gitignore"
done

git rm -f --ignore-unmatch hardware-configuration.nix >/dev/null 2>&1 || true
git rm -f --ignore-unmatch nixos/hardware-configuration.nix >/dev/null 2>&1 || true
rm -f "$REPO/hardware-configuration.nix"

echo
echo "3. Snapshotting current user configuration..."

mkdir -p \
  "$REPO/dotfiles/.config" \
  "$REPO/dotfiles/.local/bin" \
  "$REPO/dotfiles/.local/share/applications" \
  "$REPO/docs" \
  "$REPO/scripts"

for APP in mango kitty noctalia fcitx5 nvim fastfetch; do
  rm -rf "$REPO/dotfiles/.config/$APP"

  if [[ -d "$HOME/.config/$APP" ]]; then
    cp -a "$HOME/.config/$APP" "$REPO/dotfiles/.config/"
  fi
done

for FILE in user-dirs.dirs mimeapps.list; do
  rm -f "$REPO/dotfiles/.config/$FILE"

  if [[ -f "$HOME/.config/$FILE" ]]; then
    cp -a "$HOME/.config/$FILE" "$REPO/dotfiles/.config/"
  fi
done

for FILE in \
  mango-animation \
  steam \
  obs \
  obs-safe \
  obs-fix-recording-paths
do
  rm -f "$REPO/dotfiles/.local/bin/$FILE"

  if [[ -e "$HOME/.local/bin/$FILE" ]]; then
    cp -aL "$HOME/.local/bin/$FILE" "$REPO/dotfiles/.local/bin/"
  fi
done

for FILE in steam.desktop obs.desktop com.obsproject.Studio.desktop; do
  rm -f "$REPO/dotfiles/.local/share/applications/$FILE"

  if [[ -f "$HOME/.local/share/applications/$FILE" ]]; then
    cp -a "$HOME/.local/share/applications/$FILE" \
      "$REPO/dotfiles/.local/share/applications/"
  fi
done

find "$HOME/.local/share/applications" \
  -maxdepth 1 -type f -iname '*obs*.desktop' \
  -exec cp -a {} "$REPO/dotfiles/.local/share/applications/" \; \
  2>/dev/null || true

echo
echo "4. Saving current helper/recovery scripts..."

if [[ -f "$GUIDE" ]]; then
  cp -a "$GUIDE" "$REPO/docs/nixos-command-guide.txt"
  cp -a "$GUIDE" "$REPO/docs/nixos-mango-command-guide-v5.txt"
fi

if [[ -f "$HOME/MANGO-KEYS.txt" ]]; then
  cp -a "$HOME/MANGO-KEYS.txt" "$REPO/docs/"
fi

# Existing core scripts.
for FILE in \
  update-system-and-push.sh \
  update-system-and-push-v2.sh \
  sync-config-to-github.sh \
  restore-nixos-new-device.sh \
  setup-media-folders.sh \
  install-lazyvim-and-backup.sh
do
  if [[ -f "$HOME/Downloads/$FILE" ]]; then
    cp -a "$HOME/Downloads/$FILE" "$REPO/scripts/"
  fi
done

# Current Tonelico Deck build/repair scripts.
# These are installers only; runtime secrets under ~/.local/share/tonelico-deck
# are intentionally NOT copied.
find "$HOME/Downloads" -maxdepth 1 -type f \
  -name 'tonelico-deck-*.sh' \
  -exec cp -a {} "$REPO/scripts/" \; \
  2>/dev/null || true

# Keep only the correct current font/terminal-effect installer.
if [[ -f "$HOME/Downloads/tonelico-comic-mono-end4-terminal-trail.sh" ]]; then
  cp -a \
    "$HOME/Downloads/tonelico-comic-mono-end4-terminal-trail.sh" \
    "$REPO/scripts/"
fi

# Explicitly do not preserve the superseded window-animation installer.
rm -f "$REPO/scripts/tonelico-comic-mono-end4-kitty.sh"

# Store this new sync script too.
cp -a "$SELF" "$REPO/scripts/sync-current-tonelico-to-github.sh"

echo
echo "5. Safety checks..."

# Explicitly make sure the private Tonelico runtime was never accidentally copied.
rm -rf \
  "$REPO/dotfiles/.local/share/tonelico-deck" \
  "$REPO/tonelico-deck-runtime" \
  2>/dev/null || true

# Known secret/private-key patterns.
if grep -RniE \
  'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|password[[:space:]]*=[[:space:]]*"[^"]+"|psk[[:space:]]*=[[:space:]]*"[^"]+"' \
  "$REPO" \
  --exclude-dir=.git
then
  echo
  echo "ERROR: Possible secret/private key found."
  echo "Nothing was committed or pushed."
  exit 1
fi

# Sensitive filenames should also stop the push rather than silently leak.
SENSITIVE="$(
  find "$REPO" \
    -path "$REPO/.git" -prune -o \
    -type f \
    \( -iname '*.key' \
       -o -iname '*.p12' \
       -o -iname '*.pfx' \
       -o -iname 'id_rsa' \
       -o -iname 'id_ed25519' \
       -o -iname '*private*key*' \
       -o -iname 'token' \
       -o -iname 'credentials*' \) \
    -print
)"

if [[ -n "$SENSITIVE" ]]; then
  echo
  echo "ERROR: Sensitive-looking files found:"
  printf '%s\n' "$SENSITIVE"
  echo "Nothing was committed or pushed."
  exit 1
fi

echo "Safety check passed."
echo

echo "6. Changes that will be pushed:"
cd "$REPO"
git add -A
git status --short

if git diff --cached --quiet; then
  echo
  echo "Nothing changed. GitHub already matches this laptop snapshot."
  exit 0
fi

echo
read -r -p 'Type PUSH to upload this current laptop version to GitHub: ' ANSWER

if [[ "$ANSWER" != "PUSH" ]]; then
  echo "Cancelled. Nothing was committed or pushed."
  exit 0
fi

echo
echo "7. Committing..."
git commit -m "Snapshot current Tonelico NixOS setup $STAMP"

echo
echo "8. Pushing to $REMOTE ($BRANCH)..."
if ! git push origin "$BRANCH"; then
  echo
  echo "Push failed. Trying GitHub CLI authentication..."

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
echo " SUCCESS"
echo "============================================================"
echo "Current Tonelico setup pushed to:"
echo "  $REMOTE"
echo
echo "Branch:"
echo "  $BRANCH"
echo
echo "Snapshot:"
echo "  $REPO/nixos"
echo
echo "hardware-configuration.nix: NOT uploaded"
echo "Tonelico Deck runtime token/certs: NOT uploaded"
echo
echo "Latest commit:"
git --no-pager log -1 --oneline
