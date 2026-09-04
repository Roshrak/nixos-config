#!/usr/bin/env bash
# Snapshot of kde gsettings
set -euo pipefail
gsettings_set() { gsettings set "$1" "$2" "$3" 2>/dev/null || true; }
gsettings_set org.gnome.desktop.interface gtk-theme "'adw-gtk3-dark'"
gsettings_set org.gnome.desktop.interface icon-theme "'Adwaita'"
gsettings_set org.gnome.desktop.interface cursor-theme "'Bibata-Modern-Ice'"
gsettings_set org.gnome.desktop.interface cursor-size "24"
gsettings_set org.gnome.desktop.interface color-scheme "'prefer-dark'"
gsettings_set org.gnome.desktop.interface font-name "'Noto Sans 10'"
