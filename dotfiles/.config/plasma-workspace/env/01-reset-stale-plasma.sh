# Reset stale Plasma user units left over from a previous session.
# greetd's session teardown skips ksmserver's clean shutdown, so
/home/aesc/.local/bin/clean-stray-sessions >/dev/null 2>&1 || true
# plasma-kwin_wayland.service / plasmashell can stay "active" while dead,
# which makes the NEXT Plasma login hang on a black screen.
systemctl --user stop \
    plasma-workspace-wayland.target \
    plasma-kwin_wayland.service \
    plasma-plasmashell.service plasma-ksplash.service xdg-desktop-portal-kde.service 2>/dev/null || true

# Belt and braces: kill any orphaned compositor still holding DRM master.
pkill -u "$(id -u)" -x kwin_wayland 2>/dev/null || true
pkill -u "$(id -u)" -x plasmashell  2>/dev/null || true
