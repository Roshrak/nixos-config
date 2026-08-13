#!/usr/bin/env bash
set -Eeuo pipefail

# Tonelico - Comic Mono system-wide + End-4 Kitty cursor trail
# NO window open/close animation.
#
# Intended for:
#   NixOS flake: /etc/nixos#tonelico
#   Kitty
#   Noctalia v5
#
# What it changes:
#   1. Installs Comic Mono regular + bold through a local NixOS module
#   2. Sets Fontconfig sans-serif + monospace defaults to Comic Mono
#   3. Sets Noctalia v5 shell font to Comic Mono
#   4. Sets Kitty font to Comic Mono
#   5. Adds the actual End-4-style Kitty in-terminal effect:
#        cursor_shape beam
#        cursor_trail 1
#
# It does NOT change Mango animations.

STAMP="$(date +%Y%m%d-%H%M%S)"
NIXDIR="/etc/nixos"
FLAKE="$NIXDIR/flake.nix"
MODULE="$NIXDIR/comic-mono.nix"
FONTDIR="$NIXDIR/fonts/comic-mono"

KITTY_DIR="$HOME/.config/kitty"
KITTY_CONF="$KITTY_DIR/kitty.conf"
KITTY_OVERRIDE="$KITTY_DIR/tonelico-comic-mono.conf"

NOCT_DIR="$HOME/.config/noctalia"
NOCT_OVERRIDE="$NOCT_DIR/99-comic-mono.toml"

BACKUP="$HOME/.local/share/tonelico-comic-mono-backup-$STAMP"

log() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

die() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

[[ $EUID -ne 0 ]] || die "Run this as your normal user, NOT with sudo."
[[ -f "$FLAKE" ]] || die "$FLAKE not found."
command -v curl >/dev/null || die "curl is missing."

mkdir -p "$BACKUP"
sudo cp -a "$FLAKE" "$BACKUP/flake.nix"
[[ -f "$MODULE" ]] && sudo cp -a "$MODULE" "$BACKUP/comic-mono.nix"
[[ -f "$KITTY_CONF" ]] && cp -a "$KITTY_CONF" "$BACKUP/kitty.conf"
[[ -f "$KITTY_OVERRIDE" ]] && cp -a "$KITTY_OVERRIDE" "$BACKUP/kitty-override.conf"
[[ -f "$NOCT_OVERRIDE" ]] && cp -a "$NOCT_OVERRIDE" "$BACKUP/noctalia-override.toml"

restore_nix() {
    sudo cp -a "$BACKUP/flake.nix" "$FLAKE"
    if [[ -f "$BACKUP/comic-mono.nix" ]]; then
        sudo cp -a "$BACKUP/comic-mono.nix" "$MODULE"
    else
        sudo rm -f "$MODULE"
    fi
}

log "Downloading Comic Mono"
sudo mkdir -p "$FONTDIR"

sudo curl -fL --retry 3 \
    https://dtinth.github.io/comic-mono-font/ComicMono.ttf \
    -o "$FONTDIR/ComicMono.ttf"

sudo curl -fL --retry 3 \
    https://dtinth.github.io/comic-mono-font/ComicMono-Bold.ttf \
    -o "$FONTDIR/ComicMono-Bold.ttf"

sudo chmod 0644 "$FONTDIR"/*.ttf

log "Creating NixOS system font module"
sudo tee "$MODULE" >/dev/null <<'NIX'
{ pkgs, ... }:

let
  comicMono = pkgs.stdenvNoCC.mkDerivation {
    pname = "comic-mono";
    version = "2019-06-07";

    src = ./fonts/comic-mono;

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p $out/share/fonts/truetype/comic-mono
      cp $src/ComicMono.ttf \
        $out/share/fonts/truetype/comic-mono/ComicMono.ttf
      cp $src/ComicMono-Bold.ttf \
        $out/share/fonts/truetype/comic-mono/ComicMono-Bold.ttf
    '';
  };
in
{
  fonts.packages = [ comicMono ];

  # Make Comic Mono the generic UI + terminal default.
  fonts.fontconfig.defaultFonts = {
    sansSerif = [ "Comic Mono" ];
    monospace = [ "Comic Mono" ];
  };
}
NIX

log "Adding comic-mono.nix to your flake"
if ! grep -qE '(^|[[:space:]])\./comic-mono\.nix([[:space:]]|$)' "$FLAKE"; then

    if grep -qE '(^|[[:space:]])\./tonelico-deck\.nix([[:space:]]|$)' "$FLAKE"; then
        sudo sed -i \
            '/\.\/tonelico-deck\.nix/a\        ./comic-mono.nix' \
            "$FLAKE"

    elif grep -qF 'mango.nixosModules.mango' "$FLAKE"; then
        sudo sed -i \
            '/mango\.nixosModules\.mango/a\        ./comic-mono.nix' \
            "$FLAKE"

    elif grep -qE '^[[:space:]]*\./configuration\.nix[[:space:]]*$' "$FLAKE"; then
        sudo sed -i \
            '/^[[:space:]]*\.\/configuration\.nix[[:space:]]*$/a\        ./comic-mono.nix' \
            "$FLAKE"
    else
        restore_nix
        die "Could not locate the NixOS module list in flake.nix."
    fi
fi

if ! grep -qE '(^|[[:space:]])\./comic-mono\.nix([[:space:]]|$)' "$FLAKE"; then
    restore_nix
    die "comic-mono.nix was not inserted into the flake."
fi

log "Configuring Kitty: Comic Mono + End-4 cursor animation"
mkdir -p "$KITTY_DIR"
touch "$KITTY_CONF"

cat >"$KITTY_OVERRIDE" <<'EOF'
# Tonelico Comic Mono + End-4/Illogical Impulse terminal effect

font_family      Comic Mono
bold_font        Comic Mono Bold
italic_font      Comic Mono
bold_italic_font Comic Mono Bold

# Actual End-4 Kitty effect:
cursor_shape beam
cursor_trail 1

# Kitty defaults, written explicitly so the effect remains predictable:
cursor_trail_decay 0.1 0.4
cursor_trail_start_threshold 2
EOF

# Remove our own previous include if duplicated, then ensure exactly one include.
sed -i \
    '/^[[:space:]]*include[[:space:]]\+tonelico-comic-mono\.conf[[:space:]]*$/d' \
    "$KITTY_CONF"

printf '\n# Tonelico terminal appearance\ninclude tonelico-comic-mono.conf\n' \
    >>"$KITTY_CONF"

log "Configuring Noctalia v5 to use Comic Mono"
mkdir -p "$NOCT_DIR"

cat >"$NOCT_OVERRIDE" <<'EOF'
# Tonelico global Noctalia font
[shell]
font_family = "Comic Mono"
EOF

log "Checking NixOS configuration"
if ! sudo nixos-rebuild test --flake "$NIXDIR#tonelico"; then
    restore_nix
    die "nixos-rebuild test failed. Nix files were restored. Backup: $BACKUP"
fi

log "Applying NixOS configuration"
if ! sudo nixos-rebuild switch --flake "$NIXDIR#tonelico"; then
    restore_nix
    die "nixos-rebuild switch failed. Backup: $BACKUP"
fi

log "Refreshing font cache"
fc-cache -f >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo
echo "Comic Mono:"
fc-match "Comic Mono" | head -1 || true
echo
echo "Generic sans-serif:"
fc-match sans-serif | head -1 || true
echo
echo "Generic monospace:"
fc-match monospace | head -1 || true
echo
echo "Kitty effect:"
echo "  cursor_shape beam"
echo "  cursor_trail 1"
echo
echo "NO Mango/window animations were added."
echo
echo "Backup:"
echo "  $BACKUP"
echo
echo "Close every Kitty window, then open Kitty again."
