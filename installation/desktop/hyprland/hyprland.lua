-- Tonelico: plain Hyprland, using the existing Niri/Noctalia workflow.
-- Hyprland 0.55 loads hyprland.lua by default; the old .conf is historical.

hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = "auto-left", scale = 1 })

hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_IM_MODULES", "wayland;fcitx")
hl.env("XMODIFIERS", "@im=fcitx")

hl.config({
    cursor = { default_monitor = "eDP-1" },
    input = {
        kb_layout = "us",
        repeat_rate = 30,
        repeat_delay = 400,
        follow_mouse = 1,
        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            disable_while_typing = true,
        },
    },
    general = {
        gaps_in = 2,
        gaps_out = 2,
        border_size = 1,
        col = {
            active_border = "rgba(89b4faff)",
            inactive_border = "rgba(45475aff)",
        },
        layout = "dwindle",
        allow_tearing = false,
    },
    decoration = {
        rounding = 0,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        shadow = { enabled = false },
        blur = { enabled = false },
    },
    animations = { enabled = true },
    dwindle = { preserve_split = true },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0 },
})

-- Match Mango's measured transition times and easing curve. Hyprland 0.55
-- animation speeds use deciseconds (0.1 s per unit).
hl.curve("mango", {
    type = "bezier",
    points = { { 0.46, 1.0 }, { 0.29, 1.0 } },
})
hl.animation({ leaf = "windows", enabled = true, speed = 3.0, bezier = "mango", style = "slide" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.2, bezier = "mango", style = "popin 94%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.0, bezier = "mango", style = "popin 96%" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.0, bezier = "mango" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3.0, bezier = "mango" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.5, bezier = "mango", style = "slide" })
-- Noctalia owns its shell animation; avoid a second compositor animation.
hl.animation({ leaf = "layers", enabled = false })

-- Resolve output neighbors when the action runs: monitor hotplug can change
-- the topology after configuration has loaded. A missing neighbor/window is
-- intentionally a no-op.
local function move_to_neighbor_monitor(selector)
    return function()
        local target = hl.get_monitor(selector)
        local window = hl.get_active_window()
        if not target or not window then return end
        hl.dispatch(hl.dsp.window.move({ monitor = target, window = window }))
    end
end

local function focus_neighbor_monitor(selector)
    return function()
        local target = hl.get_monitor(selector)
        if not target then return end
        hl.dispatch(hl.dsp.focus({ monitor = target }))
    end
end

-- Match the existing Mango/Niri trackpad workflow. Hyprland 0.55 uses
-- explicit Lua gesture registrations; input.touchpad alone cannot add swipes.
-- Three fingers: swipe left/right through workspaces, one-to-one.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-- Four fingers: closest equivalent to Mango's overview gesture.
hl.gesture({ fingers = 4, direction = "up", action = function()
    hl.exec_cmd("noctalia msg window-switcher open")
end })
hl.gesture({ fingers = 4, direction = "down", action = function()
    hl.exec_cmd("noctalia msg window-switcher close")
end })
-- Match Mango's modifier gestures: a left swipe moves the window to the
-- next/right tag; a right swipe moves it to the previous/left tag.
hl.gesture({ fingers = 3, direction = "left", mods = "SUPER SHIFT", action = function()
    hl.dispatch(hl.dsp.window.move({ workspace = "e+1" }))
end })
hl.gesture({ fingers = 3, direction = "right", mods = "SUPER SHIFT", action = function()
    hl.dispatch(hl.dsp.window.move({ workspace = "e-1" }))
end })
hl.gesture({ fingers = 3, direction = "left", mods = "SUPER SHIFT ALT", action = function()
    move_to_neighbor_monitor("l")()
end })
hl.gesture({ fingers = 3, direction = "right", mods = "SUPER SHIFT ALT", action = function()
    move_to_neighbor_monitor("r")()
end })

-- Startup is one-shot. The session guard already applies the Hyprland theme;
-- these processes are compositor-specific and must wait for WAYLAND_DISPLAY.
hl.on("hyprland.start", function()
    hl.exec_cmd("bash /home/aesc/.local/bin/hypr-session-ready")
end)

-- Stop the Hyprland portal while the compositor still owns its Wayland
-- output proxies; otherwise its backend can crash while those proxies vanish.
hl.on("hyprland.shutdown", function()
    hl.exec_cmd("/run/current-system/sw/bin/systemctl --user stop xdg-desktop-portal-hyprland.service")
end)

local function bind(keys, command)
    hl.bind(keys, hl.dsp.exec_cmd(command))
end

-- Applications and the shared Noctalia shell.
bind("SUPER + Return", "kitty")
bind("SUPER + Space", "noctalia msg panel-toggle launcher")
bind("SUPER + S", "noctalia msg panel-toggle control-center")
bind("SUPER + Comma", "noctalia msg settings-toggle")
bind("SUPER + E", "nautilus")
bind("SUPER + Z", "chromium")
bind("SUPER + Escape", "noctalia msg session lock")
bind("SUPER + SHIFT + E", "noctalia msg panel-toggle session")
bind("SUPER + V", "noctalia msg panel-toggle clipboard")
bind("ALT + Tab", "noctalia msg window-switcher")
bind("ALT + Z", "fcitx5-remote -t")

-- Screenshots. The focused-window capture uses Hyprland's active-window geometry.
bind("Print", "noctalia msg screenshot-region")
bind("SUPER + Print", "noctalia msg screenshot-fullscreen")
bind("CTRL + Print", "bash /home/aesc/.local/bin/hypr-active-window-screenshot")

-- Window control. Super+N uses pseudotile as Hyprland's closest width toggle.
hl.bind("SUPER + Q", hl.dsp.window.close(), { repeating = true })
hl.bind("SUPER + SHIFT + Q", hl.dsp.window.close(), { repeating = true })
hl.bind("SUPER + M", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind("SUPER + N", hl.dsp.window.pseudo({ action = "toggle" }))
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind("SUPER + SHIFT + F", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + SHIFT + ALT + M", hl.dsp.exit())
-- Noctalia has no overview panel on Hyprland; use its window switcher.
hl.bind("SUPER + O", hl.dsp.exec_cmd("noctalia msg window-switcher"))
hl.bind("SUPER + SHIFT + mouse:274", hl.dsp.exec_cmd("noctalia msg window-switcher"))
hl.bind("SUPER + Tab", hl.dsp.window.cycle_next({ next = true }))
hl.bind("SUPER + R", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind("SUPER + SHIFT + Space", hl.dsp.window.float({ action = "toggle" }))

for _, pair in ipairs({ { "H", "left" }, { "L", "right" }, { "K", "up" }, { "J", "down" } }) do
    hl.bind("SUPER + " .. pair[1], hl.dsp.focus({ direction = pair[2] }))
    hl.bind("SUPER + CTRL + " .. pair[1], hl.dsp.window.swap({ direction = pair[2] }))
    hl.bind("SUPER + SHIFT + " .. pair[1], hl.dsp.window.move({ direction = pair[2] }))
end
hl.bind("SUPER + Left", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + Right", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + Up", hl.dsp.focus({ direction = "up" }))
hl.bind("SUPER + Down", hl.dsp.focus({ direction = "down" }))

for i = 1, 9 do
    hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end
hl.bind("SUPER + CTRL + Left", hl.dsp.focus({ workspace = "e-1" }))
hl.bind("SUPER + CTRL + Right", hl.dsp.focus({ workspace = "e+1" }))
hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind("SUPER + SHIFT + mouse_up", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + SHIFT + mouse_down", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + ALT + Left", focus_neighbor_monitor("l"))
hl.bind("SUPER + ALT + Right", focus_neighbor_monitor("r"))
hl.bind("SUPER + ALT + SHIFT + Left", move_to_neighbor_monitor("l"))
hl.bind("SUPER + ALT + SHIFT + Right", move_to_neighbor_monitor("r"))
hl.bind("SUPER + SHIFT + Left", move_to_neighbor_monitor("l"))
hl.bind("SUPER + SHIFT + Right", move_to_neighbor_monitor("r"))
hl.bind("SUPER + SHIFT + Up", move_to_neighbor_monitor("u"))
hl.bind("SUPER + SHIFT + Down", move_to_neighbor_monitor("d"))

hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("noctalia msg mic-mute"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("noctalia msg brightness-up"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("noctalia msg brightness-down"), { locked = true, repeating = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("noctalia msg media toggle"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("noctalia msg media toggle"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("noctalia msg media next"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("noctalia msg media previous"), { locked = true })

-- Skip the window popin effect on fullscreen windows.
hl.window_rule({ name = "audit-fullscreen-no-animation", match = { fullscreen = true }, no_anim = true })
