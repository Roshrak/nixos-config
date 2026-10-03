#!/usr/bin/env python3
"""Isolated tests for the exact autosleep.py source; no desktop APIs are called."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


SOURCE = Path(os.environ.get("AUTOSLEEP_TEST_SOURCE", "/etc/nixos/desktop/autosleep.py"))
SPEC = importlib.util.spec_from_file_location("autosleep", SOURCE)
autosleep = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(autosleep)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="autosleep-policy-test-")
        self.config_home = Path(self.temp.name) / ".config"
        self.config_home.mkdir(mode=0o700)
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config_home)}, clear=False)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_default_off_and_revisions_are_monotonic_and_idempotent(self):
        self.assertEqual(autosleep.read_policy()["mode"], "off")
        self.assertFalse((self.config_home / "autosleep").exists())
        self.assertEqual(autosleep.write_policy("on")["revision"], 1)
        self.assertEqual(autosleep.write_policy("on")["revision"], 1)
        self.assertEqual(autosleep.write_policy("off")["revision"], 2)
        self.assertEqual(autosleep.read_policy()["mode"], "off")
        self.assertEqual((self.config_home / "autosleep" / "policy.json").stat().st_mode & 0o777, 0o600)

    def test_symlinked_policy_file_is_rejected(self):
        state_dir = self.config_home / "autosleep"
        state_dir.mkdir(mode=0o700)
        target = Path(self.temp.name) / "outside.json"
        target.write_text('{"version":1,"mode":"on","revision":7}\n')
        target.chmod(0o600)
        (state_dir / "policy.json").symlink_to(target)
        with self.assertRaises(autosleep.AutosleepError):
            autosleep.read_policy()

    def test_read_only_status_does_not_create_default_policy_or_noctalia_directories(self):
        state_home = Path(self.temp.name) / "missing-state"
        env = {
            "XDG_CONFIG_HOME": str(self.config_home),
            "NOCTALIA_STATE_HOME": str(state_home),
            "THEME_PROFILE": "sway",
            "XDG_CURRENT_DESKTOP": "sway",
            "XDG_SESSION_TYPE": "wayland",
        }
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
            autosleep, "run", return_value="inactive"
        ):
            report = autosleep.status()
        self.assertEqual(report["persisted_mode"], "off")
        self.assertFalse(report["session"]["configuration_matches"])
        self.assertFalse((self.config_home / "autosleep").exists())
        self.assertFalse(state_home.exists())

    def test_atomic_initial_write_does_not_replace_a_racing_file(self):
        target = self.config_home / "race.json"
        real_link = os.link

        def race_link(source, destination, **kwargs):
            Path(destination).write_text("newer user data")
            return real_link(source, destination, **kwargs)

        with mock.patch.object(autosleep.os, "link", side_effect=race_link):
            with self.assertRaises(FileExistsError):
                autosleep._atomic_write(target, b"autosleep data\n", private=False, mode=0o644)
        self.assertEqual(target.read_text(), "newer user data")


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.settings = {}
        self.calls = []

    def test_all_current_session_families_select_an_adapter(self):
        cases = [
            ({"XDG_CURRENT_DESKTOP": "XFCE", "XDG_SESSION_TYPE": "x11"}, "xfce"),
            ({"XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "wayland"}, "gnome"),
            ({"XDG_CURRENT_DESKTOP": "KDE", "XDG_SESSION_TYPE": "wayland"}, "plasma"),
            ({"THEME_PROFILE": "hyprland", "XDG_CURRENT_DESKTOP": "Hyprland", "XDG_SESSION_TYPE": "wayland"}, "noctalia"),
            ({"THEME_PROFILE": "sway", "XDG_CURRENT_DESKTOP": "sway", "XDG_SESSION_TYPE": "wayland"}, "noctalia"),
            ({"THEME_PROFILE": "niri", "XDG_CURRENT_DESKTOP": "niri", "XDG_SESSION_TYPE": "wayland"}, "noctalia"),
            ({"THEME_PROFILE": "mango", "XDG_CURRENT_DESKTOP": "mango", "XDG_SESSION_TYPE": "wayland"}, "noctalia"),
        ]
        for env, expected in cases:
            with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(autosleep.identify_backend()[0], expected)

    def test_gnome_readback_matches_both_modes_without_touching_live_settings(self):
        gsettings = {
            ("org.gnome.desktop.session", "idle-delay"): "uint32 0",
            ("org.gnome.desktop.screensaver", "lock-enabled"): "true",
            ("org.gnome.desktop.screensaver", "lock-delay"): "uint32 0",
            ("org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type"): "'nothing'",
            ("org.gnome.settings-daemon.plugins.power", "sleep-inactive-battery-type"): "'nothing'",
        }

        def set_value(schema, key, value):
            gsettings[(schema, key)] = value

        def get_value(schema, key):
            return gsettings[(schema, key)]

        with mock.patch.object(autosleep, "_gsettings_set", side_effect=set_value), mock.patch.object(
            autosleep, "_gsettings_get", side_effect=get_value
        ):
            on = autosleep.apply_gnome("on")
            off = autosleep.apply_gnome("off")
        self.assertTrue(on["configuration_matches"])
        self.assertTrue(off["configuration_matches"])
        self.assertFalse(on["runtime_verified"])
        self.assertEqual(gsettings[("org.gnome.desktop.screensaver", "lock-enabled")], "true")

    def test_xfce_on_off_readback_has_one_timer_owner_and_no_sleep_request(self):
        xfconf = {}
        xset = {"timeout": 0, "cycle": 0, "standby": 0, "suspend": 0, "off": 0, "enabled": False}
        service_state = {"value": "inactive"}

        def xfconf_set(channel, prop, kind, value):
            xfconf[(channel, prop)] = value

        def xfconf_get(channel, prop):
            return xfconf[(channel, prop)]

        def fake_run(argv, check=True):
            self.calls.append(argv)
            if argv[:3] == ["systemctl", "--user", "restart"]:
                service_state["value"] = "active"
                return ""
            if argv[:3] == ["systemctl", "--user", "stop"]:
                service_state["value"] = "inactive"
                return ""
            if argv[:3] == ["systemctl", "--user", "is-active"]:
                return service_state["value"]
            if argv[0] != "xset":
                return ""
            args = argv[1:]
            if args == ["+dpms"]:
                xset["enabled"] = True
            elif args[:1] == ["s"] and args[1:] == ["off"]:
                xset["timeout"] = 0
                xset["cycle"] = 0
            elif args[:1] == ["s"] and len(args) == 3:
                xset["timeout"], xset["cycle"] = map(int, args[1:])
            elif args[:1] == ["dpms"] and len(args) == 4 and args[1] != "force":
                xset["standby"], xset["suspend"], xset["off"] = map(int, args[1:])
            elif args == ["-dpms"]:
                xset["enabled"] = False
            elif args == ["dpms", "force", "on"]:
                pass
            elif args == ["-q"]:
                dpms_flag = "Enabled" if xset["enabled"] else "Disabled"
                return (
                    "Screen Saver:\n  timeout: %d cycle: %d\n"
                    "DPMS (Energy Star):\n  Standby: %d    Suspend: %d    Off: %d\n  DPMS is %s\n"
                    % (xset["timeout"], xset["cycle"], xset["standby"], xset["suspend"], xset["off"], dpms_flag)
                )
            return ""

        with mock.patch.object(autosleep, "_xfconf_set", side_effect=xfconf_set), mock.patch.object(
            autosleep, "_xfconf_get", side_effect=xfconf_get
        ), mock.patch.object(autosleep, "run", side_effect=fake_run):
            on = autosleep.apply_xfce("on")
            off = autosleep.apply_xfce("off")
        self.assertTrue(on["configuration_matches"])
        self.assertTrue(off["configuration_matches"])
        self.assertEqual(on["screensaver_idle"], "false")
        self.assertEqual(on["idle_service_state"], "active")
        self.assertEqual(off["idle_service_state"], "inactive")
        self.assertTrue(xfconf[("xfce4-screensaver", "/lock/saver-activation/enabled")] == "true")
        self.assertEqual(xfconf[("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-ac")], "0")
        self.assertEqual(xfconf[("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-battery")], "0")
        self.assertEqual(xset["timeout"], 0)
        self.assertFalse(xset["enabled"])
        prohibited = {"kill", "pkill", "killall", "suspend", "hibernate", "logout"}
        self.assertFalse(any(Path(call[0]).name in prohibited or any(part in prohibited for part in call) for call in self.calls))
        self.assertTrue(
            all(call[0] != "systemctl" or call[-1] == "autosleep-idle-x11.service" for call in self.calls)
        )

    def test_x11_virtual_idle_clock_locks_before_display_power_and_wakes_without_unlocking(self):
        actions = autosleep._x11_idle_actions
        self.assertEqual(actions(299_999, False, False), [])
        self.assertEqual(actions(300_000, False, False), ["lock-request"])
        self.assertEqual(actions(304_999, False, False), ["lock-request"])
        self.assertEqual(actions(305_000, False, False), ["lock-request"])
        self.assertEqual(actions(305_000, True, False), ["display-off"])
        self.assertEqual(actions(600_000, True, True), [])
        self.assertEqual(actions(10, True, True), ["display-on"])

    def test_plasma_66_uses_installed_schema_and_preserves_global_critical_action(self):
        config = {
            ("powerdevilrc", "LowBattery", "SuspendAndShutdown", "AutoSuspendAction"): "1",
            ("powerdevilrc", "LowBattery", "SuspendAndShutdown", "PowerDownAction"): "16",
            ("powerdevilrc", "LowBattery", "Display", "Brightness"): "30",
        }

        def fake_run(argv, check=True):
            self.calls.append(argv)
            if argv[0] == "kwriteconfig6":
                file_name = argv[argv.index("--file") + 1]
                groups = []
                for i, token in enumerate(argv[:-1]):
                    if token == "--group":
                        groups.append(argv[i + 1])
                key = argv[argv.index("--key") + 1]
                value = argv[-1]
                config[(file_name, *groups, key)] = value
                return ""
            if argv[0] == "kreadconfig6":
                file_name = argv[argv.index("--file") + 1]
                groups = []
                for i, token in enumerate(argv[:-1]):
                    if token == "--group":
                        groups.append(argv[i + 1])
                key = argv[argv.index("--key") + 1]
                return config.get((file_name, *groups, key), "")
            if argv[0] == "qdbus":
                return ""
            raise AssertionError(argv)

        with mock.patch.object(autosleep, "run", side_effect=fake_run):
            on = autosleep.apply_plasma("on")
            off = autosleep.apply_plasma("off")
        self.assertTrue(on["configuration_matches"])
        self.assertTrue(off["configuration_matches"])
        self.assertEqual(config[("powerdevilrc", "LowBattery", "SuspendAndShutdown", "AutoSuspendAction")], "1")
        self.assertEqual(config[("powerdevilrc", "LowBattery", "SuspendAndShutdown", "PowerDownAction")], "16")
        self.assertTrue(any("reparseConfiguration" in call[-1] for call in self.calls))
        self.assertNotIn("DPMSControl", repr(self.calls))

    def test_noctalia_changes_only_managed_idle_behavior_and_reports_inhibitors(self):
        with tempfile.TemporaryDirectory(prefix="autosleep-noctalia-test-") as temp:
            state_home = Path(temp) / "state"
            config_home = Path(temp) / "config"
            noctalia_dir = state_home / "noctalia"
            noctalia_dir.mkdir(parents=True, mode=0o700)
            config_home.mkdir(mode=0o700)
            config_path = noctalia_dir / "settings.toml"
            config_path.write_text(
                '[appearance]\ncolor = "dark"\n[idle]\nother = true\n'
                '[idle.behavior.lock]\naction = "lock"\nenabled = true\ntimeout = 30\n'
                '[idle.behavior.screen-off]\naction = "screen_off"\nenabled = true\ntimeout = 60\n'
                '[idle.behavior.suspend]\naction = "suspend"\nenabled = true\ntimeout = 90\n'
                '[idle.behavior.custom]\naction = "run"\ncommand = "echo preserve"\nenabled = false\n'
            )
            config_path.chmod(0o600)
            service_state = {"value": "inactive"}

            def fake_run(argv, check=True):
                self.calls.append(argv)
                if argv[:3] == ["/run/current-system/sw/bin/systemctl", "--user", "restart"]:
                    service_state["value"] = "active"
                elif argv[:3] == ["/run/current-system/sw/bin/systemctl", "--user", "stop"]:
                    service_state["value"] = "inactive"
                elif argv[:3] == ["/run/current-system/sw/bin/systemctl", "--user", "is-active"]:
                    return service_state["value"]
                return ""

            with mock.patch.dict(
                os.environ,
                {
                    "NOCTALIA_STATE_HOME": str(state_home),
                    "THEME_PROFILE": "sway",
                    "XDG_CURRENT_DESKTOP": "sway",
                    "XDG_SESSION_TYPE": "wayland",
                    "XDG_CONFIG_HOME": str(config_home),
                },
                clear=False,
            ), mock.patch.object(autosleep, "run", side_effect=fake_run):
                heartbeat = Path(temp) / "app-heartbeat.log"
                app_code = (
                    "import pathlib,time\n"
                    "p=pathlib.Path(" + repr(str(heartbeat)) + ")\n"
                    "while True:\n"
                    " p.open('a').write('tick\\n')\n"
                    " time.sleep(0.02)\n"
                )
                app = subprocess.Popen([sys.executable, "-c", app_code])
                try:
                    deadline = time.monotonic() + 2
                    while not heartbeat.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(heartbeat.exists())
                    on = autosleep.apply_noctalia("on")
                    hypridle_on = (config_home / "autosleep" / "hypridle.conf").read_text()
                    autosleep.write_policy("on")
                    status_on = autosleep.status()
                    off = autosleep.apply_noctalia("off")
                    autosleep.write_policy("off")
                    status_off = autosleep.status()
                    before_ticks = len(heartbeat.read_text().splitlines())
                    time.sleep(0.1)
                    after_ticks = len(heartbeat.read_text().splitlines())
                    self.assertIsNone(app.poll())
                    self.assertGreater(after_ticks, before_ticks)
                finally:
                    app.terminate()
                    app.wait(timeout=2)
            self.assertTrue(on["configuration_matches"])
            self.assertTrue(off["configuration_matches"])
            self.assertFalse(on["runtime_verified"])
            self.assertIn("inhibitors", on)
            self.assertEqual(on["idle_service_state"], "active")
            self.assertEqual(off["idle_service_state"], "inactive")
            self.assertTrue(status_on["session"]["configuration_matches"])
            self.assertEqual(status_on["session"]["idle_service_state"], "active")
            self.assertTrue(status_off["session"]["configuration_matches"])
            self.assertEqual(status_off["session"]["idle_service_state"], "inactive")
            self.assertTrue(on["hypridle_configuration_matches"])
            self.assertIn("timeout = 300", hypridle_on)
            self.assertIn("timeout = 305", hypridle_on)
            self.assertIn("ignore_dbus_inhibit = true", hypridle_on)
            self.assertIn("ignore_systemd_inhibit = true", hypridle_on)
            self.assertIn("ignore_wayland_inhibit = true", hypridle_on)
            self.assertIn("ignore_inhibit = true", hypridle_on)
            self.assertIn("autosleep-display-off", hypridle_on)
            self.assertIn("on-resume = /run/current-system/sw/bin/autosleep-display-on", hypridle_on)
            self.assertNotIn("condition_cmd", hypridle_on)
            self.assertNotIn("suspend", hypridle_on)
            self.assertNotIn("listener {", (config_home / "autosleep" / "hypridle.conf").read_text())
            parsed = autosleep.tomlkit.parse(config_path.read_text())
            self.assertEqual(parsed["appearance"]["color"], "dark")
            self.assertTrue(parsed["idle"]["other"])
            self.assertFalse(parsed["idle"]["behavior"]["lock"]["enabled"])
            self.assertFalse(parsed["idle"]["behavior"]["screen-off"]["enabled"])
            self.assertFalse(parsed["idle"]["behavior"]["suspend"]["enabled"])
            self.assertFalse(parsed["idle"]["behavior"]["custom"]["enabled"])
            self.assertEqual(parsed["idle"]["behavior"]["custom"]["command"], "echo preserve")

    def test_noctalia_preserves_enabled_user_action_and_reports_policy_conflict(self):
        with tempfile.TemporaryDirectory(prefix="autosleep-noctalia-custom-test-") as temp:
            root = Path(temp)
            state_home = root / "state"
            noctalia_dir = state_home / "noctalia"
            noctalia_dir.mkdir(parents=True, mode=0o700)
            config_home = root / "config"
            config_home.mkdir(mode=0o700)
            config_path = noctalia_dir / "settings.toml"
            config_path.write_text(
                '[idle.behavior.custom]\naction = "run"\ncommand = "echo preserve"\nenabled = true\n'
            )
            config_path.chmod(0o600)

            def fake_run(argv, check=True):
                self.calls.append(argv)
                if argv[:3] == ["/run/current-system/sw/bin/systemctl", "--user", "is-active"]:
                    return "inactive"
                return ""

            env = {
                "NOCTALIA_STATE_HOME": str(state_home),
                "THEME_PROFILE": "sway",
                "XDG_CURRENT_DESKTOP": "sway",
                "XDG_SESSION_TYPE": "wayland",
                "XDG_CONFIG_HOME": str(config_home),
            }
            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
                autosleep, "run", side_effect=fake_run
            ):
                result = autosleep.apply_noctalia("off")

            parsed = autosleep.tomlkit.parse(config_path.read_text())
            self.assertTrue(parsed["idle"]["behavior"]["custom"]["enabled"])
            self.assertEqual(parsed["idle"]["behavior"]["custom"]["command"], "echo preserve")
            self.assertEqual(result["unmanaged_enabled_idle_behaviors"], ["custom"])
            self.assertIsNotNone(result["unmanaged_idle_behavior_warning"])
            self.assertFalse(result["configuration_matches"])

    def test_noctalia_idle_callbacks_recheck_mode_and_lock_under_policy_lock(self):
        with tempfile.TemporaryDirectory(prefix="autosleep-callback-test-") as temp:
            config_home = Path(temp) / ".config"
            config_home.mkdir(mode=0o700)
            env = {
                "XDG_CONFIG_HOME": str(config_home),
                "THEME_PROFILE": "niri",
                "XDG_SESSION_TYPE": "wayland",
                "XDG_SESSION_ID": "13",
            }
            locked_hint = {"value": "no"}

            def fake_run(argv, check=True):
                self.calls.append(argv)
                if argv[:2] == ["loginctl", "show-session"]:
                    return (
                        f"User={os.getuid()}\nActive=yes\nType=wayland\nClass=user\n"
                        f"LockedHint={locked_hint['value']}\n"
                    )
                if argv[:2] == ["loginctl", "lock-session"]:
                    locked_hint["value"] = "yes"
                    return ""
                if argv[:3] == ["noctalia", "msg", "dpms-off"]:
                    return ""
                raise AssertionError(argv)

            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(autosleep, "run", side_effect=fake_run):
                autosleep.write_policy("on")
                self.assertTrue(autosleep._idle_callback("lock"))
                locked_hint["value"] = "no"
                with self.assertRaises(autosleep.AutosleepError):
                    autosleep._idle_callback("display-off")
                self.assertFalse(any(call[:3] == ["noctalia", "msg", "dpms-off"] for call in self.calls))
                locked_hint["value"] = "yes"
                self.assertTrue(autosleep._idle_callback("lock-confirmed"))
                self.assertTrue(autosleep._idle_callback("display-off"))
                self.assertTrue(any(call[:2] == ["loginctl", "lock-session"] for call in self.calls))
                self.assertTrue(any(call[:3] == ["noctalia", "msg", "dpms-off"] for call in self.calls))

                self.calls.clear()
                with autosleep.PolicyLock():
                    autosleep.write_policy("off")
                self.assertTrue(autosleep._idle_callback("lock"))
                self.assertFalse(autosleep._idle_callback("lock-confirmed"))
                self.assertTrue(autosleep._idle_callback("display-off"))
                self.assertFalse(any(call[0] in {"loginctl", "noctalia"} for call in self.calls))

    def test_autosleep_off_waits_for_an_inflight_idle_callback_without_losing_final_mode(self):
        with tempfile.TemporaryDirectory(prefix="autosleep-callback-race-test-") as temp:
            config_home = Path(temp) / ".config"
            config_home.mkdir(mode=0o700)
            env = {
                "XDG_CONFIG_HOME": str(config_home),
                "THEME_PROFILE": "sway",
                "XDG_SESSION_TYPE": "wayland",
                "XDG_SESSION_ID": "13",
            }
            lock_started = threading.Event()
            release_lock = threading.Event()
            off_finished = threading.Event()
            errors = []

            def fake_run(argv, check=True):
                if argv[:2] == ["loginctl", "show-session"]:
                    return f"User={os.getuid()}\nActive=yes\nType=wayland\nClass=user\nLockedHint=no\n"
                if argv[:2] == ["loginctl", "lock-session"]:
                    lock_started.set()
                    if not release_lock.wait(timeout=3):
                        raise AssertionError("fixture did not release the in-flight callback")
                    return ""
                raise AssertionError(argv)

            def idle_worker():
                try:
                    autosleep._idle_callback("lock")
                except Exception as exc:  # make thread failures visible to unittest
                    errors.append(exc)

            def off_worker():
                try:
                    with autosleep.PolicyLock():
                        autosleep.write_policy("off")
                except Exception as exc:
                    errors.append(exc)
                finally:
                    off_finished.set()

            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(autosleep, "run", side_effect=fake_run):
                autosleep.write_policy("on")
                idle_thread = threading.Thread(target=idle_worker)
                idle_thread.start()
                self.assertTrue(lock_started.wait(timeout=2))
                off_thread = threading.Thread(target=off_worker)
                off_thread.start()
                self.assertFalse(off_finished.wait(timeout=0.05))
                release_lock.set()
                idle_thread.join(timeout=2)
                off_thread.join(timeout=2)
                self.assertFalse(idle_thread.is_alive())
                self.assertFalse(off_thread.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(autosleep.read_policy()["mode"], "off")
                self.assertEqual(autosleep.read_policy()["revision"], 2)

    def test_noctalia_callback_refuses_wrong_or_inactive_logind_session(self):
        with tempfile.TemporaryDirectory(prefix="autosleep-session-check-test-") as temp:
            config_home = Path(temp) / ".config"
            config_home.mkdir(mode=0o700)
            env = {
                "XDG_CONFIG_HOME": str(config_home),
                "THEME_PROFILE": "hyprland",
                "XDG_SESSION_TYPE": "wayland",
                "XDG_SESSION_ID": "9",
            }
            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
                autosleep, "run", return_value=f"User={os.getuid()}\nActive=no\nType=wayland\nClass=user\nLockedHint=no\n"
            ):
                autosleep.write_policy("on")
                with self.assertRaises(autosleep.AutosleepError):
                    autosleep._idle_callback("lock")



class CurrentRepairTests(unittest.TestCase):
    def session_output(self, **change):
        values = dict(User=str(os.getuid()), Active='yes', Type='x11', Class='user', LockedHint='no')
        values.update(change)
        return '\n'.join(f'{key}={value}' for key, value in values.items())

    def test_native_expected_types_and_no_unsupported_type(self):
        for kind in ('x11', 'wayland'):
            with self.subTest(kind=kind), mock.patch.dict(os.environ, {'XDG_SESSION_TYPE':kind,'XDG_SESSION_ID':'fixture'}, clear=True), mock.patch.object(autosleep, 'run', return_value=self.session_output(Type=kind)):
                self.assertEqual(autosleep._current_graphical_session(kind)[0], 'fixture')
        with mock.patch.dict(os.environ, {'XDG_SESSION_TYPE':'tty','XDG_SESSION_ID':'fixture'}, clear=True), mock.patch.object(autosleep, 'run') as native:
            with self.assertRaises(autosleep.AutosleepError): autosleep._current_graphical_session('tty')
            native.assert_not_called()

    def test_native_wrong_owner_type_class_active_and_missing_query_refuse(self):
        for output in [self.session_output(User='999999'), self.session_output(Type='wayland'),self.session_output(Class='greeter'), self.session_output(Active='no'), '', 'Type=x11']:
            with self.subTest(output=output), mock.patch.dict(os.environ, {'XDG_SESSION_TYPE':'x11','XDG_SESSION_ID':'fixture'}, clear=True), mock.patch.object(autosleep,'run',return_value=output):
                with self.assertRaises(autosleep.AutosleepError): autosleep._current_graphical_session('x11')

    def test_native_nonzero_with_valid_partial_stdout_is_not_accepted(self):
        import shutil
        result=subprocess.CompletedProcess(['fixture-loginctl'],1,stdout=self.session_output(),stderr='fixture logind query failed')
        with mock.patch.dict(os.environ,{'XDG_SESSION_TYPE':'x11','XDG_SESSION_ID':'fixture'},clear=True),mock.patch.object(shutil,'which',return_value='/AUDIT/loginctl'),mock.patch.object(autosleep.subprocess,'run',return_value=result):
            with self.assertRaises(autosleep.AutosleepError):autosleep._current_graphical_session('x11')

    def test_x11_daemon_complete_clock_lock_then_confirmed_blank_and_wake(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp)/'config';home.mkdir(mode=0o700)
            env={'XDG_CONFIG_HOME':str(home),'XDG_SESSION_TYPE':'x11','XDG_SESSION_ID':'fixture','XDG_CURRENT_DESKTOP':'XFCE'}
            calls=[]; state={'idle':0,'locked':False,'tick':0}
            def native(argv,check=True):
                calls.append(argv)
                if argv[:2]==['loginctl','show-session']: return self.session_output(LockedHint='yes' if state['locked'] else 'no')
                if argv==['xprintidle']: return str(state['idle'])
                if argv[:2]==['loginctl','lock-session']: state['locked']=True;return ''
                if argv[:2]==['xset','dpms']: return ''
                raise AssertionError(argv)
            def tick(delay):
                state['tick']+=1
                state['idle']={1:300000,2:305000,3:0}.get(state['tick'],0)
                if state['tick']==4: autosleep.write_policy('off')
            with mock.patch.dict(os.environ,env,clear=True),mock.patch.object(autosleep,'run',side_effect=native),mock.patch.object(autosleep.time,'sleep',side_effect=tick):
                autosleep.write_policy('on');self.assertEqual(autosleep._x11_idle_daemon(),0)
            lock=calls.index(['loginctl','lock-session','fixture']); blank=calls.index(['xset','dpms','force','off']);wake=calls.index(['xset','dpms','force','on'])
            self.assertLess(lock,blank);self.assertLess(blank,wake)
            self.assertFalse(any('suspend' in call for call in calls))

    def test_x11_daemon_query_failure_never_blanks(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp)/'config';home.mkdir(mode=0o700);calls=[]
            def native(argv,check=True):
                calls.append(argv)
                if argv[:2]==['loginctl','show-session']:return ''
                raise AssertionError(argv)
            with mock.patch.dict(os.environ,{'XDG_CONFIG_HOME':str(home),'XDG_SESSION_TYPE':'x11','XDG_SESSION_ID':'fixture','XDG_CURRENT_DESKTOP':'XFCE'},clear=True),mock.patch.object(autosleep,'run',side_effect=native):
                autosleep.write_policy('on')
                with self.assertRaises(autosleep.AutosleepError):autosleep._x11_idle_daemon()
            self.assertFalse(any(call[0]=='xset' for call in calls))

    def test_noctalia_600_and_644_preserve_mode_owner_custom_content(self):
        for mode in (0o600,0o644):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as temp:
                state=Path(temp)/'state';state.mkdir(mode=0o700); cfg=Path(temp)/'config';cfg.mkdir(mode=0o700)
                settings=state/'noctalia';settings.mkdir();path=settings/'settings.toml'
                path.write_text('[appearance]\ncustom = "preserve"\n[idle.behavior.suspend]\naction = "suspend"\nenabled = true\n');path.chmod(mode)
                with mock.patch.dict(os.environ,{'NOCTALIA_STATE_HOME':str(state),'XDG_CONFIG_HOME':str(cfg)},clear=True),mock.patch.object(autosleep,'run',return_value='inactive'):
                    result=autosleep.apply_noctalia('off')
                self.assertTrue(result['configuration_matches']);self.assertEqual(path.stat().st_mode & 0o777,mode);self.assertEqual(path.stat().st_uid,os.getuid());self.assertEqual(path.stat().st_gid,os.getgid())
                self.assertIn('custom = "preserve"',path.read_text());self.assertFalse(autosleep.tomlkit.parse(path.read_text())['idle']['behavior']['suspend']['enabled'])

    def test_noctalia_symlink_foreign_owner_missing_malformed_and_conflict_refuse(self):
        for scenario in ('link','foreign','missing','malformed','conflict'):
            with self.subTest(scenario=scenario),tempfile.TemporaryDirectory() as temp:
                state=Path(temp)/'state';state.mkdir(mode=0o700); cfg=Path(temp)/'config';cfg.mkdir(mode=0o700);settings=state/'noctalia';settings.mkdir();path=settings/'settings.toml';path.write_text('[appearance]\ncustom = "original"\n');path.chmod(0o644)
                calls=[];env={'NOCTALIA_STATE_HOME':str(state),'XDG_CONFIG_HOME':str(cfg)}
                if scenario=='link':
                    target=Path(temp)/'outside';target.write_text('sentinel');path.unlink();path.symlink_to(target)
                if scenario=='malformed':path.write_text('[invalid')
                real_toml=autosleep._toml_file
                def raced(*args,**kwargs):
                    result=real_toml(*args,**kwargs)
                    if scenario=='missing':path.unlink()
                    if scenario=='conflict':path.write_text('[appearance]\ncustom = "newer user change"\n')
                    return result
                with mock.patch.dict(os.environ,env,clear=True),mock.patch.object(autosleep,'run',side_effect=lambda argv,check=True:calls.append(argv)),mock.patch.object(autosleep,'_toml_file',side_effect=raced),mock.patch.object(autosleep,'_uid',return_value=os.getuid()+1 if scenario=='foreign' else os.getuid()):
                    with self.assertRaises(autosleep.AutosleepError):
                        autosleep.apply_noctalia('off')
                self.assertEqual(calls,[])
                if scenario=='link':self.assertEqual(target.read_text(),'sentinel')
                if scenario=='conflict':self.assertIn('newer user change',path.read_text())
                self.assertFalse(list(settings.glob('*.tmp.*')))

if __name__ == "__main__":
    unittest.main(verbosity=2)
