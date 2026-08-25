#!/usr/bin/env bash
# Syncs the active Noctalia accent color into Niri's focus ring.
set -euo pipefail

FOCUS_COLOR=$(noctalia msg status 2>/dev/null | jq -r '.accentColor // "#67d4e4"')

cat > "$HOME/.config/niri/colors.kdl" << EOF
// Generated automatically from Noctalia palette
layout {
    focus-ring {
        active-color "${FOCUS_COLOR}"
        inactive-color "#45475a"
    }
}
EOF

if [ "${XDG_CURRENT_DESKTOP:-}" = "niri" ]; then
    niri msg action reload-config 2>/dev/null || true
fi
