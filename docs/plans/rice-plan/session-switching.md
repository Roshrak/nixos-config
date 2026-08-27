# Session switching (Mango <-> KDE) notes

## The fix installed
~/.config/plasma-workspace/env/01-reset-stale-plasma.sh

greetd's session teardown kills the session scope without running Plasma's
clean shutdown, so plasma-kwin_wayland.service and plasmashell can stay
"active" in the user systemd manager while their processes are dead. The
next Plasma login then hangs on a black screen with a blinking cursor
(startplasma waits for a kwin that never launches).

The env script stops those stale units and kills orphaned kwin_wayland /
plasmashell processes BEFORE startplasma starts the real ones.
First login of a boot = no-op. Re-login after Mango = clears zombies.

## Rescue: black screen / stuck compositor (no power cut needed)
1. Switch to a text console: Ctrl+Alt+F3
2. Log in with your user
3. Run:
       loginctl terminate-user $USER
   This ends all your sessions cleanly and returns you to the greeter.

Alternative if only the current graphical session is broken:
       systemctl --user stop plasma-workspace-wayland.target

## Related setup living elsewhere
- Theme separation between Mango/KDE: ~/.config/theme-profiles/ +
  ~/.local/bin/apply-theme-profile (stamped by mango config.conf exec-once
  and ~/.config/plasma-workspace/env/00-theme-profile.sh)
- KDE kitty theme pinned to Breeze Dark so Noctalia wallpaper theming
  from Mango cannot leak into KDE sessions.
