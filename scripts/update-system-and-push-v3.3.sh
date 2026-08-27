#!/usr/bin/env bash
#
# update-system-and-push-v3.3.sh
#
# One command does everything, every run:
#   flake update -> rebuild+switch -> non-nix updates -> health check
#   -> snapshot (NixOS + dotfiles + helpers + theme profiles + plans)
#   -> commit + push to github.com/Roshrak/nixos-config
#
# Removed in v3.3: the old Original<->DWM toggle machinery (purged from the
# system). Added: niri/theme-profiles/plasma-workspace/systemd-user snapshot,
# isolation helpers, rice plan docs, RESTORE-CURRENT.md.
#
# No flags needed. Run:
#   bash ~/Downloads/update-system-and-push-v3.3.sh
#
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
    echo "Run this normally as aesc, not with sudo."
    exit 1
fi

NIX_DIR="/etc/nixos"
REPO="$HOME/nixos-config"
DOCS="$REPO/docs"
RICE_PLAN="$HOME/rice plan"

MANGO="$HOME/.config/mango"

V5="$DOCS/nixos-mango-command-guide-v5.txt"
KEYS="$DOCS/MANGO-KEYS.txt"
RESTORE_MD="$DOCS/RESTORE-CURRENT.md"

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

case "${1:-}" in
    "") ;;
    -h|--help)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Unknown argument: $1 (this script takes no flags)" >&2
        exit 2
        ;;
esac

# ======================================================================
# PART A - SYSTEM UPDATE
# ======================================================================

say "1. BACK UP FLAKE LOCK"

[ -f "$NIX_DIR/flake.nix" ] || fail "Missing $NIX_DIR/flake.nix"
cd "$NIX_DIR"

if [ -f flake.lock ]; then
    sudo cp -a flake.lock "flake.lock.before-update-$STAMP"
    echo "Saved: $NIX_DIR/flake.lock.before-update-$STAMP"
else
    echo "No existing flake.lock; continuing."
fi

say "2. UPDATE NIX FLAKE INPUTS"

sudo nix flake update

say "3. BUILD FIRST (pre-flight)"

# Declarative Chromium policy now lives in configuration.nix; drop the old
# manual /etc copy so activation doesn't clash with it.
if grep -q 'chromium/policies/managed' "$NIX_DIR/configuration.nix" 2>/dev/null; then
    sudo rm -f /etc/chromium/policies/managed/default-browser.json
fi

sudo nixos-rebuild build --flake .#tonelico

say "4. ACTIVATE (switch)"

sudo nixos-rebuild switch --flake .#tonelico

say "5. UPDATE NON-NIX ITEMS"

if command -v flatpak >/dev/null 2>&1; then
    echo "--- Flatpak ---"
    flatpak update -y || echo "WARNING: Flatpak update failed/skipped."
fi

if command -v nvim >/dev/null 2>&1 && [ -d "$HOME/.config/nvim" ]; then
    echo "--- LazyVim ---"
    timeout 300 nvim --headless "+Lazy! sync" +qa ||
        echo "WARNING: LazyVim plugin sync failed/timed out."
fi

if command -v fwupdmgr >/dev/null 2>&1; then
    echo "--- Firmware metadata ---"
    sudo fwupdmgr refresh --force || true
    sudo fwupdmgr get-updates || true
    echo "Firmware was checked, not automatically installed."
fi

# ======================================================================
# PART B - HEALTH CHECK (warn-only, never fatal)
# ======================================================================

say "6. HEALTH CHECK"

WARN=0

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
echo "--- Mango config parser ---"
if mango -c "$MANGO/config.conf" -p; then
    echo "OK"
else
    echo "WARNING: parser complained (live session unaffected)"
    WARN=1
fi

echo
echo "--- Noctalia ---"
if noctalia msg status 2>/dev/null; then
    echo "OK"
else
    echo "WARNING: Noctalia did not respond (not running in this session?)"
    WARN=1
fi

echo
echo "--- Audio ---"
if wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null; then
    echo "OK"
else
    echo "WARNING: no default audio sink."
    WARN=1
fi

echo
echo "--- Network ---"
nmcli -t -f DEVICE,TYPE,STATE device status || true

echo
echo "--- Greeter / sessions ---"
printf "greetd: "
systemctl is-enabled greetd.service 2>/dev/null || true
printf "sddm:   "
systemctl is-enabled sddm.service 2>/dev/null || true

EXEC_LINE="$(grep '^Exec=' /run/current-system/sw/share/wayland-sessions/niri.desktop 2>/dev/null || true)"
case "$EXEC_LINE" in
    *niri-session-guarded*)
        echo "niri.desktop Exec -> guarded wrapper: OK"
        ;;
    *)
        echo "WARNING: niri.desktop is not the guarded wrapper: '$EXEC_LINE'"
        WARN=1
        ;;
esac

POLICY_FILE="/etc/chromium/policies/managed/default-browser.json"
if grep -q 'DefaultBrowserSettingEnabled' "$POLICY_FILE" 2>/dev/null; then
    echo "Chromium default-browser policy: OK"
else
    echo "WARNING: Chromium default-browser policy missing"
    WARN=1
fi

echo
echo "--- Important commands ---"
for CMD in \
    chromium kitty obs prismlauncher steam nvim fastfetch noctalia mango \
    wpctl apply-theme-profile clean-stray-sessions niri-session-guarded \
    save-noctalia-profile
do
    if command -v "$CMD" >/dev/null 2>&1; then
        printf "OK      %-24s %s\n" "$CMD" "$(command -v "$CMD")"
    else
        printf "MISSING %-24s\n" "$CMD"
        WARN=1
    fi
done

echo
echo "--- Greeter sync helper ---"
[ -f "$HOME/.local/bin/noctalia-greeter-sync-smart" ] &&
    echo "OK: noctalia-greeter-sync-smart" ||
    { echo "MISSING: noctalia-greeter-sync-smart"; WARN=1; }

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
echo "  - Noctalia bar/launcher works (mango/niri)"
echo "  - session cycle works: mango -> niri -> kde -> niri"
echo "  - screenshots go to ~/Pictures/Screenshots"
echo "  - OBS records to ~/Videos/OBS"
echo "  - Steam starts the way you expect"
echo

read -r -p 'Type PUSH to snapshot this working state and upload to GitHub: ' ANSWER
if [ "$ANSWER" != "PUSH" ]; then
    echo
    echo "GitHub upload cancelled. The system update itself is already active."
    exit 0
fi

# ======================================================================
# PART C - SNAPSHOT
# ======================================================================

say "8. CHECK GITHUB REPOSITORY"

[ -d "$REPO/.git" ] || fail "Git repository not found: $REPO"
cd "$REPO"

BRANCH="$(git branch --show-current)"
REMOTE="$(git remote get-url origin 2>/dev/null || true)"

echo "Repository: $REPO"
echo "Branch:     $BRANCH"
echo "Remote:     $REMOTE"

[ "$BRANCH" = "main" ] || fail "Expected branch main, found: $BRANCH"

case "$REMOTE" in
    *github.com/Roshrak/nixos-config.git|*github.com/Roshrak/nixos-config)
        ;;
    *)
        fail "Unexpected origin remote: $REMOTE"
        ;;
esac

git reset -q 2>/dev/null || true    # drop stale staging from interrupted runs
git fetch origin
git pull --rebase --autostash origin main

say "9. CLEAN OBSOLETE DOCS"

mkdir -p "$DOCS"
for old in \
    "$DOCS/nixos-command-guide.txt" \
    "$DOCS/nixos-mango-command-and-reinstall-guide-v2.txt" \
    "$DOCS/nixos-mango-command-and-reinstall-guide-v3.txt"
do
    if [ -e "$old" ]; then
        echo "Removing: $old"
        rm -f -- "$old"
    fi
done

[ -f "$V5" ] || fail "Missing current V5 guide: $V5"
[ -f "$KEYS" ] || fail "Missing MANGO-KEYS.txt: $KEYS"

say "10. CLEAN ABANDONED NOCTALIA LOGO EXPERIMENT (defensive)"

[ -f "$MANGO/config.conf" ] && \
    sed -i '/^env=NOCTALIA_ASSETS_DIR,/d' "$MANGO/config.conf"

if [ -e "$CUSTOM_ASSETS" ]; then
    find -P "$CUSTOM_ASSETS" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    rm -rf -- "$CUSTOM_ASSETS"
fi

[ ! -e "$CUSTOM_ASSETS" ] || fail "Could not remove $CUSTOM_ASSETS"

if grep -qs 'NOCTALIA_ASSETS_DIR' "$MANGO/config.conf" 2>/dev/null; then
    fail "NOCTALIA_ASSETS_DIR still exists in live Mango config"
fi
echo "Custom-logo experiment is absent."

say "11. SNAPSHOT /etc/nixos"

NIX_DST="$REPO/nixos"
rm -rf "$NIX_DST"
mkdir -p "$NIX_DST"

while IFS= read -r -d '' src; do
    rel="${src#/etc/nixos/}"
    dst="$NIX_DST/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -a --no-preserve=ownership "$src" "$dst"
done < <(
    find "$NIX_DIR" \
        -type f \
        \( -name '*.nix' -o -name 'flake.lock' \) \
        ! -name 'hardware-configuration.nix' \
        ! -name 'flake.lock.before-update-*' \
        -print0
)

if [ -d "$NIX_DIR/fonts" ]; then
    rm -rf "$NIX_DST/fonts"
    cp -a --no-preserve=ownership "$NIX_DIR/fonts" "$NIX_DST/fonts"
    echo "Saved NixOS font assets."
fi

rm -f "$NIX_DST/hardware-configuration.nix"

# Root-level compatibility copies.
while IFS= read -r -d '' src; do
    base="$(basename "$src")"
    [ "$base" = "hardware-configuration.nix" ] && continue
    cp -a --no-preserve=ownership "$src" "$REPO/$base"
done < <(
    find "$NIX_DIR" \
        -maxdepth 1 \
        -type f \
        \( -name '*.nix' -o -name 'flake.lock' \) \
        ! -name 'hardware-configuration.nix' \
        ! -name 'flake.lock.before-update-*' \
        -print0
)

touch "$REPO/.gitignore"
for entry in '/hardware-configuration.nix' '/nixos/hardware-configuration.nix'; do
    grep -Fqx "$entry" "$REPO/.gitignore" ||
        printf '\n%s\n' "$entry" >> "$REPO/.gitignore"
done

git rm -f --ignore-unmatch \
    hardware-configuration.nix nixos/hardware-configuration.nix \
    >/dev/null 2>&1 || true

say "12. SNAPSHOT USER CONFIG"

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

    find "$dst" \
        -type f \
        \( \
            -name '*.bak' -o -name '*.bak-*' -o -name '*.backup' \
            -o -name '*.old' -o -name '*.before-*' \
            -o -name '*before-dwm-look*' -o -name '*before-animation*' \
            -o -name '*before-gesture*' -o -name '*before-touchpad*' \
            -o -name '*before-monitor*' \
        \) \
        -delete 2>/dev/null || true

    echo "Saved ~/.config/$name"
}

for app in \
    mango noctalia kitty fcitx5 nvim fastfetch \
    niri theme-profiles plasma-workspace systemd
do
    sync_config_dir "$app"
done

# Stray mktemp artifacts from seed-stamping sessions must not leak in.
find "$DOTCONFIG/theme-profiles" -name '.seed.*' -delete 2>/dev/null || true

if [ -f "$HOME/.config/mimeapps.list" ]; then
    cp -a "$HOME/.config/mimeapps.list" "$DOTCONFIG/mimeapps.list"
fi

if [ -f "$HOME/.config/kwinrc" ]; then
    cp -a "$HOME/.config/kwinrc" "$DOTCONFIG/kwinrc"
    echo "Saved ~/.config/kwinrc (KDE: overview hot corner, desktops, tiling)"
fi

say "13. SNAPSHOT CUSTOM HELPERS"

BIN_DST="$REPO/dotfiles/.local/bin"
mkdir -p "$BIN_DST"

for helper in \
    apply-theme-profile \
    clean-stray-sessions \
    niri-session-guarded \
    mango-session-guarded \
    save-noctalia-profile \
    noctalia-greeter-sync-smart \
    mango-animation \
    steam \
    obs \
    obs-safe \
    obs-fix-recording-paths
do
    src="$HOME/.local/bin/$helper"
    if [ -f "$src" ]; then
        cp -a "$src" "$BIN_DST/$helper"
        chmod +x "$BIN_DST/$helper"
        echo "Saved: $helper"
    else
        echo "Skip missing helper: $helper"
    fi
done

say "14. SNAPSHOT DESKTOP SESSION FILES + RICE PLANS"

APP_DST="$REPO/dotfiles/.local/share/applications"
mkdir -p "$APP_DST"

if [ -f "$HOME/.local/share/applications/steam.desktop" ]; then
    cp -a "$HOME/.local/share/applications/steam.desktop" "$APP_DST/steam.desktop"
fi

mkdir -p "$DOCS/plans"
if [ -d "$RICE_PLAN" ]; then
    rm -rf "$DOCS/plans/rice-plan"
    cp -a "$RICE_PLAN" "$DOCS/plans/rice-plan"
    # Machine-local backups (multi-GB tarballs) live under multi-de/backups.
    rm -rf "$DOCS/plans/rice-plan/multi-de/backups"
    # Hard guard: nothing over 50MB ever enters the repo (GitHub cap 100MB).
    find "$DOCS/plans" -type f -size +50M -delete
    echo "Saved rice plan docs (backups + >50MB files excluded)."
fi

# ======================================================================
# PART D - DOCS
# ======================================================================

say "15. UPDATE V5 GUIDE + MANGO-KEYS (script path references)"

sed -i \
    -e 's|update-system-and-push-v2\.sh|update-system-and-push-v3.3.sh|g' \
    -e 's|update-system-and-push-v3\.sh|update-system-and-push-v3.3.sh|g' \
    -e 's|update-system-and-push-v3\.1\.sh|update-system-and-push-v3.3.sh|g' \
    -e 's|update-system-and-push-v3\.2\.sh|update-system-and-push-v3.3.sh|g' \
    -e 's|sync-config-to-github\.sh|update-system-and-push-v3.3.sh|g' \
    "$V5"

say "16. WRITE RESTORE-CURRENT.md"

cat > "$RESTORE_MD" <<'EOF'
# RESTORE-CURRENT.md — what this repo snapshot contains (auto-generated)

Regenerated on every run of scripts/update-system-and-push-v3.3.sh.

## Snapshot contents

- nixos/                — full /etc/nixos set (*.nix + flake.lock + fonts),
                          hardware-configuration.nix excluded (machine-local)
- configuration.nix etc — root-level copies for convenience
- dotfiles/.config/     — mango, noctalia, kitty, fcitx5, nvim, fastfetch,
                          niri (config.kdl), theme-profiles (per-DE seeds),
                          plasma-workspace (KDE stale-session hook),
                          systemd/user (plasma gate drop-ins), kwinrc,
                          mimeapps.list
- dotfiles/.local/bin/  — apply-theme-profile, clean-stray-sessions,
                          niri-session-guarded, save-noctalia-profile,
                          noctalia-greeter-sync-smart, mango-animation,
                          steam, obs helpers
- docs/plans/rice-plan/ — the multi-DE isolation master plan + batteries
- scripts/              — this updater itself

## Restore outline (NEW machine, hardware may vary)

Hard requirements: NixOS, user named "aesc" (absolute /home/aesc paths are
baked into configs and seeds by design).

1. Install NixOS minimal on the target machine; create user aesc.
2. On the target, generate fresh hardware: `sudo nixos-generate-config`.
   KEEP that hardware-configuration.nix (never copy the old machine's).
3. Copy nixos/* -> /etc/nixos, root-level *.nix files into /etc/nixos,
   flake.lock included.
4. Adjust for the new hardware in /etc/nixos/configuration.nix:
   - Intel (default): keep hardware.cpu.intel.updateMicrocode,
     intel-media-driver, intel-compute-runtime, LIBVA_DRIVER_NAME = "iHD".
   - AMD: swap microcode for hardware.cpu.amd.updateMicrocode, replace
     intel-media-driver with amdvlk/libva-mesa-driver, set
     LIBVA_DRIVER_NAME = "radeontop"; remove intel-compute-runtime.
   - NVIDIA: add services.xserver.videoDrivers = [ "nvidia" ]; remove the
     iHD VA-API line (use nvidia-vaapi-driver instead).
   - videoDrivers is currently [ "modesetting" ].
5. Comment out machine-specific modules in flake.nix if absent on the
   target: ./windows-vm.nix (needs VFIO passthrough), ./wave75-via.nix
   (specific keyboard udev), ./comic-mono.nix (or keep fonts/, harmless).
6. Hostname: keep "tonelico" or sed it in flake.nix (nixosConfigurations.<name>).
7. Binary cache trust for the third-party flakes (noctalia cachix):
   sudo nixos-rebuild switch --flake /etc/nixos#tonelico --accept-flake-config
   (first switch only; or add the keys to nix.settings afterwards).
8. Copy dotfiles/.config/* -> ~/.config/ and dotfiles/.local/bin/* ->
   ~/.local/bin/ (chmod +x the bin helpers).
9. Wallpapers are NOT in this snapshot. Theme seeds reference
   ~/Pictures/Wallpapers/<3 files> — drop any wallpaper with those names
   (or re-pick wallpapers in-session; seeds stay isolated per DE via
   theme-profiles).
10. Chromium never nags about default browser: the policy is declarative in
    configuration.nix (environment.etc .../chromium/policies/managed/...).

## Session isolation invariants (must survive any restore)

- Theme seeds in ~/.config/theme-profiles/{mango,niri,kde}: wallpaper,
  kitty theme, gsettings, noctalia-state.toml; all auto_sync=false.
- apply-theme-profile is stamped at login: mango config.conf exec-once,
  niri config.kdl spawn-at-startup (absolute paths).
- niri.desktop Exec = /home/aesc/.local/bin/niri-session-guarded
  (patched by desktop/plasma.nix dm-sessions-share, meta.priority=1).
- Plasma user units gated by ~/.config/systemd/user/plasma-*.service.d/
  kde-gate.conf (ConditionEnvironment=XDG_CURRENT_DESKTOP=KDE).
- Chromium singleton cleanup via clean-stray-sessions in all 3 sessions.
EOF

# ======================================================================
# PART E - VERIFY + COMMIT + PUSH
# ======================================================================

say "17. STORE THIS SCRIPT + VERIFY SNAPSHOT"

mkdir -p "$REPO/scripts"
SELF="$(readlink -f "$0")"
cp -a "$SELF" "$REPO/scripts/update-system-and-push-v3.3.sh"
chmod +x "$REPO/scripts/update-system-and-push-v3.3.sh"

rm -f \
    "$REPO/scripts/update-system-and-push-v2.sh" \
    "$REPO/scripts/update-system-and-push-v3.sh" \
    "$REPO/scripts/update-system-and-push-v3.1.sh" \
    "$REPO/scripts/update-system-and-push-v3.2.sh" \
    "$REPO/scripts/sync-config-to-github.sh"

[ -f "$REPO/nixos/flake.nix" ] || fail "Repo nixos/flake.nix missing"
[ -f "$REPO/dotfiles/.config/mango/config.conf" ] ||
    fail "Repo mango config missing"
[ -f "$REPO/dotfiles/.config/niri/config.kdl" ] ||
    fail "Repo niri config missing"
[ -f "$REPO/dotfiles/.config/theme-profiles/niri/noctalia-state.toml" ] ||
    fail "Repo niri theme seed missing"
[ -f "$REPO/dotfiles/.local/bin/apply-theme-profile" ] ||
    fail "apply-theme-profile not copied"
[ -f "$REPO/dotfiles/.local/bin/niri-session-guarded" ] ||
    fail "niri-session-guarded not copied"
[ -f "$REPO/dotfiles/.local/bin/mango-session-guarded" ] ||
    fail "mango-session-guarded not copied"
[ -f "$REPO/dotfiles/.config/systemd/user/niri.service.d/save-profile.conf" ] ||
    fail "niri save-profile drop-in not copied"
[ -f "$REPO/dotfiles/.local/bin/clean-stray-sessions" ] ||
    fail "clean-stray-sessions not copied"
[ -f "$RESTORE_MD" ] || fail "RESTORE-CURRENT.md missing"

if grep -Rqs 'NOCTALIA_ASSETS_DIR' \
    "$REPO/dotfiles/.config/mango" 2>/dev/null
then
    fail "Custom-logo override leaked into repository snapshot"
fi

echo
echo "Docs kept:"
find "$DOCS" -maxdepth 1 -type f -name '*.txt' -printf '  %f\n' | sort

say "18. STAGE + VALIDATE"

for file in "$REPO/configuration.nix" "$REPO/nixos/configuration.nix"; do
    [ -f "$file" ] && sed -i -E 's/[[:space:]]+$//' "$file"
done

KITTY_REPO="$REPO/dotfiles/.config/kitty/kitty.conf"
if [ -f "$KITTY_REPO" ]; then
    tmp="$(mktemp)"
    awk '
        { line[NR] = $0 }
        END {
            n = NR
            while (n > 0 && line[n] ~ /^[[:space:]]*$/) { n-- }
            for (i = 1; i <= n; i++) { print line[i] }
        }
    ' "$KITTY_REPO" > "$tmp"
    cat "$tmp" > "$KITTY_REPO"
    rm -f "$tmp"
fi

git add -A

# Trailing whitespace in copied docs/plans must not kill the push; normalize
# repository copies (never /etc/nixos or live ~/.config) and report, not abort.
find "$REPO/docs" "$REPO/dotfiles" -type f \
    \( -name '*.nix' -o -name '*.txt' -o -name '*.md' -o -name '*.conf' \
       -o -name '*.toml' -o -name '*.kdl' -o -name '*.sh' \) \
    -exec sed -i -E 's/[[:space:]]+$//' {} + 2>/dev/null || true
git add -A

WS_CHECK="$(git diff --cached --check 2>&1 || true)"
if [ -n "$WS_CHECK" ]; then
    echo "WARNING: whitespace notes (non-fatal):"
    echo "$WS_CHECK"
fi

while IFS=$'\t' read -r status path extra; do
    case "$status" in D*) continue ;; esac
    case "$path" in
        hardware-configuration.nix|*/hardware-configuration.nix)
            fail "hardware-configuration.nix is staged as $status"
            ;;
    esac
done < <(git diff --cached --name-status)

echo
git status --short
echo
git diff --cached --stat

say "19. SECRET SANITY CHECK"

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

say "20. COMMIT"

if git diff --cached --quiet; then
    echo "No new configuration changes to commit."
else
    git commit -m "Update reproducible Tonelico desktop setup (multi-DE isolation)"
fi

say "21. PUSH TO GITHUB"

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
echo "Stored:"
echo "  - reusable NixOS config + flake.lock"
echo "  - mango / noctalia / kitty / fcitx5 / nvim / fastfetch / niri configs"
echo "  - theme-profiles per-DE seeds + plasma-workspace hook + systemd gates"
echo "  - isolation helpers (apply-theme-profile, clean-stray-sessions,"
echo "    niri-session-guarded, save-noctalia-profile, greeter sync)"
echo "  - rice plan docs + RESTORE-CURRENT.md"
echo "  - this script: scripts/update-system-and-push-v3.3.sh"
echo
