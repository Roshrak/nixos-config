# Canonical Keymap — identical across Mango / Niri / KDE

Mod = Super (all sessions). "dispatch" lines = mango grammar.

## Apps & panels
| Key | Action | mango | niri | kde |
|---|---|---|---|---|
| Mod+Return | kitty | spawn,kitty ✅ | spawn kitty ✅ | *custom if wanted* |
| Mod+Space | launcher panel | noctalia panel-toggle launcher | same via Noctalia IPC ✅ | KRunner (Meta default) |
| Mod+S | control center | noctalia control-center ✅ | Noctalia control-center ✅ | — |
| Mod+, | settings toggle | settings-toggle ✅ | ✅ | systemsettings |
| Mod+E | nautilus | ✅ | ✅ | *dolphin* |
| Mod+Z | chromium | ✅ | ✅ | *native* |
| Mod+Escape | lock | noctalia session lock ✅ | ✅ | Meta+L (kwin) |
| Mod+Shift+E | session panel | panel-toggle session ✅ | ✅ | — |
| Print | region screenshot | screenshot-region ✅ | ✅ | Spectacle |
| Mod+V | clipboard panel | clipboard ✅ | ✅ | Klipper |
| Alt+Tab | window switcher | window-switcher ✅ | ✅ | kwin default |

## Windows
| Key | Action | mango | niri | kde |
|---|---|---|---|---|
| Mod+Q | close | killclient ✅ | close-window ✅ | Alt+F4 default |
| **Mod+M** | **maximize, bar stays** | switch_layout → monocle tag ✅ | maximize-column ✅ | Meta+M Maximize Window ✅ |
| Mod+F | true fullscreen | togglefullscreen ✅ | fullscreen-window ✅ | Meta+F? default |
| Mod+Shift+F | floating toggle | togglefloating ✅ | toggle-window-floating ✅ | n/a |
| Mod+N | layout cycle | switch_layout ✅ | *(niri auto) unbound* | — |
| Mod+R | reload config | reload_config ✅ | hot-reload automatic | — |
| Mod+Shift+Alt+M | quit compositor | quit ✅ | quit ✅ | — |

## Focus / move / workspaces / monitors
hjkl + arrows focus ✅ identical · Ctrl+hjkl/arrows move ✅
1–9 view/tag ↔ focus/move-column-to-workspace ✅
Mod+Alt+←/→ monitor focus ✅ · Mod+Alt(+Shift)+←→ and Shift+↑↓ move-to-monitor ✅
Mod+Scroll / Mod+O overview equivalents noted in config.kdl

## Media/hardware keys (identical spawns)
XF86 vol ± / mute → wpctl ; mic mute → wpctl source toggle (mango: noctalia)
brightness → noctalia brightness-± (niri) / brightnessctl (i3-era removed; mango keeps noctalia)
play/next/prev → noctalia media *

## Known semantic deltas (documented, intentional)
- Niri has no per-window "urgent" border color.
- Niri gestures cover workspace swipe only (3-finger window-move = mango-only).
- Mango M = monocle-on-tag (dwm semantics); single-window visual result ≈ KWin/Niri maximize but toggles the whole tag back with the same key.
