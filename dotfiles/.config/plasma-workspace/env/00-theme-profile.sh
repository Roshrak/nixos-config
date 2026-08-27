# Keep KDE's GTK theme separate from Mango's.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
apply-theme-profile kde >/dev/null 2>&1 || true
