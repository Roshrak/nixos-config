#!/usr/bin/env python3
"""Per-user autosleep policy and desktop adapters for the Tonelico host."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    import tomlkit
except ImportError as exc:  # pragma: no cover - exercised by the packaged binary
    raise SystemExit("autosleep: packaged tomlkit dependency is unavailable") from exc


VERSION = 1
IDLE_SECONDS = 300
DISPLAY_OFF_SECONDS = 305
EXIT_USAGE = 2
EXIT_APPLY = 1


class AutosleepError(RuntimeError):
    pass


def _uid() -> int:
    return os.getuid()


def _safe_directory(
    path: Path, *, create: bool = False, private: bool = False, allow_missing: bool = False
) -> bool:
    path = path.expanduser()
    if not path.is_absolute():
        raise AutosleepError(f"state directory is not absolute: {path}")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        try:
            item = current.lstat()
        except FileNotFoundError:
            if not create:
                if allow_missing:
                    return False
                raise AutosleepError(f"required directory is missing: {current}")
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                pass
            item = current.lstat()
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISDIR(item.st_mode):
            raise AutosleepError(f"refusing non-directory or symlink path: {current}")
    item = path.stat()
    if item.st_uid != _uid():
        raise AutosleepError(f"directory is not owned by the current user: {path}")
    if private and stat.S_IMODE(item.st_mode) != 0o700:
        raise AutosleepError(f"private directory must have mode 0700: {path}")
    return True


def _config_home() -> Path:
    raw = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    path = Path(raw).expanduser()
    _safe_directory(path)
    return path


def _policy_dir(*, create: bool = False) -> Path:
    path = _config_home() / "autosleep"
    _safe_directory(path, create=create, private=True, allow_missing=not create)
    return path


def _check_private_file(path: Path, *, missing_ok: bool = True) -> os.stat_result | None:
    try:
        item = path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return None
        raise AutosleepError(f"required state file is missing: {path}")
    if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
        raise AutosleepError(f"refusing non-regular or symlink state file: {path}")
    if item.st_uid != _uid() or stat.S_IMODE(item.st_mode) != 0o600:
        raise AutosleepError(f"state file must be user-owned and mode 0600: {path}")
    return item


def _owned_regular_file(path: Path) -> os.stat_result | None:
    try:
        item = path.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode) or item.st_uid != _uid():
        raise AutosleepError(f"refusing non-user-owned, non-regular, or symlink file: {path}")
    return item


def _atomic_write(
    path: Path,
    data: bytes,
    *,
    mode: int = 0o600,
    private: bool = True,
    expected_hash: bytes | None = None,
) -> None:
    parent = path.parent
    _safe_directory(parent, create=True, private=private)
    old = _check_private_file(path) if private else _owned_regular_file(path)
    if old is not None and stat.S_IMODE(old.st_mode) != mode:
        raise AutosleepError(f"refusing to change unexpected state-file mode: {path}")
    temp = parent / f".{path.name}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(temp, flags, mode)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(fd)
        if old is not None:
            current = _check_private_file(path, missing_ok=False) if private else _owned_regular_file(path)
            if current is None:
                raise AutosleepError(f"state file disappeared during update: {path}")
            current_hash = hashlib.sha256(path.read_bytes()).digest() if expected_hash is not None else None
            if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                old.st_dev,
                old.st_ino,
                old.st_mtime_ns,
                old.st_size,
            ):
                raise AutosleepError(f"state changed concurrently; preserved the newer file: {path}")
            if expected_hash is not None and current_hash != expected_hash:
                raise AutosleepError(f"state changed concurrently; preserved the newer file: {path}")
            os.replace(temp, path)
        else:
            # Do not overwrite a file that appeared after the initial read.
            # A same-directory hard link provides atomic no-clobber creation.
            os.link(temp, path, follow_symlinks=False)
            temp.unlink()
        dir_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        os.close(fd)
        try:
            temp.unlink()
        except FileNotFoundError:
            pass


class PolicyLock:
    def __enter__(self) -> "PolicyLock":
        self.directory = _policy_dir(create=True)
        self.path = self.directory / "policy.lock"
        _check_private_file(self.path)
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.fd = os.open(self.path, flags, 0o600)
        os.fchmod(self.fd, 0o600)
        item = os.fstat(self.fd)
        if not stat.S_ISREG(item.st_mode) or item.st_uid != _uid() or stat.S_IMODE(item.st_mode) != 0o600:
            os.close(self.fd)
            raise AutosleepError("policy lock has unsafe type, owner, or mode")
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: object) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def _state_path(*, create: bool = False) -> Path:
    return _policy_dir(create=create) / "policy.json"


def read_policy() -> dict[str, Any]:
    path = _state_path(create=False)
    item = _check_private_file(path)
    if item is None:
        return {"version": VERSION, "mode": "off", "revision": 0, "updated_at": None}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AutosleepError(f"policy state is unreadable or corrupt: {path}") from exc
    if (
        not isinstance(data, dict)
        or data.get("version") != VERSION
        or data.get("mode") not in ("on", "off")
        or not isinstance(data.get("revision"), int)
        or data["revision"] < 0
    ):
        raise AutosleepError(f"policy state has an unsupported format: {path}")
    return data


def write_policy(mode: str) -> dict[str, Any]:
    prior = read_policy()
    revision = prior["revision"] + (prior["mode"] != mode)
    state = {
        "version": VERSION,
        "mode": mode,
        "revision": revision,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    _atomic_write(_state_path(create=True), (json.dumps(state, sort_keys=True) + "\n").encode())
    return state


def run(argv: list[str], *, check: bool = True) -> str:
    if not argv:
        raise AutosleepError("empty adapter command")
    executable = argv[0]
    if not os.path.isabs(executable):
        import shutil

        found = shutil.which(executable)
        if found is None:
            raise AutosleepError(f"required adapter executable is unavailable: {executable}")
        argv = [found, *argv[1:]]
    proc = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if check and proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        raise AutosleepError(f"{Path(argv[0]).name} failed: {detail[-1000:]}")
    return proc.stdout.strip()


def identify_backend() -> tuple[str, str, str]:
    profile = os.environ.get("THEME_PROFILE", "").strip().lower()
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    session_type = os.environ.get("XDG_SESSION_TYPE", "").lower()
    if profile in {"hyprland", "niri", "sway", "mango"}:
        return ("noctalia", profile, session_type or "wayland")
    if "gnome" in desktop:
        return ("gnome", "gnome", session_type)
    if "kde" in desktop or "plasma" in desktop or os.environ.get("KDE_FULL_SESSION") == "true":
        return ("plasma", "plasma", session_type or "wayland")
    if "xfce" in desktop and session_type == "x11":
        return ("xfce", "xfce", session_type)
    if "cinnamon" in desktop:
        return ("cinnamon", "cinnamon", session_type)
    if "mate" in desktop:
        return ("mate", "mate", session_type)
    if "lxqt" in desktop:
        return ("lxqt", "lxqt", session_type)
    if "awesome" in desktop:
        return ("awesome", "awesome", session_type)
    raise AutosleepError(
        "could not identify a supported graphical session from XDG_CURRENT_DESKTOP, "
        "XDG_SESSION_TYPE, and THEME_PROFILE"
    )


def _gsettings_get(schema: str, key: str) -> str:
    return run(["gsettings", "get", schema, key])


def _gsettings_set(schema: str, key: str, value: str) -> None:
    run(["gsettings", "set", schema, key, value])


def apply_gnome(mode: str) -> dict[str, Any]:
    delay = "uint32 300" if mode == "on" else "uint32 0"
    _gsettings_set("org.gnome.desktop.session", "idle-delay", delay)
    _gsettings_set("org.gnome.desktop.screensaver", "lock-enabled", "true")
    if mode == "on":
        _gsettings_set("org.gnome.desktop.screensaver", "lock-delay", "uint32 0")
    _gsettings_set("org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type", "'nothing'")
    _gsettings_set("org.gnome.settings-daemon.plugins.power", "sleep-inactive-battery-type", "'nothing'")
    state = {
        "mode": mode,
        "idle_delay": _gsettings_get("org.gnome.desktop.session", "idle-delay"),
        "lock_enabled": _gsettings_get("org.gnome.desktop.screensaver", "lock-enabled"),
        "lock_delay": _gsettings_get("org.gnome.desktop.screensaver", "lock-delay") if mode == "on" else None,
        "sleep_ac": _gsettings_get("org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type"),
        "sleep_battery": _gsettings_get("org.gnome.settings-daemon.plugins.power", "sleep-inactive-battery-type"),
        "lock": "native GNOME Shell; runtime lock and wake not exercised here",
        "inhibitors": "native session behavior; playback-inhibitor behavior requires runtime acceptance",
    }
    state["configuration_matches"] = (
        state["idle_delay"] == delay
        and state["lock_enabled"].lower() == "true"
        and (mode != "on" or state["lock_delay"] == "uint32 0")
        and state["sleep_ac"].strip("'") == "nothing"
        and state["sleep_battery"].strip("'") == "nothing"
    )
    state["runtime_verified"] = False
    state["verification"] = "configuration-only; lock/wake behavior requires session acceptance"
    return state


def _xfconf_set(channel: str, prop: str, kind: str, value: str) -> None:
    run(["xfconf-query", "--channel", channel, "--property", prop, "--create", "--type", kind, "--set", value])


def _xfconf_get(channel: str, prop: str) -> str:
    # xfconf-query reads a property when no write/list action is supplied; it
    # has no --get switch. Missing/uninitialized settings read as empty so
    # status can report a mismatch instead of collapsing to a tool error.
    return run(["xfconf-query", "--channel", channel, "--property", prop], check=False)


def _xfce_display_matches(output: str, mode: str) -> bool:
    saver = output.split("Screen Saver:", 1)[-1].split("DPMS", 1)[0]
    dpms = output.split("DPMS (Energy Star):", 1)[-1] if "DPMS (Energy Star):" in output else ""
    timeout = re.search(r"\btimeout:\s*(\d+)", saver)
    power = re.search(r"\bStandby:\s*(\d+)\s+Suspend:\s*(\d+)\s+Off:\s*(\d+)", dpms)
    if timeout is None:
        return False
    if mode == "on":
        return int(timeout.group(1)) == 0 and power is not None and tuple(map(int, power.groups())) == (0, 0, 0) and "DPMS is Enabled" in dpms
    return int(timeout.group(1)) == 0 and "DPMS is Disabled" in dpms


def apply_xfce(mode: str) -> dict[str, Any]:
    # One input-idle watcher owns this session. Keep the native screen-saver
    # idle trigger disabled so it cannot race the lock-confirmed DPMS step.
    _xfconf_set("xfce4-screensaver", "/saver/idle-activation/enabled", "bool", "false")
    _xfconf_set("xfce4-screensaver", "/saver/enabled", "bool", "true")
    _xfconf_set("xfce4-screensaver", "/lock/saver-activation/enabled", "bool", "true")
    _xfconf_set("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-ac", "int", "0")
    _xfconf_set("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-battery", "int", "0")
    # XFCE takes logind's handle-lid-switch inhibitor in this session, so the
    # logind Ignore setting alone does not control lid-close behavior. In the
    # installed XFCE power-manager enum, 0 is the explicit "Do nothing" action.
    _xfconf_set("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-ac", "uint", "0")
    _xfconf_set("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-battery", "uint", "0")
    if mode == "on":
        run(["xset", "+dpms"])
        run(["xset", "s", "off"])
        run(["xset", "dpms", "0", "0", "0"])
        run(["systemctl", "--user", "restart", "autosleep-idle-x11.service"])
    else:
        run(["xset", "s", "off"])
        run(["xset", "-dpms"])
        run(["xset", "dpms", "force", "on"])
        run(["systemctl", "--user", "stop", "autosleep-idle-x11.service"])
    idle_service_state = run(
        ["systemctl", "--user", "is-active", "autosleep-idle-x11.service"], check=False
    ).strip() or "unknown"
    state = {
        "mode": mode,
        "screensaver_idle": _xfconf_get("xfce4-screensaver", "/saver/idle-activation/enabled"),
        "screensaver_lock": _xfconf_get("xfce4-screensaver", "/lock/saver-activation/enabled"),
        "automatic_suspend_ac": _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-ac"),
        "automatic_suspend_battery": _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-battery"),
        "lid_action_ac": _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-ac"),
        "lid_action_battery": _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-battery"),
        "display": run(["xset", "-q"]),
        "idle_service_state": idle_service_state,
        "lock": "native XFCE screensaver; runtime lock and wake not exercised here",
        "inhibitors": "XFCE fullscreen-inhibit setting is preserved; media-inhibitor behavior requires runtime acceptance",
    }
    state["configuration_matches"] = (
        state["screensaver_idle"].strip().lower() == "false"
        and state["screensaver_lock"].strip().lower() == "true"
        and state["automatic_suspend_ac"].strip() == "0"
        and state["automatic_suspend_battery"].strip() == "0"
        and state["lid_action_ac"].strip() == "0"
        and state["lid_action_battery"].strip() == "0"
        and _xfce_display_matches(state["display"], mode)
        and ((mode == "on" and state["idle_service_state"] == "active")
             or (mode == "off" and state["idle_service_state"] in {"inactive", "failed", "unknown"}))
    )
    state["runtime_verified"] = False
    state["verification"] = "configuration-only; lock/wake behavior requires session acceptance"
    return state


def apply_plasma(mode: str) -> dict[str, Any]:
    enabled = "true" if mode == "on" else "false"
    run(["kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Autolock", enabled])
    run(["kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "RequirePassword", "true"])
    if mode == "on":
        run(["kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Timeout", "5"])
    # Plasma 6.6 has separate idle timeout keys and a distinct global critical
    # battery action. Disable idle timeouts in every profile while preserving
    # that critical action and the configured power button behavior.
    profiles = ("AC", "Battery", "LowBattery")
    for profile in profiles:
        def set_key(group: str, key: str, value: str) -> None:
            run(["kwriteconfig6", "--file", "powerdevilrc", "--group", profile, "--group", group, "--key", key, value])

        set_key("SuspendAndShutdown", "AutoSuspendIdleTimeoutSec", "0")
        set_key("SuspendAndShutdown", "LidAction", "0")
        set_key("Display", "DimDisplayWhenIdle", "false")
        set_key("Display", "TurnOffDisplayWhenIdle", enabled)
        set_key("Display", "TurnOffDisplayIdleTimeoutSec", str(DISPLAY_OFF_SECONDS if mode == "on" else 0))
        if mode == "on":
            set_key("Display", "TurnOffDisplayIdleTimeoutWhenLockedSec", "5")
            set_key("Display", "LockBeforeTurnOffDisplay", "true")
    run(["qdbus", "org.kde.Solid.PowerManagement", "/org/kde/Solid/PowerManagement", "org.kde.Solid.PowerManagement.reparseConfiguration"])

    def get_key(profile: str, group: str, key: str) -> str:
        return run(["kreadconfig6", "--file", "powerdevilrc", "--group", profile, "--group", group, "--key", key], check=False)

    state = {
        "mode": mode,
        "autolock": run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Autolock"], check=False),
        "require_password": run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "RequirePassword"], check=False),
        "lock_timeout_minutes": run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Timeout"], check=False),
        "auto_suspend_idle_seconds": {profile: get_key(profile, "SuspendAndShutdown", "AutoSuspendIdleTimeoutSec") for profile in profiles},
        "lid_actions": {profile: get_key(profile, "SuspendAndShutdown", "LidAction") for profile in profiles},
        "display_dim_enabled": {profile: get_key(profile, "Display", "DimDisplayWhenIdle") for profile in profiles},
        "display_off_enabled": {profile: get_key(profile, "Display", "TurnOffDisplayWhenIdle") for profile in profiles},
        "display_idle_timeout_seconds": {profile: get_key(profile, "Display", "TurnOffDisplayIdleTimeoutSec") for profile in profiles},
        "display_idle_when_locked_seconds": {profile: get_key(profile, "Display", "TurnOffDisplayIdleTimeoutWhenLockedSec") for profile in profiles},
        "lock_before_display_off": {profile: get_key(profile, "Display", "LockBeforeTurnOffDisplay") for profile in profiles},
        "lock": "native KScreenLocker; runtime lock and wake not exercised here",
        "inhibitors": "PowerDevil/KScreenLocker inhibition behavior requires runtime acceptance",
    }
    state["configuration_matches"] = (
        state["autolock"].lower() == enabled
        and state["require_password"].lower() == "true"
        and (mode != "on" or state["lock_timeout_minutes"] == "5")
        and all(value == "0" for value in state["auto_suspend_idle_seconds"].values())
        and all(value == "0" for value in state["lid_actions"].values())
        and all(value.lower() == "false" for value in state["display_dim_enabled"].values())
        and all(value.lower() == enabled for value in state["display_off_enabled"].values())
        and all(value == str(DISPLAY_OFF_SECONDS if mode == "on" else 0) for value in state["display_idle_timeout_seconds"].values())
        and (mode != "on" or all(value == "5" for value in state["display_idle_when_locked_seconds"].values()))
        and (mode != "on" or all(value.lower() == "true" for value in state["lock_before_display_off"].values()))
    )
    state["runtime_verified"] = False
    state["verification"] = "configuration-only; lock/wake behavior requires session acceptance"
    return state


def _toml_file(
    path: Path, *, create: bool = False
) -> tuple[Any, bytes | None, os.stat_result | None]:
    parent_exists = _safe_directory(path.parent, create=create, allow_missing=not create)
    if not parent_exists:
        return tomlkit.document(), None, None
    old = _owned_regular_file(path)
    if old is None:
        return tomlkit.document(), None, None
    before = path.read_bytes()
    try:
        return tomlkit.parse(before.decode("utf-8")), before, old
    except Exception as exc:
        raise AutosleepError(f"Noctalia settings file is invalid TOML: {path}") from exc


_MANAGED_NOCTALIA_BEHAVIOR_IDS = {"lock", "screen-off", "suspend"}
_MANAGED_NOCTALIA_ACTIONS = {
    "lock",
    "screen-off",
    "screen_off",
    "lock-and-suspend",
    "lock_and_suspend",
    "suspend",
}


def _noctalia_behavior_is_managed(name: str, entry: Any) -> bool:
    action = entry.get("action") if hasattr(entry, "get") else None
    return name in _MANAGED_NOCTALIA_BEHAVIOR_IDS or action in _MANAGED_NOCTALIA_ACTIONS


def _noctalia_settings_path(*, create: bool = False) -> Path:
    raw = os.environ.get("NOCTALIA_STATE_HOME")
    if not raw:
        profile = os.environ.get("THEME_PROFILE", "").lower()
        if profile not in {"hyprland", "niri", "sway", "mango"}:
            raise AutosleepError("Noctalia state home is unavailable for this compositor session")
        raw = str(Path.home() / ".local" / "state" / "theme-profiles" / profile)
    state_home = Path(raw).expanduser()
    _safe_directory(state_home, create=create, allow_missing=not create)
    return state_home / "noctalia" / "settings.toml"


def _hypridle_config_path() -> Path:
    return _policy_dir(create=True) / "hypridle.conf"


def _current_graphical_session(expected_type: str) -> tuple[str, dict[str, str]]:
    if expected_type not in {"x11", "wayland"}:
        raise AutosleepError("unsupported graphical session type")
    session_type = os.environ.get("XDG_SESSION_TYPE", "").strip().lower()
    session_id = os.environ.get("XDG_SESSION_ID", "").strip()
    if session_type != expected_type:
        raise AutosleepError(f"idle callback expected an {expected_type} graphical session")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", session_id):
        raise AutosleepError("idle callback has a missing or invalid XDG_SESSION_ID")
    output = run(
        [
            "loginctl",
            "show-session",
            session_id,
            "--property=User",
            "--property=Active",
            "--property=Type",
            "--property=Class",
            "--property=LockedHint",
            "--no-pager",
        ],
        check=True,
    )
    values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    if (
        values.get("User") != str(_uid())
        or values.get("Active") != "yes"
        or values.get("Type") != expected_type
        or values.get("Class") != "user"
    ):
        raise AutosleepError("idle callback logind session is absent, inactive, or owned by another session")
    return session_id, values


def _current_noctalia_session() -> tuple[str, dict[str, str]]:
    profile = os.environ.get("THEME_PROFILE", "").strip().lower()
    if profile not in {"hyprland", "niri", "sway", "mango"}:
        raise AutosleepError("idle callback is not running in a supported Noctalia Wayland session")
    return _current_graphical_session("wayland")


def _idle_callback(action: str) -> bool:
    """Run one Hypridle callback under the policy lock to cancel stale events."""
    if action not in {"lock", "lock-confirmed", "display-off"}:
        raise AutosleepError(f"invalid internal idle callback: {action}")
    with PolicyLock():
        policy = read_policy()
        if policy["mode"] != "on":
            return action != "lock-confirmed"
        session_id, session = _current_noctalia_session()
        if action == "lock":
            run(["loginctl", "lock-session", session_id])
            return True
        if session.get("LockedHint") != "yes":
            if action == "lock-confirmed":
                return False
            raise AutosleepError("refusing display power-off before logind confirms the session lock")
        if action == "display-off":
            run(["noctalia", "msg", "dpms-off"])
            return True
        return True


def _x11_idle_actions(idle_ms: int, locked: bool, display_is_off: bool) -> list[str]:
    """Pure virtual-clock decision used by the X11 controller and fixtures."""
    if idle_ms < IDLE_SECONDS * 1000:
        return ["display-on"] if display_is_off else []
    if not locked:
        return ["lock-request"]
    if idle_ms >= DISPLAY_OFF_SECONDS * 1000 and not display_is_off:
        return ["display-off"]
    return []


def _x11_idle_daemon() -> int:
    backend, desktop, session_type = identify_backend()
    if session_type != "x11" or backend not in {"xfce", "awesome"}:
        return 0

    locked_retry_at = 0.0
    display_retry_at = 0.0
    display_is_off = False
    while True:
        with PolicyLock():
            policy = read_policy()
            if policy["mode"] != "on":
                if display_is_off:
                    run(["xset", "dpms", "force", "on"])
                return 0

            session_id, session = _current_graphical_session("x11")
            idle_text = run(["xprintidle"])
            if not idle_text.isdecimal():
                raise AutosleepError(f"xprintidle returned an invalid idle duration: {idle_text!r}")
            idle_ms = int(idle_text)
            now = time.monotonic()
            locked = session.get("LockedHint") == "yes"
            actions = _x11_idle_actions(idle_ms, locked, display_is_off)

            if "lock-request" in actions:
                if now >= locked_retry_at:
                    try:
                        run(["loginctl", "lock-session", session_id])
                    except AutosleepError as exc:
                        print(f"autosleep: X11 lock request failed; display remains on: {exc}", file=sys.stderr)
                    locked_retry_at = now + 5.0
                    _, refreshed = _current_graphical_session("x11")
                    locked = refreshed.get("LockedHint") == "yes"
                actions = _x11_idle_actions(idle_ms, locked, display_is_off)

            for action in actions:
                if action == "display-on":
                    run(["xset", "dpms", "force", "on"])
                    display_is_off = False
                    display_retry_at = 0.0
                elif action == "display-off" and now >= display_retry_at:
                    try:
                        run(["xset", "dpms", "force", "off"])
                        display_is_off = True
                    except AutosleepError as exc:
                        print(f"autosleep: X11 display power-off failed after lock confirmation: {exc}", file=sys.stderr)
                        display_retry_at = now + 5.0

        time.sleep(1.0)


def render_hypridle_config(mode: str) -> bytes:
    if mode not in {"on", "off"}:
        raise AutosleepError(f"invalid autosleep mode for Hypridle: {mode}")
    lines = [
        "# Managed by autosleep. Edit the policy with `autosleep on|off`.",
        "general {",
        "    ignore_dbus_inhibit = true",
        "    ignore_systemd_inhibit = true",
        "    ignore_wayland_inhibit = true",
        "    inhibit_sleep = 0",
        "}",
    ]
    if mode == "on":
        lines.extend(
            [
                "",
                "listener {",
                f"    timeout = {IDLE_SECONDS}",
                "    on-timeout = /run/current-system/sw/bin/autosleep-lock-session",
                "    ignore_inhibit = true",
                "}",
                "",
                "listener {",
                f"    timeout = {DISPLAY_OFF_SECONDS}",
                "    on-timeout = /run/current-system/sw/bin/autosleep-display-off",
                "    on-resume = /run/current-system/sw/bin/autosleep-display-on",
                "    ignore_inhibit = true",
                "}",
            ]
        )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _noctalia_configuration_state(mode: str) -> dict[str, Any]:
    path = _noctalia_settings_path(create=False)
    doc, _, _ = _toml_file(path)
    behavior = doc.get("idle", {}).get("behavior", {})
    lock_cfg = behavior.get("lock", {})
    screen_cfg = behavior.get("screen-off", {})
    behavior_order = list(doc.get("idle", {}).get("behavior_order", []))
    behaviors_disabled = all(
        not bool(entry.get("enabled", False))
        for name, entry in behavior.items()
        if _noctalia_behavior_is_managed(name, entry)
    )
    unmanaged_enabled = sorted(
        name
        for name, entry in behavior.items()
        if hasattr(entry, "get")
        and bool(entry.get("enabled", False))
        and not _noctalia_behavior_is_managed(name, entry)
    )
    try:
        config_path = _policy_dir(create=False) / "hypridle.conf"
        idle_config_matches = config_path.read_bytes() == render_hypridle_config(mode)
    except (AutosleepError, OSError):
        idle_config_matches = False
    service_state = run(
        ["/run/current-system/sw/bin/systemctl", "--user", "is-active", "autosleep-idle.service"],
        check=False,
    ).strip() or "unknown"
    configuration_matches = (
        behaviors_disabled
        and not bool(lock_cfg.get("enabled", False))
        and lock_cfg.get("timeout") == IDLE_SECONDS
        and not bool(screen_cfg.get("enabled", False))
        and screen_cfg.get("timeout") == DISPLAY_OFF_SECONDS
        and idle_config_matches
        and not unmanaged_enabled
        and ((mode == "on" and service_state == "active")
             or (mode == "off" and service_state in {"inactive", "failed", "unknown"}))
    )
    return {
        "mode": mode,
        "lock_enabled": bool(lock_cfg.get("enabled", False)),
        "lock_timeout_seconds": lock_cfg.get("timeout"),
        "screen_off_enabled": bool(screen_cfg.get("enabled", False)),
        "screen_off_timeout_seconds": screen_cfg.get("timeout"),
        "behavior_order": behavior_order,
        "noctalia_idle_behaviors_disabled": behaviors_disabled,
        "unmanaged_enabled_idle_behaviors": unmanaged_enabled,
        "unmanaged_idle_behavior_warning": (
            "enabled user-defined Noctalia idle behaviors remain and may conflict with autosleep"
            if unmanaged_enabled
            else None
        ),
        "hypridle_configuration_matches": idle_config_matches,
        "idle_service_state": service_state,
        "automatic_suspend": "Noctalia behaviors disabled; Hypridle has no suspend listener",
        "lock": "session lock requested through logind; monitor power waits for LockedHint=yes",
        "inhibitors": "Hypridle listeners explicitly ignore D-Bus, systemd, and Wayland idle inhibitors",
        "configuration_matches": configuration_matches,
        "runtime_verified": False,
        "verification": "configuration plus service-state readback; physical lock, panel power, and wake remain unverified",
    }


def _toml_table(parent: Any, key: str) -> Any:
    value = parent.get(key)
    if value is None:
        value = tomlkit.table()
        parent[key] = value
    if not hasattr(value, "get"):
        raise AutosleepError(f"Noctalia settings key has incompatible type: {key}")
    return value


def apply_noctalia(mode: str) -> dict[str, Any]:
    path = _noctalia_settings_path(create=True)
    doc, before, old = _toml_file(path, create=True)
    idle = _toml_table(doc, "idle")
    behavior = _toml_table(idle, "behavior")
    lock = _toml_table(behavior, "lock")
    screen = _toml_table(behavior, "screen-off")
    lock["action"] = "lock"
    lock["enabled"] = False
    lock["timeout"] = IDLE_SECONDS
    screen["action"] = "screen_off"
    screen["enabled"] = False
    screen["timeout"] = DISPLAY_OFF_SECONDS
    # Hypridle owns every Noctalia-compositor idle action. Preserve user
    # behavior definitions and command text, but disable their automatic
    # triggers so no second timer can lock, blank, suspend, or power off.
    for name, entry in behavior.items():
        if hasattr(entry, "get") and _noctalia_behavior_is_managed(name, entry):
            entry["enabled"] = False
    if old is not None:
        current = _owned_regular_file(path)
        if current is None:
            raise AutosleepError("Noctalia settings disappeared during update")
        now = path.read_bytes()
        if (
            current.st_dev,
            current.st_ino,
            current.st_mtime_ns,
            current.st_size,
            hashlib.sha256(now).digest(),
        ) != (
            old.st_dev,
            old.st_ino,
            old.st_mtime_ns,
            old.st_size,
            hashlib.sha256(before or b"").digest(),
        ):
            raise AutosleepError("Noctalia settings changed concurrently; preserved the newer settings file")
    _atomic_write(
        path,
        tomlkit.dumps(doc).encode("utf-8"),
        mode=stat.S_IMODE(old.st_mode) if old else 0o600,
        private=False,
        expected_hash=hashlib.sha256(before).digest() if before is not None else None,
    )
    run(["noctalia", "msg", "config-reload"])
    idle_config = _hypridle_config_path()
    _atomic_write(idle_config, render_hypridle_config(mode))
    systemctl = "/run/current-system/sw/bin/systemctl"
    if mode == "on":
        run([systemctl, "--user", "restart", "autosleep-idle.service"])
        service_state = run([systemctl, "--user", "is-active", "autosleep-idle.service"], check=False)
        if service_state.strip() != "active":
            raise AutosleepError(
                "the Wayland idle service did not remain active; policy is saved, but this session is unapplied"
            )
    else:
        run(["noctalia", "msg", "dpms-on"])
        run([systemctl, "--user", "stop", "autosleep-idle.service"])
        service_state = run([systemctl, "--user", "is-active", "autosleep-idle.service"], check=False)
        if service_state.strip() not in {"inactive", "failed", "unknown"}:
            raise AutosleepError("the Wayland idle service is still active after autosleep off")
    return _noctalia_configuration_state(mode)


def apply(mode: str) -> dict[str, Any]:
    backend, desktop, session_type = identify_backend()
    if backend == "xfce":
        result = apply_xfce(mode)
    elif backend == "gnome":
        result = apply_gnome(mode)
    elif backend == "plasma":
        result = apply_plasma(mode)
    elif backend == "noctalia":
        result = apply_noctalia(mode)
    elif backend == "awesome" and session_type == "x11":
        result = apply_xfce(mode)
        result["backend"] = "x11-screensaver"
    else:
        raise AutosleepError(
            f"detected {desktop} ({session_type}), but no validated native autosleep adapter is available; "
            "the requested preference is saved and this session remains unapplied"
        )
    result.update({"backend": backend, "desktop": desktop, "session_type": session_type})
    return result


def status() -> dict[str, Any]:
    policy = read_policy()
    try:
        backend, desktop, session_type = identify_backend()
        if backend == "gnome":
            idle = _gsettings_get("org.gnome.desktop.session", "idle-delay")
            lock = _gsettings_get("org.gnome.desktop.screensaver", "lock-enabled")
            lock_delay = _gsettings_get("org.gnome.desktop.screensaver", "lock-delay")
            ac = _gsettings_get("org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type")
            battery = _gsettings_get("org.gnome.settings-daemon.plugins.power", "sleep-inactive-battery-type")
            applied = {
                "backend": backend,
                "desktop": desktop,
                "session_type": session_type,
                "idle_delay": idle,
                "lock_enabled": lock,
                "lock_delay": lock_delay,
                "sleep_ac": ac,
                "sleep_battery": battery,
                "matches_mode": idle == ("uint32 300" if policy["mode"] == "on" else "uint32 0"),
                "configuration_matches": idle == ("uint32 300" if policy["mode"] == "on" else "uint32 0")
                and lock.strip().lower() == "true"
                and (policy["mode"] != "on" or lock_delay == "uint32 0")
                and ac.strip("'") == "nothing"
                and battery.strip("'") == "nothing",
                "runtime_verified": False,
                "verification": "configuration-only; lock/wake behavior requires session acceptance",
                "inhibitors": "native GNOME behavior; playback-inhibitor behavior requires runtime acceptance",
            }
        elif backend == "xfce" or (backend == "awesome" and session_type == "x11"):
            idle = _xfconf_get("xfce4-screensaver", "/saver/idle-activation/enabled")
            lock = _xfconf_get("xfce4-screensaver", "/lock/saver-activation/enabled")
            ac = _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-ac")
            battery = _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/inactivity-on-battery")
            lid_ac = _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-ac")
            lid_battery = _xfconf_get("xfce4-power-manager", "/xfce4-power-manager/lid-action-on-battery")
            dpms = run(["xset", "-q"])
            idle_service_state = run(
                ["systemctl", "--user", "is-active", "autosleep-idle-x11.service"], check=False
            ).strip() or "unknown"
            configuration_matches = (
                idle.strip().lower() == "false"
                and lock.strip().lower() == "true"
                and ac.strip() == "0"
                and battery.strip() == "0"
                and lid_ac.strip() == "0"
                and lid_battery.strip() == "0"
                and _xfce_display_matches(dpms, policy["mode"])
                and ((policy["mode"] == "on" and idle_service_state == "active")
                     or (policy["mode"] == "off" and idle_service_state in {"inactive", "failed", "unknown"}))
            )
            applied = {
                "backend": "xfce" if backend == "xfce" else "x11-screensaver",
                "desktop": desktop,
                "session_type": session_type,
                "screensaver_idle": idle,
                "screensaver_lock": lock,
                "automatic_suspend_ac": ac,
                "automatic_suspend_battery": battery,
                "lid_action_ac": lid_ac,
                "lid_action_battery": lid_battery,
                "display": dpms,
                "idle_service_state": idle_service_state,
                "matches_mode": configuration_matches,
                "configuration_matches": configuration_matches,
                "runtime_verified": False,
                "verification": "configuration-only; lock/wake behavior requires session acceptance",
                "inhibitors": "runtime idle-source behavior requires acceptance",
            }
        elif backend == "plasma":
            auto = run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Autolock"], check=False)
            require_password = run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "RequirePassword"], check=False)
            timeout = run(["kreadconfig6", "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Timeout"], check=False)
            profiles = ("AC", "Battery", "LowBattery")

            def get_profile(profile: str, group: str, key: str) -> str:
                return run(["kreadconfig6", "--file", "powerdevilrc", "--group", profile, "--group", group, "--key", key], check=False)

            suspend_values = {p: get_profile(p, "SuspendAndShutdown", "AutoSuspendIdleTimeoutSec") for p in profiles}
            lid_values = {p: get_profile(p, "SuspendAndShutdown", "LidAction") for p in profiles}
            dim_values = {p: get_profile(p, "Display", "DimDisplayWhenIdle") for p in profiles}
            display_enabled = {p: get_profile(p, "Display", "TurnOffDisplayWhenIdle") for p in profiles}
            display_timeout = {p: get_profile(p, "Display", "TurnOffDisplayIdleTimeoutSec") for p in profiles}
            locked_timeout = {p: get_profile(p, "Display", "TurnOffDisplayIdleTimeoutWhenLockedSec") for p in profiles}
            lock_before_off = {p: get_profile(p, "Display", "LockBeforeTurnOffDisplay") for p in profiles}
            expected_enabled = "true" if policy["mode"] == "on" else "false"
            configuration_matches = (
                auto.lower() == expected_enabled
                and require_password.lower() == "true"
                and (policy["mode"] != "on" or timeout == "5")
                and all(value == "0" for value in suspend_values.values())
                and all(value == "0" for value in lid_values.values())
                and all(value.lower() == "false" for value in dim_values.values())
                and all(value.lower() == expected_enabled for value in display_enabled.values())
                and all(value == str(DISPLAY_OFF_SECONDS if policy["mode"] == "on" else 0) for value in display_timeout.values())
                and (policy["mode"] != "on" or all(value == "5" for value in locked_timeout.values()))
                and (policy["mode"] != "on" or all(value.lower() == "true" for value in lock_before_off.values()))
            )
            applied = {
                "backend": backend,
                "desktop": desktop,
                "session_type": session_type,
                "autolock": auto,
                "require_password": require_password,
                "lock_timeout_minutes": timeout,
                "suspend_idle_times": suspend_values,
                "lid_actions": lid_values,
                "display_dim_enabled": dim_values,
                "display_off_enabled": display_enabled,
                "display_idle_timeout_seconds": display_timeout,
                "display_idle_when_locked_seconds": locked_timeout,
                "lock_before_display_off": lock_before_off,
                "matches_mode": configuration_matches,
                "configuration_matches": configuration_matches,
                "runtime_verified": False,
                "verification": "configuration-only; lock/wake behavior requires session acceptance",
                "critical_battery_action": "global PowerDevil setting is outside the keys changed by autosleep",
                "inhibitors": "PowerDevil/KScreenLocker inhibition behavior requires runtime acceptance",
            }
        elif backend == "noctalia":
            applied = _noctalia_configuration_state(policy["mode"])
            applied.update({"backend": backend, "desktop": desktop, "session_type": session_type})
            applied["matches_mode"] = applied["configuration_matches"]
        else:
            raise AutosleepError(f"{desktop} has no validated status adapter")
        error = None
    except AutosleepError as exc:
        applied = {"backend": "unavailable", "effective": "unknown"}
        error = str(exc)
    return {
        "persisted_mode": policy["mode"],
        "revision": policy["revision"],
        "timeout_seconds": IDLE_SECONDS,
        "display_off_delay_seconds": DISPLAY_OFF_SECONDS,
        "automatic_system_suspend": "configured off by NixOS logind policy; active effective state must be checked after boot",
        "session": applied,
        "runtime_verified": applied.get("runtime_verified", False),
        "verification": applied.get("verification", "unverified"),
        "error": error,
    }


def main(args: list[str]) -> int:
    if args not in (
        ["on"],
        ["off"],
        ["status"],
        ["apply"],
        ["__idle-lock"],
        ["__idle-lock-confirmed"],
        ["__idle-display-off"],
        ["__x11-idle-daemon"],
    ):
        print("Usage: autosleep on|off|status", file=sys.stderr)
        return EXIT_USAGE
    command = args[0]
    try:
        if command == "status":
            report = status()
            print(json.dumps(report, indent=2, sort_keys=True))
            return 0 if report.get("error") is None and report["session"].get("configuration_matches") else EXIT_APPLY
        if command == "__x11-idle-daemon":
            return _x11_idle_daemon()
        if command in {"__idle-lock", "__idle-lock-confirmed", "__idle-display-off"}:
            action = {
                "__idle-lock": "lock",
                "__idle-lock-confirmed": "lock-confirmed",
                "__idle-display-off": "display-off",
            }[command]
            result = _idle_callback(action)
            return 0 if result else EXIT_APPLY
        with PolicyLock():
            policy = read_policy()
            mode = policy["mode"] if command == "apply" else command
            if command in {"on", "off"}:
                policy = write_policy(mode)
            applied = apply(mode)
        print(json.dumps({"persisted_mode": policy["mode"], "revision": policy["revision"], "session": applied}, indent=2, sort_keys=True))
        return 0 if applied.get("configuration_matches") else EXIT_APPLY
    except AutosleepError as exc:
        print(f"autosleep: {exc}", file=sys.stderr)
        return EXIT_APPLY
    except OSError as exc:
        print(f"autosleep: operating-system error: {exc}", file=sys.stderr)
        return EXIT_APPLY


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
