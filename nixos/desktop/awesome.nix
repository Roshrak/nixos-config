{ pkgs, ... }:

let
  awesomeRc = pkgs.writeText "tonelico-awesome-rc.lua" ''
    local awful = require("awful")
    local gears = require("gears")
    local wibox = require("wibox")
    local beautiful = require("beautiful")
    require("awful.autofocus")

    local modkey = "Mod4"
    local terminal = "kitty"
    local launcher = "rofi -show drun"
    local wallpaper = "/home/aesc/Pictures/Wallpapers/wallpaperflare.com_wallpaper.jpg"
    local palette = {
      background = "#0f141c",
      surface = "#161e28",
      foreground = "#dee2ef",
      muted = "#8c9aaa",
      accent = "#50d8ec",
      border = "#3d4758",
      urgent = "#ff7187",
    }

    beautiful.init({
      font = "JetBrainsMono Nerd Font 10",
      bg_normal = palette.background,
      bg_focus = palette.surface,
      bg_urgent = palette.urgent,
      fg_normal = palette.foreground,
      fg_focus = palette.foreground,
      fg_urgent = palette.background,
      border_width = 2,
      border_normal = palette.border,
      border_focus = palette.accent,
      border_marked = palette.urgent,
      useless_gap = 8,
      wibar_height = 32,
      menu_height = 28,
      menu_width = 180,
      notification_bg = palette.surface,
      notification_fg = palette.foreground,
    })

    awful.layout.layouts = {
      awful.layout.suit.tile,
      awful.layout.suit.floating,
      awful.layout.suit.max,
    }

    local tag_names = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

    awful.screen.connect_for_each_screen(function(s)
      awful.tag(tag_names, s, awful.layout.layouts[1])

      s.wibar = awful.wibar({
        position = "top",
        screen = s,
        height = beautiful.wibar_height,
        bg = palette.background .. "ee",
      })

      local taglist = awful.widget.taglist({
        screen = s,
        filter = awful.widget.taglist.filter.all,
        buttons = {
          awful.button({}, 1, function(t) t:view_only() end),
          awful.button({ modkey }, 1, function(t)
            if client.focus then client.focus:move_to_tag(t) end
          end),
          awful.button({}, 4, function(t) awful.tag.viewprev(t.screen) end),
          awful.button({}, 5, function(t) awful.tag.viewnext(t.screen) end),
        },
      })
      local tasklist = awful.widget.tasklist({
        screen = s,
        filter = awful.widget.tasklist.filter.currenttags,
        buttons = {
          awful.button({}, 1, function(c)
            c:activate({ context = "tasklist", action = "toggle_minimization" })
          end),
          awful.button({}, 4, function() awful.client.focus.byidx(-1) end),
          awful.button({}, 5, function() awful.client.focus.byidx(1) end),
        },
      })
      local clock = wibox.widget.textclock("  %a %d %b  %H:%M  ", 60)
      local tray = wibox.widget.systray()

      s.wibar:setup({
        layout = wibox.layout.align.horizontal,
        {
          layout = wibox.layout.fixed.horizontal,
          taglist,
          wibox.widget.textbox("  "),
          wibox.widget.textbox("TONELICO"),
        },
        tasklist,
        {
          layout = wibox.layout.fixed.horizontal,
          tray,
          clock,
        },
      })

      if gears.filesystem.file_readable(wallpaper) then
        gears.wallpaper.maximized(wallpaper, s, true)
      else
        gears.wallpaper.set(palette.background)
      end
    end)

    root.buttons(gears.table.join(
      awful.button({}, 4, awful.tag.viewnext),
      awful.button({}, 5, awful.tag.viewprev)
    ))

    local function spawn(command)
      awful.spawn.with_shell(command)
    end

    local globalkeys = gears.table.join(
      awful.key({ modkey }, "Return", function() spawn(terminal) end,
        { description = "open terminal", group = "launcher" }),
      awful.key({ modkey }, "space", function() spawn(launcher) end,
        { description = "open application launcher", group = "launcher" }),
      awful.key({ modkey }, "e", function() spawn("nautilus") end,
        { description = "open files", group = "launcher" }),
      awful.key({ modkey }, "z", function() spawn("chromium") end,
        { description = "open browser", group = "launcher" }),
      awful.key({ modkey }, "s", function() spawn("xfce4-settings-manager") end,
        { description = "open settings", group = "launcher" }),
      awful.key({ modkey }, "Escape", function() spawn("xfce4-screensaver-command --lock") end,
        { description = "lock screen", group = "session" }),
      awful.key({ modkey, "Shift" }, "e", function() spawn("lxqt-leave") end,
        { description = "logout and power menu", group = "session" }),
      awful.key({ modkey }, "q", function() if client.focus then client.focus:kill() end end,
        { description = "close window", group = "client" }),
      awful.key({ modkey }, "f", function() if client.focus then client.focus.fullscreen = not client.focus.fullscreen end end,
        { description = "toggle fullscreen", group = "client" }),
      awful.key({ modkey }, "m", function()
        if client.focus then client.focus.maximized = not client.focus.maximized; client.focus:raise() end
      end, { description = "toggle maximize", group = "client" }),
      awful.key({ modkey, "Shift" }, "v", function() if client.focus then client.focus.floating = not client.focus.floating end end,
        { description = "toggle floating", group = "client" }),
      awful.key({ modkey }, "h", function() awful.client.focus.bydirection("left"); if client.focus then client.focus:raise() end end),
      awful.key({ modkey }, "l", function() awful.client.focus.bydirection("right"); if client.focus then client.focus:raise() end end),
      awful.key({ modkey }, "k", function() awful.client.focus.bydirection("up"); if client.focus then client.focus:raise() end end),
      awful.key({ modkey }, "j", function() awful.client.focus.bydirection("down"); if client.focus then client.focus:raise() end end),
      awful.key({ modkey, "Control" }, "Left", awful.tag.viewprev,
        { description = "previous workspace", group = "tag" }),
      awful.key({ modkey, "Control" }, "Right", awful.tag.viewnext,
        { description = "next workspace", group = "tag" }),
      awful.key({ modkey }, "Tab", function() awful.client.focus.history.previous(); if client.focus then client.focus:raise() end end,
        { description = "previous window", group = "client" }),
      awful.key({ modkey, "Shift" }, "space", function() awful.layout.inc(1) end,
        { description = "next layout", group = "layout" }),
      awful.key({ modkey }, "Print", function() spawn("xfce4-screenshooter -f") end,
        { description = "screenshot", group = "media" }),
      awful.key({ modkey, "Shift" }, "Print", function() spawn("xfce4-screenshooter -r") end,
        { description = "region screenshot", group = "media" }),
      awful.key({ modkey }, "v", function() spawn("xfce4-clipman-history") end,
        { description = "clipboard history", group = "media" }),
      awful.key({}, "XF86AudioRaiseVolume", function() spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end),
      awful.key({}, "XF86AudioLowerVolume", function() spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end),
      awful.key({}, "XF86AudioMute", function() spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end),
      awful.key({}, "XF86AudioMicMute", function() spawn("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle") end),
      awful.key({}, "XF86MonBrightnessUp", function() spawn("brightnessctl set 5%+") end),
      awful.key({}, "XF86MonBrightnessDown", function() spawn("brightnessctl set 5%-") end),
      awful.key({}, "XF86AudioPlay", function() spawn("playerctl play-pause") end),
      awful.key({}, "XF86AudioNext", function() spawn("playerctl next") end),
      awful.key({}, "XF86AudioPrev", function() spawn("playerctl previous") end),
      awful.key({}, "XF86Tools", function() spawn("fcitx5-remote -t") end)
    )

    local clientbuttons = gears.table.join(
      awful.button({}, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
      end),
      awful.button({ modkey }, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.move(c)
      end),
      awful.button({ modkey }, 3, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.resize(c)
      end)
    )

    for i = 1, #tag_names do
      local key = "#" .. (i % 10 + 9)
      globalkeys = gears.table.join(globalkeys,
        awful.key({ modkey }, key, function()
          local tag = awful.screen.focused().tags[i]
          if tag then tag:view_only() end
        end, { description = "view workspace " .. i, group = "tag" }),
        awful.key({ modkey, "Shift" }, key, function()
          if client.focus then
            local tag = client.focus.screen.tags[i]
            if tag then client.focus:move_to_tag(tag) end
          end
        end, { description = "move window to workspace " .. i, group = "tag" })
      )
    end

    root.keys(globalkeys)

    awful.rules.rules = {
      {
        rule = {},
        properties = {
          border_width = beautiful.border_width,
          border_color = beautiful.border_normal,
          focus = awful.client.focus.filter,
          raise = true,
          buttons = clientbuttons,
          screen = awful.screen.preferred,
          placement = awful.placement.no_offscreen,
        },
      },
      {
        rule_any = {
          instance = { "copyq", "pinentry" },
          class = { "Arandr", "Blueman-manager", "Gpick", "Kruler", "MessageWin", "Sxiv", "Wpa_gui", "Xfce4-screenshooter" },
          name = { "Event Tester" },
          role = { "AlarmWindow", "ConfigManager", "pop-up" },
        },
        properties = { floating = true },
      },
    }

    client.connect_signal("manage", function(c)
      if c.floating then
        gears.timer.delayed_call(function()
          if not c.valid or not c.floating then return end
          local pointer = mouse.coords()
          local target_screen = mouse.screen or c.screen
          if target_screen then c.screen = target_screen end
          local geometry = c:geometry()
          c:geometry({
            x = pointer.x - math.floor(geometry.width / 2),
            y = pointer.y - math.floor(geometry.height / 2),
          })
          awful.placement.no_offscreen(c, { honor_workarea = true })
        end)
      end
    end)

    client.connect_signal("focus", function(c)
      c.border_color = beautiful.border_focus
    end)
    client.connect_signal("unfocus", function(c)
      c.border_color = beautiful.border_normal
    end)
  '';
  awesomeDunst = pkgs.writeText "tonelico-awesome-dunstrc" ''
    [global]
        monitor = 0
        follow = mouse
        width = 360
        height = 300
        origin = top-right
        offset = 18x52
        notification_limit = 5
        progress_bar = true
        indicate_hidden = yes
        transparency = 0
        separator_height = 2
        padding = 12
        horizontal_padding = 14
        frame_width = 2
        frame_color = "#50d8ec"
        separator_color = frame
        font = JetBrainsMono Nerd Font 10
        line_height = 0
        markup = full
        format = "<b>%s</b>\n%b"
        alignment = left
        vertical_alignment = center
        show_age_threshold = 60
        word_wrap = yes
        ignore_newline = no
        stack_duplicates = true
        hide_duplicate_count = false
        sticky_history = yes
        history_length = 20
        browser = /run/current-system/sw/bin/chromium
        icon_position = left
        min_icon_size = 32
        max_icon_size = 48

    [urgency_low]
        background = "#0f141c"
        foreground = "#dee2ef"
        timeout = 4

    [urgency_normal]
        background = "#161e28"
        foreground = "#dee2ef"
        timeout = 6

    [urgency_critical]
        background = "#2a1720"
        foreground = "#fff0f2"
        frame_color = "#ff7187"
        timeout = 0
  '';
  awesomeSession = pkgs.writeShellScriptBin "awesome-session" ''
    exec /run/current-system/sw/bin/awesome -c /etc/xdg/awesome/rc.lua "$@"
  '';
in
{
  services.xserver.windowManager.awesome.enable = true;

  environment.etc."xdg/awesome/rc.lua".source = awesomeRc;
  environment.etc."xdg/dunst/awesome.conf".source = awesomeDunst;

  environment.systemPackages = with pkgs; [
    awesomeSession
    dunst
    rofi
    xclip
    xdotool
    wmctrl
    lxqt.lxqt-policykit
    xfce4-clipman-plugin
    xfce4-screensaver
    networkmanagerapplet
    blueman
    brightnessctl
    playerctl
    xfce4-screenshooter
    lxqt.lxqt-session
  ];

  # Every user service below exists only for the Awesome graphical session.
  # Stopping the target at logout tears down its applets and sole notification
  # server without disturbing another desktop or the shared user manager.
  systemd.user.targets.awesome-session = {
    description = "AwesomeWM graphical session services";
  };

  systemd.user.services = {
    awesome-dunst = {
      description = "Awesome session notification server";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.dunst}/bin/dunst --config /etc/xdg/dunst/awesome.conf";
        Restart = "on-failure";
      };
    };
    awesome-polkit-agent = {
      description = "Awesome session polkit authentication agent";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
        Restart = "on-failure";
      };
    };
    awesome-network-applet = {
      description = "Awesome session NetworkManager tray applet";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.networkmanagerapplet}/bin/nm-applet";
        Restart = "on-failure";
      };
    };
    awesome-bluetooth-applet = {
      description = "Awesome session Bluetooth tray applet";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.blueman}/bin/blueman-applet";
        Restart = "on-failure";
      };
    };
    awesome-clipboard = {
      description = "Awesome session clipboard manager";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.xfce4-clipman-plugin}/bin/xfce4-clipman";
        Restart = "on-failure";
      };
    };
    awesome-screensaver = {
      description = "Awesome session screen locker";
      wantedBy = [ "awesome-session.target" ];
      partOf = [ "awesome-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.xfce4-screensaver}/bin/xfce4-screensaver --no-daemon";
        Restart = "on-failure";
      };
    };
  };
}
