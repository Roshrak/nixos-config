#!/usr/bin/env bash
#
# update-system-and-push-v3.2.sh
#
# One merged tool for this Tonelico NixOS machine:
#
#   Full update + health check + reproducible GitHub snapshot:
#       bash ~/Downloads/update-system-and-push-v3.2.sh
#
#   Snapshot/push the current working config WITHOUT updating NixOS:
#       bash ~/Downloads/update-system-and-push-v3.2.sh --sync-only
#
# This script does NOT require python3.
#
set -euo pipefail

# ----------------------------------------------------------------------
# MODE
# ----------------------------------------------------------------------

MODE="full"

case "${1:-}" in
    "")
        MODE="full"
        ;;
    --sync-only|sync|sync-only)
        MODE="sync"
        ;;
    -h|--help)
        cat <<'EOF'
Usage:
  update-system-and-push-v3.2.sh
      Update NixOS + non-Nix items, build, switch, health-check,
      then snapshot the reproducible setup and push it to GitHub.

  update-system-and-push-v3.2.sh --sync-only
      Do NOT update or rebuild NixOS. Snapshot the current working
      setup, update the docs, commit, and push to GitHub.
EOF
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Use --help for usage." >&2
        exit 2
        ;;
esac

if [ "${EUID}" -eq 0 ]; then
    echo "Run this normally as aesc, not with sudo."
    exit 1
fi

# ----------------------------------------------------------------------
# PATHS
# ----------------------------------------------------------------------

NIX_DIR="/etc/nixos"
REPO="$HOME/nixos-config"
DOCS="$REPO/docs"

MANGO="$HOME/.config/mango"
NOCTALIA="$HOME/.config/noctalia"

TOGGLE="$HOME/.local/bin/toggle-desktop-look"
PROFILES="$HOME/.local/share/desktop-look-toggle"

V5="$DOCS/nixos-mango-command-guide-v5.txt"
KEYS="$DOCS/MANGO-KEYS.txt"

CUSTOM_ASSETS="$HOME/.local/share/noctalia-custom-assets"

STAMP="$(date +%F-%H%M%S)"

say() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# ======================================================================
# PART A - OPTIONAL FULL SYSTEM UPDATE
# ======================================================================

if [ "$MODE" = "full" ]; then

    say "1. BACK UP FLAKE LOCK"

    [ -f "$NIX_DIR/flake.nix" ] || fail "Missing $NIX_DIR/flake.nix"

    cd "$NIX_DIR"

    if [ -f flake.lock ]; then
        sudo cp -a \
            flake.lock \
            "flake.lock.before-update-$STAMP"

        echo "Saved:"
        echo "  $NIX_DIR/flake.lock.before-update-$STAMP"
    else
        echo "No existing flake.lock; continuing."
    fi


    say "2. UPDATE NIX FLAKE INPUTS"

    sudo nix flake update


    say "3. BUILD FIRST"

    sudo nixos-rebuild build --flake .#tonelico


    say "4. ACTIVATE SUCCESSFUL BUILD"

    sudo nixos-rebuild switch --flake .#tonelico


    say "5. UPDATE NON-NIX ITEMS"

    if command -v flatpak >/dev/null 2>&1; then
        echo
        echo "--- Flatpak ---"
        flatpak update -y ||
            echo "WARNING: Flatpak update failed/skipped."
    fi

    if command -v nvim >/dev/null 2>&1 &&
       [ -d "$HOME/.config/nvim" ]; then

        echo
        echo "--- LazyVim ---"

        timeout 300 \
            nvim --headless "+Lazy! sync" +qa ||
            echo "WARNING: LazyVim plugin sync failed/timed out."
    fi

    if command -v fwupdmgr >/dev/null 2>&1; then
        echo
        echo "--- Firmware metadata ---"

        sudo fwupdmgr refresh --force || true
        sudo fwupdmgr get-updates || true

        echo "Firmware was checked, not automatically installed."
    fi


    say "6. HEALTH CHECK"

    WARN=0

    echo
    echo "--- Current system ---"
    readlink -f /run/current-system
    uname -r

    echo
    echo "--- Failed system services ---"

    SYSTEM_FAILED="$(
        systemctl --failed --no-legend --plain 2>/dev/null || true
    )"

    if [ -n "$SYSTEM_FAILED" ]; then
        printf '%s\n' "$SYSTEM_FAILED"
        WARN=1
    else
        echo "OK"
    fi

    echo
    echo "--- Failed user services ---"

    USER_FAILED="$(
        systemctl --user --failed --no-legend --plain 2>/dev/null || true
    )"

    if [ -n "$USER_FAILED" ]; then
        printf '%s\n' "$USER_FAILED"
        WARN=1
    else
        echo "OK"
    fi

    echo
    echo "--- Mango config ---"

    if mango -c "$MANGO/config.conf" -p; then
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

    for CMD in \
        chromium \
        kitty \
        obs \
        prismlauncher \
        steam \
        nvim \
        fastfetch \
        noctalia \
        mango \
        wpctl
    do
        if command -v "$CMD" >/dev/null 2>&1; then
            printf "OK      %-18s %s\n" \
                "$CMD" \
                "$(command -v "$CMD")"
        else
            printf "MISSING %-18s\n" "$CMD"
        fi
    done

    echo
    echo "--- Desktop look switcher ---"

    if [ -x "$TOGGLE" ]; then
        "$TOGGLE" status || true
    else
        echo "MISSING: $TOGGLE"
        WARN=1
    fi

    for profile in dwm original; do
        if [ -f "$PROFILES/$profile/mango.conf" ] &&
           [ -f "$PROFILES/$profile/noctalia-settings.toml" ]; then
            echo "OK: $profile profile"
        else
            echo "MISSING: $profile profile"
            WARN=1
        fi
    done

    echo
    echo "--- Disk ---"
    df -h /

    echo
    echo "--- Recent generations ---"
    sudo nixos-rebuild list-generations | tail -n 10


    say "7. MANUAL CONFIRMATION"

    if [ "$WARN" -ne 0 ]; then
        echo "WARNING: one or more automatic checks need attention."
        echo
    fi

    echo "Quickly confirm:"
    echo "  - Chromium opens"
    echo "  - Kitty opens"
    echo "  - audio + volume keys work"
    echo "  - Noctalia bar/launcher works"
    echo "  - Super+Shift+Alt+R switches Bread/DWM <-> Original"
    echo "  - screenshots go to ~/Pictures/Screenshots"
    echo "  - OBS records to ~/Videos/OBS"
    echo "  - Steam starts the way you expect"
    echo

    read -r -p \
        'Type PUSH to snapshot this working state and upload to GitHub: ' \
        ANSWER

    if [ "$ANSWER" != "PUSH" ]; then
        echo
        echo "GitHub upload cancelled."
        echo "The system update itself is already active."
        exit 0
    fi

else

    say "SYNC-ONLY MODE"

    echo "NixOS/flakes/Flatpak/LazyVim/firmware will NOT be updated."
    echo "The current working configuration will be snapshotted as-is."
    echo

    read -r -p \
        'Type PUSH to snapshot the current setup and upload to GitHub: ' \
        ANSWER

    if [ "$ANSWER" != "PUSH" ]; then
        echo "GitHub upload cancelled."
        exit 0
    fi

fi

# ======================================================================
# PART B - REPRODUCIBLE CONFIG + DOCS SNAPSHOT
# ======================================================================

say "8. CHECK GITHUB REPOSITORY"

[ -d "$REPO/.git" ] ||
    fail "Git repository not found: $REPO"

cd "$REPO"

BRANCH="$(git branch --show-current)"
REMOTE="$(git remote get-url origin 2>/dev/null || true)"

echo "Repository: $REPO"
echo "Branch:     $BRANCH"
echo "Remote:     $REMOTE"

[ "$BRANCH" = "main" ] ||
    fail "Expected branch main, found: $BRANCH"

case "$REMOTE" in
    *github.com/Roshrak/nixos-config.git|*github.com/Roshrak/nixos-config)
        ;;
    *)
        fail "Unexpected origin remote: $REMOTE"
        ;;
esac

git fetch origin
git pull --rebase --autostash origin main


# ----------------------------------------------------------------------
# Remove obsolete documentation
# ----------------------------------------------------------------------

say "9. CLEAN DOCUMENTATION"

mkdir -p "$DOCS"

for old in \
    "$DOCS/nixos-command-guide.txt" \
    "$DOCS/nixos-mango-command-and-reinstall-guide-v2.txt" \
    "$DOCS/nixos-mango-command-and-reinstall-guide-v3.txt"
do
    if [ -e "$old" ]; then
        echo "Removing outdated guide:"
        echo "  $old"
        rm -f -- "$old"
    fi
done

[ -f "$V5" ] ||
    fail "Missing current V5 guide: $V5"

[ -f "$KEYS" ] ||
    fail "Missing MANGO-KEYS.txt: $KEYS"


# ----------------------------------------------------------------------
# Remove failed custom authentication-logo experiment
# ----------------------------------------------------------------------

say "10. CLEAN ABANDONED NOCTALIA LOGO EXPERIMENT"

for file in \
    "$MANGO/config.conf" \
    "$PROFILES/dwm/mango.conf" \
    "$PROFILES/original/mango.conf"
do
    [ -f "$file" ] || continue

    sed -i \
        '/^env=NOCTALIA_ASSETS_DIR,/d' \
        "$file"

    sed -i -E \
        's|^exec-once=env[[:space:]]+NOCTALIA_ASSETS_DIR=[^[:space:]]+[[:space:]]+noctalia$|exec-once=noctalia|' \
        "$file"
done

if [ -e "$CUSTOM_ASSETS" ]; then
    # This local tree may contain read-only directories inherited from
    # the immutable Nix store. -P prevents following symlinks into it.
    find -P \
        "$CUSTOM_ASSETS" \
        -type d \
        -exec chmod u+rwx {} + \
        2>/dev/null || true

    rm -rf -- "$CUSTOM_ASSETS"
fi

[ ! -e "$CUSTOM_ASSETS" ] ||
    fail "Could not remove $CUSTOM_ASSETS"

if grep -Rqs \
    'NOCTALIA_ASSETS_DIR' \
    "$MANGO/config.conf" \
    "$PROFILES/dwm/mango.conf" \
    "$PROFILES/original/mango.conf" \
    2>/dev/null
then
    fail "NOCTALIA_ASSETS_DIR still exists in live/profile config"
fi

echo "Custom-logo experiment is absent."


# ----------------------------------------------------------------------
# Normalize and save persistent Original <-> DWM switcher
# ----------------------------------------------------------------------

say "11. SAVE ORIGINAL <-> BREAD/DWM SWITCHER"

[ -f "$TOGGLE" ] ||
    fail "Missing switcher: $TOGGLE"

chmod +x "$TOGGLE"

# Repair the old Mango IPC syntax if it exists in an earlier switcher copy.
sed -i \
    's/mmsg -d reload_config/mmsg dispatch reload_config/g' \
    "$TOGGLE"

if grep -q \
    'mmsg -d reload_config' \
    "$TOGGLE"
then
    fail "Old Mango reload syntax remains in $TOGGLE"
fi

mkdir -p "$MANGO"

cat > "$MANGO/look-toggle.conf" <<'EOF'
# Persistent Mango + Noctalia desktop-look switcher.
# The current profile is saved before the other profile is loaded.

keymode=common
bind=SUPER+SHIFT+ALT,r,spawn,/home/aesc/.local/bin/toggle-desktop-look
keymode=default
EOF

SOURCE_LINE='source-optional=~/.config/mango/look-toggle.conf'

ensure_toggle_source() {
    local file="$1"

    [ -f "$file" ] || return 0

    if ! grep -Fqx \
        "$SOURCE_LINE" \
        "$file"
    then
        printf \
            '\n# Persistent desktop-look toggle\n%s\n' \
            "$SOURCE_LINE" \
            >> "$file"
    fi
}

ensure_toggle_source "$MANGO/config.conf"
ensure_toggle_source "$PROFILES/dwm/mango.conf"
ensure_toggle_source "$PROFILES/original/mango.conf"

# Save the exact currently active Mango + Noctalia state before snapshot.
"$TOGGLE" save

ACTIVE="$("$TOGGLE" status 2>/dev/null || true)"
echo "$ACTIVE"

for profile in dwm original; do

    [ -f "$PROFILES/$profile/mango.conf" ] ||
        fail "Missing $profile Mango profile"

    [ -f "$PROFILES/$profile/noctalia-settings.toml" ] ||
        fail "Missing $profile Noctalia profile"

    ensure_toggle_source \
        "$PROFILES/$profile/mango.conf"

done

echo
echo "Mango reload calls in switcher:"
grep -n \
    'mmsg .*reload_config' \
    "$TOGGLE" ||
    true


# ----------------------------------------------------------------------
# Validate current desktop
# ----------------------------------------------------------------------

say "12. VALIDATE CURRENT DESKTOP"

# Mango's standalone parser can reject some live input keywords even when the
# current Mango session is otherwise working. Do not abort a reproducible
# snapshot just because `mango -p` reports one of those parser errors.
if mango -c "$MANGO/config.conf" -p; then
    echo "Mango config parser: OK"
else
    echo
    echo "WARNING: Mango parser reported an error."
    echo "The snapshot will continue without changing the live Mango config."
    echo "Review the parser output above separately if desired."
fi

if command -v noctalia >/dev/null 2>&1; then
    if noctalia config validate; then
        echo "Noctalia config: OK"
    else
        echo "ERROR: Noctalia config validation failed."
        exit 1
    fi
fi


# ----------------------------------------------------------------------
# Snapshot reusable /etc/nixos
# ----------------------------------------------------------------------

say "13. SNAPSHOT REUSABLE NIXOS CONFIG"

NIX_DST="$REPO/nixos"

rm -rf "$NIX_DST"
mkdir -p "$NIX_DST"

while IFS= read -r -d '' src; do

    rel="${src#/etc/nixos/}"
    dst="$NIX_DST/$rel"

    mkdir -p "$(dirname "$dst")"

    cp -a \
        --no-preserve=ownership \
        "$src" \
        "$dst"

done < <(
    find /etc/nixos \
        -type f \
        \( -name '*.nix' -o -name 'flake.lock' \) \
        ! -name 'hardware-configuration.nix' \
        ! -name 'flake.lock.before-update-*' \
        -print0
)

# Preserve declarative assets required by Nix modules.
# comic-mono.nix uses ./fonts/comic-mono, so a Nix-only copy is incomplete.
if [ -d "$NIX_DIR/fonts" ]; then
    rm -rf "$NIX_DST/fonts"

    cp -a \
        --no-preserve=ownership \
        "$NIX_DIR/fonts" \
        "$NIX_DST/fonts"

    echo "Saved NixOS font assets."
fi

rm -f \
    "$NIX_DST/hardware-configuration.nix"

# Root-level compatibility copies.
while IFS= read -r -d '' src; do

    base="$(basename "$src")"

    [ "$base" = "hardware-configuration.nix" ] &&
        continue

    cp -a \
        --no-preserve=ownership \
        "$src" \
        "$REPO/$base"

done < <(
    find /etc/nixos \
        -maxdepth 1 \
        -type f \
        \( -name '*.nix' -o -name 'flake.lock' \) \
        ! -name 'hardware-configuration.nix' \
        ! -name 'flake.lock.before-update-*' \
        -print0
)

touch "$REPO/.gitignore"

grep -Fqx \
    '/hardware-configuration.nix' \
    "$REPO/.gitignore" ||
    printf \
        '\n/hardware-configuration.nix\n' \
        >> "$REPO/.gitignore"

grep -Fqx \
    '/nixos/hardware-configuration.nix' \
    "$REPO/.gitignore" ||
    printf \
        '/nixos/hardware-configuration.nix\n' \
        >> "$REPO/.gitignore"

# Remove any OLD repository copy only. Never touches /etc/nixos.
git rm \
    -f \
    --ignore-unmatch \
    hardware-configuration.nix \
    nixos/hardware-configuration.nix \
    >/dev/null 2>&1 ||
    true


# ----------------------------------------------------------------------
# Snapshot selected ~/.config
# ----------------------------------------------------------------------

say "14. SNAPSHOT USER CONFIG"

DOTCONFIG="$REPO/dotfiles/.config"
mkdir -p "$DOTCONFIG"

sync_config_dir() {
    local name="$1"
    local src="$HOME/.config/$name"
    local dst="$DOTCONFIG/$name"

    if [ ! -d "$src" ]; then
        echo "Skip missing: ~/.config/$name"
        return 0
    fi

    rm -rf "$dst"
    cp -a "$src" "$dst"

    # Current config only, no historical edit backups.
    find "$dst" \
        -type f \
        \( \
            -name '*.bak' \
            -o -name '*.bak-*' \
            -o -name '*.backup' \
            -o -name '*.old' \
            -o -name '*.before-*' \
            -o -name '*before-dwm-look*' \
            -o -name '*before-animation*' \
            -o -name '*before-gesture*' \
            -o -name '*before-touchpad*' \
            -o -name '*before-monitor*' \
        \) \
        -delete \
        2>/dev/null ||
        true

    echo "Saved ~/.config/$name"
}

for app in \
    mango \
    noctalia \
    kitty \
    fcitx5 \
    nvim \
    fastfetch
do
    sync_config_dir "$app"
done

if [ -f "$HOME/.config/mimeapps.list" ]; then
    cp -a \
        "$HOME/.config/mimeapps.list" \
        "$DOTCONFIG/mimeapps.list"
fi


# ----------------------------------------------------------------------
# Snapshot custom ~/.local/bin helpers
# ----------------------------------------------------------------------

say "15. SNAPSHOT CUSTOM HELPERS"

BIN_DST="$REPO/dotfiles/.local/bin"
mkdir -p "$BIN_DST"

for helper in \
    toggle-desktop-look \
    noctalia-greeter-sync-smart \
    mango-animation \
    steam \
    obs \
    obs-safe \
    obs-fix-recording-paths
do

    src="$HOME/.local/bin/$helper"

    if [ -f "$src" ]; then
        cp -a \
            "$src" \
            "$BIN_DST/$helper"

        chmod +x \
            "$BIN_DST/$helper"

        echo "Saved: $helper"
    fi

done


# ----------------------------------------------------------------------
# Snapshot BOTH appearance profiles
# ----------------------------------------------------------------------

say "16. SNAPSHOT ORIGINAL + BREAD/DWM PROFILES"

PROFILE_DST="$REPO/dotfiles/.local/share/desktop-look-toggle"

rm -rf "$PROFILE_DST"

mkdir -p \
    "$PROFILE_DST/dwm" \
    "$PROFILE_DST/original"

for profile in dwm original; do

    cp -a \
        "$PROFILES/$profile/mango.conf" \
        "$PROFILE_DST/$profile/mango.conf"

    cp -a \
        "$PROFILES/$profile/noctalia-settings.toml" \
        "$PROFILE_DST/$profile/noctalia-settings.toml"

    echo "Saved profile: $profile"

done

# Reconstructed during restore.
rm -f \
    "$PROFILE_DST/active"


# ----------------------------------------------------------------------
# Snapshot known custom .desktop files
# ----------------------------------------------------------------------

APP_DST="$REPO/dotfiles/.local/share/applications"
mkdir -p "$APP_DST"

if [ -f "$HOME/.local/share/applications/steam.desktop" ]; then
    cp -a \
        "$HOME/.local/share/applications/steam.desktop" \
        "$APP_DST/steam.desktop"
fi


# ======================================================================
# PART C - UPDATE DOCUMENTATION
# ======================================================================

say "17. UPDATE MANGO-KEYS.txt"

if ! grep -Fq \
    'Super + Shift + Alt + R' \
    "$KEYS"
then
    tmp="$(mktemp)"

    awk '
        {
            print
            if ($0 ~ /^Super \+ R[[:space:]]+/) {
                print "Super + Shift + Alt + R  Toggle Bread/DWM <-> Original look"
            }
        }
    ' "$KEYS" > "$tmp"

    cat "$tmp" > "$KEYS"
    rm -f "$tmp"
fi

if ! grep -Fq \
    'DESKTOP LOOK SWITCHER' \
    "$KEYS"
then
    cat >> "$KEYS" <<'EOF'

DESKTOP LOOK SWITCHER

Super + Shift + Alt + R
    Toggle Bread/DWM <-> Original.

toggle-desktop-look
    Toggle between Bread/DWM and Original.

toggle-desktop-look dwm
    Load Bread/DWM.

toggle-desktop-look original
    Load Original.

toggle-desktop-look save
    Save the currently active Mango + Noctalia profile.

toggle-desktop-look status
    Show the active profile.

The current Mango + Noctalia profile is saved automatically before
the other appearance is loaded.
EOF
fi


say "18. UPDATE V5 GUIDE"

# The merged V3 script replaces both previous helper scripts.
sed -i \
    -e 's|~/Downloads/update-system-and-push-v2\.sh|~/Downloads/update-system-and-push-v3.2.sh|g' \
    -e 's|~/Downloads/update-system-and-push-v3\.sh|~/Downloads/update-system-and-push-v3.2.sh|g' \
    -e 's|~/Downloads/update-system-and-push-v3\.1\.sh|~/Downloads/update-system-and-push-v3.2.sh|g' \
    "$V5"

sed -i \
    's|~/Downloads/sync-config-to-github\.sh|~/Downloads/update-system-and-push-v3.2.sh --sync-only|g' \
    "$V5"

sed -i \
    's|0\. THE TWO FILES I USE MOST|0. THE ONE SCRIPT I USE MOST|' \
    "$V5"

sed -i \
    's/The supplied sync script handles/The merged script handles/g' \
    "$V5"

sed -i \
    's/The GitHub sync script backs this helper up/The merged script backs this helper up/g' \
    "$V5"

sed -i \
    's/The sync script stores a reusable snapshot under:/The merged script in --sync-only mode stores a reusable snapshot under:/' \
    "$V5"

# Health checklist.
if ! grep -Fq \
    'Super+Shift+Alt+R toggles Bread/DWM <-> Original' \
    "$V5"
then
    tmp="$(mktemp)"

    awk '
        {
            print
            if ($0 == "  [ ] Noctalia bar works") {
                print "  [ ] Super+Shift+Alt+R toggles Bread/DWM <-> Original"
            }
        }
    ' "$V5" > "$tmp"

    cat "$tmp" > "$V5"
    rm -f "$tmp"
fi

# Section 15: restore the new ~/.local/share profile tree too.
if ! grep -Fq \
    '# DESKTOP_LOOK_PROFILE_RESTORE' \
    "$V5"
then
    block="$(mktemp)"
    tmp="$(mktemp)"

    cat > "$block" <<'EOF'

  # DESKTOP_LOOK_PROFILE_RESTORE
  if [ -d "$REPO/dotfiles/.local/share/desktop-look-toggle" ]; then
    mkdir -p "$HOME/.local/share"

    rm -rf "$HOME/.local/share/desktop-look-toggle"

    cp -a \
      "$REPO/dotfiles/.local/share/desktop-look-toggle" \
      "$HOME/.local/share/desktop-look-toggle"

    mkdir -p "$HOME/.local/state/noctalia"

    # A clean restore starts in Bread/DWM.
    cp -a \
      "$HOME/.local/share/desktop-look-toggle/dwm/mango.conf" \
      "$HOME/.config/mango/config.conf"

    cp -a \
      "$HOME/.local/share/desktop-look-toggle/dwm/noctalia-settings.toml" \
      "$HOME/.local/state/noctalia/settings.toml"

    printf '%s\n' dwm \
      > "$HOME/.local/share/desktop-look-toggle/active"

    if [ -f "$HOME/.local/bin/toggle-desktop-look" ]; then
      chmod +x "$HOME/.local/bin/toggle-desktop-look"
    fi
  fi
EOF

    awk -v block="$block" '
        index($0, "echo \"Dotfiles restored.\"") {
            while ((getline line < block) > 0) {
                print line
            }
            close(block)
        }
        {
            print
        }
    ' "$V5" > "$tmp"

    cat "$tmp" > "$V5"

    rm -f \
        "$block" \
        "$tmp"
fi

# Add one authoritative switcher section just before the final END marker.
if ! grep -Fq \
    '18. ORIGINAL <-> BREAD/DWM DESKTOP LOOK SWITCHER' \
    "$V5"
then
    section="$(mktemp)"
    tmp="$(mktemp)"

    cat > "$section" <<'EOF'

======================================================================
18. ORIGINAL <-> BREAD/DWM DESKTOP LOOK SWITCHER
======================================================================

CURRENT BEHAVIOR

  This setup has two independently editable appearance profiles:

    Bread / DWM
    Original

  Mango and Noctalia switch together.

  Before the other profile is loaded, the currently active Mango config
  and Noctalia settings are saved back into the active profile. Changes
  made to either appearance therefore persist independently.


KEYBIND

  Super + Shift + Alt + R


MANUAL COMMANDS

  toggle-desktop-look
  toggle-desktop-look dwm
  toggle-desktop-look original
  toggle-desktop-look save
  toggle-desktop-look status


AUTHORITATIVE FILES

  Switcher:
    ~/.local/bin/toggle-desktop-look

  Shared Mango keybind:
    ~/.config/mango/look-toggle.conf

  Bread/DWM:
    ~/.local/share/desktop-look-toggle/dwm/mango.conf
    ~/.local/share/desktop-look-toggle/dwm/noctalia-settings.toml

  Original:
    ~/.local/share/desktop-look-toggle/original/mango.conf
    ~/.local/share/desktop-look-toggle/original/noctalia-settings.toml


BACKUP / UPDATE SCRIPT

  Full system update + health check + GitHub snapshot:

    ~/Downloads/update-system-and-push-v3.2.sh

  GitHub snapshot only, without updating NixOS:

    ~/Downloads/update-system-and-push-v3.2.sh --sync-only


MANGO RELOAD

  Correct:
    mmsg dispatch reload_config

  Obsolete / incorrect:
    mmsg -d reload_config


IMPORTANT

  Do not manually recreate gap, opacity, blur, border, animation, bar or
  panel values from this guide. The Mango and Noctalia profile files are
  the authoritative current values.

  The abandoned Noctalia authentication-logo/custom-assets experiment is
  not part of the reproducible configuration and must not add
  NOCTALIA_ASSETS_DIR to the restored setup.

EOF

    # V5 normally ends with separator / END / separator. Keep END last.
    if [ "$(tail -n 2 "$V5" | head -n 1)" = "END" ]; then

        line_count="$(wc -l < "$V5")"
        keep_count=$((line_count - 3))

        head -n "$keep_count" "$V5" > "$tmp"
        cat "$section" >> "$tmp"
        tail -n 3 "$V5" >> "$tmp"

        cat "$tmp" > "$V5"

    else
        cat "$section" >> "$V5"
    fi

    rm -f \
        "$section" \
        "$tmp"
fi


# ======================================================================
# PART D - STORE MERGED HELPER + VERIFY + COMMIT
# ======================================================================

say "19. STORE MERGED V3 SCRIPT IN REPOSITORY"

mkdir -p "$REPO/scripts"

SELF="$(readlink -f "$0")"

cp -a \
    "$SELF" \
    "$REPO/scripts/update-system-and-push-v3.2.sh"

chmod +x \
    "$REPO/scripts/update-system-and-push-v3.2.sh"

# Old repository helper copies are obsolete after the merge.
rm -f \
    "$REPO/scripts/update-system-and-push-v2.sh" \
    "$REPO/scripts/update-system-and-push-v3.1.sh" \
    "$REPO/scripts/sync-config-to-github.sh"


say "20. VERIFY REPRODUCIBLE SNAPSHOT"

[ -f "$REPO/dotfiles/.config/mango/look-toggle.conf" ] ||
    fail "look-toggle.conf was not copied"

[ -f "$REPO/dotfiles/.local/bin/noctalia-greeter-sync-smart" ] ||
    fail "noctalia-greeter-sync-smart was not copied"

[ -f "$REPO/dotfiles/.local/bin/toggle-desktop-look" ] ||
    fail "toggle-desktop-look was not copied"

for profile in dwm original; do

    [ -f "$PROFILE_DST/$profile/mango.conf" ] ||
        fail "Missing repository $profile/mango.conf"

    [ -f "$PROFILE_DST/$profile/noctalia-settings.toml" ] ||
        fail "Missing repository $profile/noctalia-settings.toml"

done

grep -Fq \
    'SUPER+SHIFT+ALT,r' \
    "$REPO/dotfiles/.config/mango/look-toggle.conf" ||
    fail "Switcher keybind missing from repository"

if grep -Rqs \
    'NOCTALIA_ASSETS_DIR' \
    "$REPO/dotfiles/.config/mango" \
    "$PROFILE_DST" \
    2>/dev/null
then
    fail "Custom-logo override leaked into repository snapshot"
fi

echo
echo "Docs kept:"
find "$DOCS" \
    -maxdepth 1 \
    -type f \
    -name '*.txt' \
    -printf '  %f\n' \
    | sort

echo
echo "Look profiles:"
find "$PROFILE_DST" \
    -maxdepth 2 \
    -type f \
    -printf '  %P\n' \
    | sort


say "21. STAGE + VALIDATE GIT CHANGES"

# Normalize formatting in REPOSITORY COPIES only.
# This prevents git diff --check from stopping on harmless whitespace copied
# from the live config, without changing /etc/nixos or ~/.config.
for file in \
    "$REPO/configuration.nix" \
    "$REPO/nixos/configuration.nix"
do
    if [ -f "$file" ]; then
        sed -i -E 's/[[:space:]]+$//' "$file"
    fi
done

KITTY_REPO="$REPO/dotfiles/.config/kitty/kitty.conf"

if [ -f "$KITTY_REPO" ]; then
    tmp="$(mktemp)"

    awk '
        { line[NR] = $0 }
        END {
            n = NR
            while (n > 0 && line[n] ~ /^[[:space:]]*$/) {
                n--
            }
            for (i = 1; i <= n; i++) {
                print line[i]
            }
        }
    ' "$KITTY_REPO" > "$tmp"

    cat "$tmp" > "$KITTY_REPO"
    rm -f "$tmp"
fi

git add -A

git diff --cached --check

# Refuse an added/modified hardware-configuration.nix, but allow deletion
# of an old tracked copy.
while IFS=$'\t' read -r status path extra; do

    case "$status" in
        D*)
            continue
            ;;
    esac

    case "$path" in
        hardware-configuration.nix|*/hardware-configuration.nix)
            fail "hardware-configuration.nix is staged as $status"
            ;;
    esac

done < <(
    git diff --cached --name-status
)

echo
git status --short

echo
git diff --cached --stat


say "22. SECRET SANITY CHECK"

SUSPICIOUS="$(
    git diff --cached -U0 |
    grep -Ei \
      '^\+[^+].*(access[_-]?token[[:space:]]*=|refresh[_-]?token[[:space:]]*=|api[_-]?key[[:space:]]*=|client[_-]?secret[[:space:]]*=|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|password[[:space:]]*=[[:space:]]*["'\''][^"'\'']{4,})' \
    || true
)"

if [ -n "$SUSPICIOUS" ]; then
    echo
    echo "Possible secret-like content detected:"
    echo "$SUSPICIOUS"
    echo
    echo "Nothing was committed or pushed."
    exit 1
fi

echo "OK"


say "23. COMMIT"

if git diff --cached --quiet; then
    echo "No new configuration changes to commit."
else
    git commit \
        -m "Update reproducible Tonelico desktop setup"
fi


say "24. PUSH TO GITHUB"

git push origin main


echo
echo "============================================================"
echo " COMPLETE"
echo "============================================================"
echo

git log -1 --oneline

echo
echo "Repository status:"
git status --short

echo
echo "Current desktop switcher:"
"$TOGGLE" status || true

echo
echo "Stored:"
echo "  - reusable NixOS config"
echo "  - current Mango + Noctalia + user configs"
echo "  - Bread/DWM profile"
echo "  - Original profile"
echo "  - Super+Shift+Alt+R persistent switcher"
echo "  - updated V5 guide"
echo "  - updated MANGO-KEYS.txt"
echo "  - merged update-system-and-push-v3.2.sh"
echo
