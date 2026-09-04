# Keep KDE's GTK and Kitty theme separate from Sway, Niri, and Mango.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export KITTY_CONFIG_DIRECTORY="/home/aesc/.config/kitty/profiles/kde"
/home/aesc/.local/bin/apply-theme-profile kde >/dev/null 2>&1 || true
