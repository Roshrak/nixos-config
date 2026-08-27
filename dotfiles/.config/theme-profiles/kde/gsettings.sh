#!/usr/bin/env bash
# KDE Plasma session GTK/gsettings theme profile.
set -euo pipefail

gsettings_set() {
    gsettings set "$1" "$2" "$3" 2>/dev/null || true
}

gsettings_set org.gnome.desktop.interface gtk-theme "'breeze-dark'"
gsettings_set org.gnome.desktop.interface icon-theme "'breeze-dark'"
gsettings_set org.gnome.desktop.interface cursor-theme "'breeze_cursors'"
gsettings_set org.gnome.desktop.interface cursor-size "24"
gsettings_set org.gnome.desktop.interface color-scheme "'prefer-dark'"
gsettings_set org.gnome.desktop.interface font-name "'Noto Sans 10'"
