#!/bin/bash
# Run AS ROOT (sudo bash APPLY-rebuild1.sh) from inside this staging dir.
# Applies Phase 5 rebuild #1: niri input + module (disabled), cache wired.
set -euo pipefail

NIXOS=/etc/nixos
STAGE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/4 Baseline commit of current /etc/nixos =="
if ! git -C "$NIXOS" diff --quiet HEAD -- 2>/dev/null || [ -n "$(git -C "$NIXOS" status --porcelain 2>/dev/null | grep -v '^??')" ] || [ -n "$(git -C "$NIXOS" status --porcelain 2>/dev/null | grep '^??.*nix$')" ]; then
    git -C "$NIXOS" add -A
    git -C "$NIXOS" commit -m "baseline before multi-DE integration (portal split, plasma+greetd fixes)" || echo "(nothing to commit)"
else
    echo "   clean, skipping"
fi

echo "== 2/4 Taking ownership of /etc/nixos for user aesc =="
chown -R aesc:users "$NIXOS"

echo "== 3/4 Installing staged files =="
install -m 644 "$STAGE/flake.nix"       "$NIXOS/flake.nix"
install -m 644 "$STAGE/desktop/niri.nix" "$NIXOS/desktop/niri.nix"
grep -q 'niri.url' "$NIXOS/flake.nix"        && echo "   flake.nix OK"
grep -q 'programs.niri.enable = false' "$NIXOS/desktop/niri.nix" && echo "   niri.nix OK (enable=false, step-2 flip later)"

echo "== 4/4 Evaluating configuration (no switch yet) =="
cd "$NIXOS"
nixos-rebuild build --flake .#tonelico

echo
echo "EVAL OK. Now switch:"
echo "  sudo nixos-rebuild switch --flake /etc/nixos#tonelico"
