#!/usr/bin/env python3
"""Launch one Minecraft window in the current Niri session and verify /spawn.

No hardcoded display/socket. Input requires a fresh join event, an unlocked
session, and read-back proof that the unique Minecraft window owns focus.
Global uinput still has a focus-change race; do not change focus while it types.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

INSTANCE_NAME = "Fabulously Optimized"
SERVER_ADDR = "alt.crazy-fools.co.uk:25565"


def say(state: str, message: str) -> None:
    print(f"  [{state}] {message}", flush=True)


class LogCursor:
    """Read only fresh records; handle a missing, rotated or truncated log."""
    def __init__(self, path: Path):
        self.path = path
        self.identity = None
        self.offset = 0
        self.pending = b""
        try:
            info = path.stat()
            self.identity = (info.st_dev, info.st_ino)
            self.offset = info.st_size
        except FileNotFoundError:
            pass

    def read(self) -> list[str]:
        try:
            with self.path.open("rb") as handle:
                info = os.fstat(handle.fileno())
                identity = (info.st_dev, info.st_ino)
                if identity != self.identity or info.st_size < self.offset:
                    self.offset = 0
                    self.pending = b""
                self.identity = identity
                handle.seek(self.offset)
                data = handle.read()
                self.offset = handle.tell()
        except FileNotFoundError:
            return []
        records = (self.pending + data).split(b"\n")
        self.pending = records.pop()
        return [re.sub(r"§[0-9a-fk-or]", "", line.decode("utf-8", "replace")) for line in records]


class NiriSession:
    def __init__(self, env: dict[str, str] | None = None):
        self.env = dict(os.environ if env is None else env)

    def command(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        try:
            result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"{args[0]} unavailable or timed out") from error
        if result.returncode != 0:
            raise RuntimeError(f"{args[0]} returned exit {result.returncode}")
        return result

    def windows(self) -> list[dict]:
        result = self.command(["niri", "msg", "-j", "windows"])
        try:
            data = json.loads(result.stdout)
        except ValueError as error:
            raise RuntimeError("Niri returned invalid window data") from error
        if not isinstance(data, list) or not all(isinstance(window, dict) for window in data):
            raise RuntimeError("Niri window data has an unsupported shape")
        return data

    def unlocked(self) -> None:
        session = self.env.get("XDG_SESSION_ID", "")
        if not session:
            raise RuntimeError("Current logind session identity is unavailable; input was not sent")
        result = self.command(["loginctl", "show-session", session, "-p", "LockedHint", "--value"])
        if result.stdout.strip() != "no":
            raise RuntimeError("Session is locked or lock state is unknown; input was not sent")

    def preflight(self, uinput: Path, needs_input: bool) -> None:
        if "niri" not in self.env.get("XDG_CURRENT_DESKTOP", "").lower():
            raise RuntimeError("This helper supports the active Niri session; the current desktop is different")
        socket = self.env.get("NIRI_SOCKET", "")
        try:
            info = Path(socket).stat()
        except OSError as error:
            raise RuntimeError("The current NIRI_SOCKET is unavailable; no alternate session was selected") from error
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError("NIRI_SOCKET is not an owned session socket")
        for command in ("niri", "prismlauncher", "loginctl"):
            if shutil.which(command, path=self.env.get("PATH")) is None:
                raise RuntimeError(f"Missing required command: {command}")
        if needs_input and (not uinput.is_file() or not os.access(uinput, os.X_OK)):
            raise RuntimeError("The uinput_type helper is missing or not executable")
        self.windows()
        self.unlocked()

    def minecraft(self) -> dict | None:
        matches = []
        for window in self.windows():
            app = str(window.get("app_id") or "").lower()
            title = str(window.get("title") or "").lower()
            if re.search(r"(^|[._-])minecraft([._\s-]|$)", app) or (
                app in {"java", "sun-awt-x11-xframepeer"} and title.startswith("minecraft")
            ):
                matches.append(window)
        if len(matches) > 1:
            raise RuntimeError("Multiple Minecraft windows found; target is ambiguous")
        return matches[0] if matches else None

    def assert_target(self, window_id: int) -> None:
        self.unlocked()
        current = self.minecraft()
        if current is None or current.get("id") != window_id or current.get("is_focused") is not True:
            raise RuntimeError("Minecraft no longer owns focus; further input was stopped")

    def focus(self) -> int:
        window = self.minecraft()
        if window is None or not isinstance(window.get("id"), int):
            raise RuntimeError("No unique Minecraft window is available")
        window_id = window["id"]
        self.command(["niri", "msg", "action", "focus-window", "--id", str(window_id)])
        self.assert_target(window_id)
        say("VERIFIED", f"Minecraft window {window_id} owns focus; session is unlocked")
        return window_id


def wait_for_join(cursor: LogCursor, server: str, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    host = server.split(":", 1)[0].lower()
    connected = False
    next_note = time.monotonic() + 5
    while time.monotonic() < deadline:
        for line in cursor.read():
            lower = line.lower()
            if "connecting to " + host in lower:
                connected = True
                say("OBSERVED", "Fresh log records connection to the requested server")
            # A different player's generic 'joined the game' is not our login.
            if connected and ("joined crazy-fools.co.uk" in lower or (
                "[chat]" in lower and "welcome" in lower and "crazy-fools" in lower
            )):
                return True
        if time.monotonic() >= next_note:
            say("WAIT", f"Waiting for a fresh join event; {max(0, int(deadline - time.monotonic()))}s remain")
            next_note = time.monotonic() + 5
        time.sleep(0.25)
    return False


def send_spawn(session: NiriSession, window_id: int, uinput: Path) -> None:
    for token in ("slash", "type:spawn", "enter"):
        session.assert_target(window_id)
        session.command([str(uinput), token])
        time.sleep(0.3)
    say("SENT", "/spawn input completed; server response is still unverified")


def wait_for_spawn(cursor: LogCursor, timeout: float = 15) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for line in cursor.read():
            if "[chat]" in line.lower() and re.search(
                r"\b(teleported|teleporting|warped|welcome to spawn)\b", line, re.I
            ):
                return True
        time.sleep(0.25)
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="Inspect prerequisites without launching, focusing or typing")
    parser.add_argument("--no-spawn", action="store_true", help="Launch/wait for join without sending keyboard input")
    parser.add_argument("--instance", default=INSTANCE_NAME)
    parser.add_argument("--server", default=SERVER_ADDR, help="Connection target; fresh join verification currently recognizes Crazy-Fools welcome messages")
    parser.add_argument("--log", type=Path, help="Override the selected instance's latest.log")
    parser.add_argument("--uinput", type=Path, default=Path.home()/".local/bin/uinput_type")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args(argv)
    if not 1 <= args.timeout <= 600:
        parser.error("--timeout must be 1..600 seconds")
    if args.log is None:
        args.log = Path.home()/".local/share/PrismLauncher/instances"/args.instance/"minecraft/logs/latest.log"
    print("\nMinecraft /spawn helper\n" + "=" * 56, flush=True)
    session = NiriSession()
    try:
        say("CHECK", "Current-session IPC, commands, lock state and input helper")
        session.preflight(args.uinput, not args.no_spawn)
        if args.check_only:
            say("CHECK ONLY", "Prerequisites available. No game was launched, focused or typed into.")
            return 0
        cursor = LogCursor(args.log)
        if session.minecraft() is None:
            proc = subprocess.Popen(["prismlauncher", "--launch", args.instance, "--server", args.server],
                                    env=session.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            say("STARTED", f"Prism process {proc.pid}; game/server success is not yet established")
        else:
            say("REUSE", "Minecraft window already exists; a second instance was not launched")
        say("WAIT", f"Fresh server join evidence in {args.log} (limit {args.timeout}s)")
        if not wait_for_join(cursor, args.server, args.timeout):
            raise RuntimeError("Join was not confirmed before timeout; no keyboard input was sent")
        say("VERIFIED", "Fresh requested-server connection and welcome event observed")
        if args.no_spawn:
            say("DONE", "Join evidence verified; keyboard input was disabled")
            return 0
        window_id = session.focus()
        # Ignore all old spawn/teleport messages, including those read during join.
        response_cursor = LogCursor(args.log)
        send_spawn(session, window_id, args.uinput)
        if not wait_for_spawn(response_cursor):
            raise RuntimeError("Input was sent but teleport acknowledgement is unconfirmed; no automatic retry was made")
        say("VERIFIED", "Fresh server teleport acknowledgement observed; destination appearance requires visual acceptance")
        return 0
    except (OSError, RuntimeError) as error:
        say("FAILED", str(error))
        return 1
    except KeyboardInterrupt:
        say("STOPPED", "Interrupted; completion was not claimed")
        return 130


if __name__ == "__main__":
    sys.exit(main())
