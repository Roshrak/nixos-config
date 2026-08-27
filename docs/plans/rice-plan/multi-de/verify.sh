#!/usr/bin/env bash
# verify.sh — full multi-session integration battery.
# Run any time: ~/rice\ plan/multi-de/verify.sh
set -u
P=0; F=0
ck(){ local m="$1" c="$2"
  if eval "$c" >/dev/null 2>&1; then echo "PASS  $m"; P=$((P+1)); else echo "FAIL  $m"; F=$((F+1)); fi }

echo "── sessions/config ──────────────────────────────────"
ck "exactly 3 wayland-sessions" "[ \"\$(ls /run/current-system/sw/share/wayland-sessions | tr '\n' ' ')\" = 'mango.desktop niri.desktop plasma.desktop ' ]"
ck "no xsessions dir"            "[ ! -e /run/current-system/sw/share/xsessions ]"
ck "no i3 leftovers in live bin" "[ -z \"\$(ls /run/current-system/sw/bin | grep -E '^i3$|^polybar|^picom')\" ]"

echo "── compositor configs ───────────────────────────────"
ck "niri config valid"           "niri validate -c $HOME/.config/niri/config.kdl"
ck "niri has Mod+M maximize"     "grep -q 'maximize-column' $HOME/.config/niri/config.kdl"
ck "niri stamps before shell"    "[ \"\$(grep -n 'apply-theme-profile' $HOME/.config/niri/config.kdl | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'spawn-at-startup \\\"noctalia\\\"' $HOME/.config/niri/config.kdl | head -1 | cut -d: -f1)\" ]"
ck "niri uses absolute stamp"    "grep -q '/home/aesc/.local/bin/apply-theme-profile' $HOME/.config/niri/config.kdl"
ck "niri stray-guard hooked"     "grep -q clean-stray-sessions $HOME/.config/niri/config.kdl"
ck "mango config valid"          "mango -c $HOME/.config/mango/config.conf -p"
ck "mango stamps before noctalia" "test \$(grep -n 'apply-theme-profile mango' $HOME/.config/mango/config.conf | head -1 | cut -d: -f1) -lt \$(grep -n '^exec-once=noctalia' $HOME/.config/mango/config.conf | head -1 | cut -d: -f1)"
ck "mango stray-guard first"     "[ \$(grep -n 'clean-stray-sessions' $HOME/.config/mango/config.conf | cut -d: -f1) = 1 ] || [ \$(grep -n 'clean-stray-sessions' $HOME/.config/mango/config.conf | cut -d: -f1 | head -1) -lt \$(grep -n 'apply-theme-profile mango' $HOME/.config/mango/config.conf | cut -d: -f1) ]"
ck "mango has Mod+M cycle"       "grep -q 'bind=SUPER,m,switch_layout' $HOME/.config/mango/config.conf"
ck "fcitx single-instance (XDG)" "[ ! -e /etc/xdg/autostart/org.fcitx.Fcitx5.desktop ] || { ! grep -q 'exec-once=fcitx5' $HOME/.config/mango/config.conf && ! grep -q 'spawn-at-startup \"fcitx5\"' $HOME/.config/niri/config.kdl; }"

echo "── isolation plumbing ───────────────────────────────"
ck "kde theme hook executable"   "[ -x $HOME/.config/plasma-workspace/env/00-theme-profile.sh ]"
ck "kde stale-reset executable"  "[ -x $HOME/.config/plasma-workspace/env/01-reset-stale-plasma.sh ]"
ck "kde hook calls stray-guard"  "grep -q clean-stray-sessions $HOME/.config/plasma-workspace/env/01-reset-stale-plasma.sh"
ck "kded gtk-sync disabled"      "grep -A1 Module-gtkconfig $HOME/.config/kded6rc | grep -q false"
ck "profile scripts scope=3"     "grep -q 'PROFILES=(mango kde niri)' $HOME/.local/bin/apply-theme-profile && grep -q 'mango kde niri ' $HOME/.local/bin/save-noctalia-profile"
for p in mango niri; do ck "$p seed valid TOML"        "noctalia config validate $HOME/.config/theme-profiles/$p/noctalia-state.toml"; done
ck "kde = gtk-only seed (no noctalia)" "[ -f $HOME/.config/theme-profiles/kde/gtk-3.0/settings.ini ] && [ ! -e $HOME/.config/theme-profiles/kde/noctalia-state.toml ]"
# NOTE: seeds may currently hold IDENTICAL content by design (niri was
# cloned from mango as its starting look) — isolation is guaranteed by
# them being separate, non-linked files:
ck "seeds separate files (no links)" "[ -f $HOME/.config/theme-profiles/mango/noctalia-state.toml ] && [ ! -L $HOME/.config/theme-profiles/mango/noctalia-state.toml ] && [ -f $HOME/.config/theme-profiles/niri/noctalia-state.toml ] && [ ! -L $HOME/.config/theme-profiles/niri/noctalia-state.toml ]"
ck "greeter_sync auto_sync=false" "grep -A3 '\\[shell.greeter_sync\\]' $HOME/.config/theme-profiles/mango/noctalia-state.toml | grep -q 'auto_sync = false'"
ck "single greeter_sync table N" "[ \$(grep -c '\\[shell.greeter_sync\\]' $HOME/.config/theme-profiles/niri/noctalia-state.toml) = 1 ]"
ck "stamping logged to file"     "grep -q 'stamp.log' $HOME/.local/bin/apply-theme-profile"

echo "── purged features ──────────────────────────────────"
ck "toggle machinery gone"       "[ ! -e $HOME/.local/bin/toggle-desktop-look ] && [ ! -e $HOME/.local/share/desktop-look-toggle ] && [ ! -e $HOME/.config/mango/look-toggle.conf ]"
ck "zero live look-toggle refs"  "! grep -rn 'look-toggle\\|toggle-desktop' $HOME/.config/mango/config.conf | grep -v '^.*before-' | grep -q ."

echo "── portals/system ───────────────────────────────────"
ck "portal confs correct set"    "[ -e /etc/xdg/xdg-desktop-portal/mango-portals.conf ] && [ -e /etc/xdg/xdg-desktop-portal/niri-portals.conf ] && [ ! -e /etc/xdg/xdg-desktop-portal/i3-portals.conf ]"

echo
echo "RESULT: PASS=$P FAIL=$F"
[ $F -eq 0 ]
