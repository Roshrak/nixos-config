#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this normally, not with sudo."
  exit 1
fi

if pgrep -x obs >/dev/null 2>&1; then
  echo "OBS is currently open. Close OBS, then run this script again."
  exit 1
fi

SHOT_DIR="$HOME/Pictures/Screenshots"
RECORD_DIR="$HOME/Videos/Screen Recordings"
OBS_DIR="$HOME/Videos/OBS"
NOCTALIA_DIR="$HOME/.config/noctalia"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
REPO="$HOME/nixos-config"
STAMP="$(date +%F-%H%M%S)"

echo "=== Creating clean media folders ==="
mkdir -p \
  "$SHOT_DIR" \
  "$RECORD_DIR" \
  "$OBS_DIR" \
  "$NOCTALIA_DIR" \
  "$BIN_DIR" \
  "$APP_DIR"

# Keep the standard XDG parent folders correct.
xdg-user-dirs-update --set PICTURES "$HOME/Pictures" 2>/dev/null || true
xdg-user-dirs-update --set VIDEOS "$HOME/Videos" 2>/dev/null || true

echo "=== Forcing Noctalia screenshots into $SHOT_DIR ==="
cat > "$NOCTALIA_DIR/99-media-paths.toml" <<EOF
# Managed by setup-media-folders.sh
[shell.screenshot]
save_to_file = true
directory = "$SHOT_DIR"
filename_pattern = "screenshot_%Y%m%d_%H%M%S"
copy_to_clipboard = true
EOF

noctalia config validate

echo "=== Moving existing loose screenshots ==="
find "$HOME/Pictures" -maxdepth 1 -type f \
  \( -iname 'screenshot*.png' -o -iname 'screenshot*.jpg' \
     -o -iname 'screenshot*.jpeg' -o -iname 'screen shot*.png' \
     -o -iname 'screen shot*.jpg' \) \
  -exec mv -n -t "$SHOT_DIR" -- {} + 2>/dev/null || true

find "$HOME" -maxdepth 1 -type f \
  \( -iname 'screenshot*.png' -o -iname 'screenshot*.jpg' \
     -o -iname 'screenshot*.jpeg' -o -iname 'screen shot*.png' \
     -o -iname 'screen shot*.jpg' \) \
  -exec mv -n -t "$SHOT_DIR" -- {} + 2>/dev/null || true

echo "=== Creating permanent OBS path enforcer ==="

cat > "$BIN_DIR/obs-fix-recording-paths" <<'OBS_FIX'
#!/usr/bin/env bash
set -euo pipefail

OUT="$HOME/Videos/OBS"
mkdir -p "$OUT"

set_ini_value() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  local tmp="${file}.path-fix.$$"

  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN {
      in_section = 0
      section_found = 0
      key_written = 0
    }

    /^\[[^]]+\][[:space:]]*$/ {
      if (in_section && !key_written) {
        print key "=" value
        key_written = 1
      }

      wanted = "[" section "]"
      in_section = ($0 == wanted)

      if (in_section) {
        section_found = 1
        key_written = 0
      }
    }

    {
      if (in_section && $0 ~ ("^" key "=")) {
        print key "=" value
        key_written = 1
        next
      }

      print
    }

    END {
      if (in_section && !key_written) {
        print key "=" value
      }

      if (!section_found) {
        print ""
        print "[" section "]"
        print key "=" value
      }
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

shopt -s nullglob
profiles=("$HOME/.config/obs-studio/basic/profiles/"*/basic.ini)

for file in "${profiles[@]}"; do
  cp -n "$file" "$file.before-recording-path-fix" 2>/dev/null || true

  # Simple output mode.
  set_ini_value "$file" "SimpleOutput" "FilePath" "$OUT"

  # Advanced standard recording mode.
  set_ini_value "$file" "AdvOut" "RecFilePath" "$OUT"

  # Advanced custom FFmpeg output mode.
  set_ini_value "$file" "AdvOut" "FFFilePath" "$OUT"
done
OBS_FIX
chmod +x "$BIN_DIR/obs-fix-recording-paths"

OBS_BIN="/run/current-system/sw/bin/obs"
if [ ! -x "$OBS_BIN" ]; then
  OBS_BIN="$(command -v obs || true)"
fi
if [ -z "$OBS_BIN" ] || [ ! -x "$OBS_BIN" ]; then
  echo "ERROR: OBS executable was not found."
  exit 1
fi

cat > "$BIN_DIR/obs-safe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$BIN_DIR/obs-fix-recording-paths"
exec "$OBS_BIN" "\$@"
EOF
chmod +x "$BIN_DIR/obs-safe"

# Also intercept `obs` launched from a terminal when ~/.local/bin is on PATH.
ln -sfn "$BIN_DIR/obs-safe" "$BIN_DIR/obs"

# Apply to all existing OBS profiles now.
"$BIN_DIR/obs-fix-recording-paths"

echo "=== Overriding the OBS launcher so every launch rechecks its folder ==="
SYSTEM_DESKTOP="$(
  find /run/current-system/sw/share/applications \
    -maxdepth 1 -type f \
    \( -iname 'com.obsproject.Studio.desktop' -o -iname '*obs*.desktop' \) \
    -print 2>/dev/null |
  head -n 1
)"

if [ -n "$SYSTEM_DESKTOP" ]; then
  DESKTOP_NAME="$(basename "$SYSTEM_DESKTOP")"
  cp "$SYSTEM_DESKTOP" "$APP_DIR/$DESKTOP_NAME"

  awk -v cmd="$BIN_DIR/obs-safe" '
    BEGIN { changed = 0 }
    /^Exec=/ && !changed {
      print "Exec=" cmd " %U"
      changed = 1
      next
    }
    { print }
  ' "$APP_DIR/$DESKTOP_NAME" > "$APP_DIR/$DESKTOP_NAME.tmp"

  mv "$APP_DIR/$DESKTOP_NAME.tmp" "$APP_DIR/$DESKTOP_NAME"
else
  cat > "$APP_DIR/com.obsproject.Studio.desktop" <<EOF
[Desktop Entry]
Name=OBS Studio
Comment=Free and Open Source Streaming/Recording Software
Exec=$BIN_DIR/obs-safe %U
Icon=com.obsproject.Studio
Terminal=false
Type=Application
Categories=AudioVideo;Recorder;
StartupNotify=true
EOF
fi

update-desktop-database "$APP_DIR" 2>/dev/null || true

echo "=== Moving video files that are loose in the home directory ==="
find "$HOME" -maxdepth 1 -type f \
  \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.mov' \
     -o -iname '*.webm' -o -iname '*.flv' -o -iname '*.avi' \) \
  -exec mv -n -t "$OBS_DIR" -- {} + 2>/dev/null || true

echo "=== Restarting Noctalia so the screenshot rule is active ==="
pkill -x noctalia 2>/dev/null || true
sleep 1
noctalia --daemon >/dev/null 2>&1 & disown

echo
echo "=== Result ==="
echo "Screenshots:       $SHOT_DIR"
echo "Screen recordings: $RECORD_DIR"
echo "OBS recordings:    $OBS_DIR"

echo
echo "OBS profile paths:"
grep -RHE '^(FilePath|RecFilePath|FFFilePath)=' \
  "$HOME/.config/obs-studio/basic/profiles"/*/basic.ini 2>/dev/null || \
  echo "No OBS profile exists yet. The OBS launcher will set it after OBS creates one."

echo
echo "=== Backing the new paths up to GitHub, when connected ==="
if [ -d "$REPO/.git" ]; then
  mkdir -p \
    "$REPO/dotfiles/.config" \
    "$REPO/dotfiles/.local/bin" \
    "$REPO/dotfiles/.local/share/applications"

  rm -rf "$REPO/dotfiles/.config/noctalia"
  cp -a "$HOME/.config/noctalia" "$REPO/dotfiles/.config/"

  cp -a "$BIN_DIR/obs-fix-recording-paths" "$REPO/dotfiles/.local/bin/"
  cp -a "$BIN_DIR/obs-safe" "$REPO/dotfiles/.local/bin/"
  cp -aL "$BIN_DIR/obs" "$REPO/dotfiles/.local/bin/obs"

  find "$APP_DIR" -maxdepth 1 -type f -iname '*obs*.desktop' \
    -exec cp -a {} "$REPO/dotfiles/.local/share/applications/" \;

  if [ -f "$HOME/.config/user-dirs.dirs" ]; then
    cp -a "$HOME/.config/user-dirs.dirs" \
      "$REPO/dotfiles/.config/user-dirs.dirs"
  fi

  cd "$REPO"
  git pull --rebase --autostash
  git add -A

  if git diff --cached --quiet; then
    echo "No new Git changes to upload."
  else
    git commit -m "Organize screenshots and recording folders $STAMP"
    git push
    echo "Uploaded to: $(git remote get-url origin)"
  fi
else
  echo "Skipped GitHub: $REPO is not a Git repository."
fi

echo
echo "DONE"
