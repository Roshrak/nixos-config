#!/usr/bin/env python3
"""Validate the complete staged Git tree without displaying secret values."""

import argparse
import re
import subprocess
import sys
from pathlib import PurePosixPath


def allowed_path(path):
    if any(ord(char) < 32 or ord(char) == 127 for char in path):
        return False
    parts = PurePosixPath(path).parts
    if not parts or path.startswith("/") or ".." in parts:
        return False
    if path in {"README.md", ".gitignore"}:
        return True
    if path == "dotfiles/.hermes/agy_bridge.py":
        return True
    return path.startswith((
        "nixos/", "baby-step/", "scripts/", "docs/", "dotfiles/.config/",
        "dotfiles/.local/bin/", "dotfiles/.local/share/applications/",
        "dotfiles/.local/share/desktop-look-toggle/",
    ))


def forbidden_path(path):
    parts = PurePosixPath(path).parts
    name = parts[-1]
    if any(part in {".git", ".ssh", "secrets", "credentials"} for part in parts):
        return True
    if name in {"id_rsa", "id_ed25519", "id_ecdsa", ".netrc", "auth.json", "credentials"}:
        return True
    if name == ".env" or name.startswith((".env.", "credentials.")):
        return True
    if name.endswith((".key", ".pem", ".p12", ".pfx")) or ".giant-backup-" in name:
        return True
    if path.startswith(("baby-step/logs/", "baby-step/state/", "baby-step/backups/", "baby-step/full-audit-")):
        return True
    if path == "dotfiles/.config/fcitx5/conf/cached_layouts":
        return True
    if path.startswith("dotfiles/.config/"):
        if name in {".noctalia-cache.json", ".setup-complete"} or ".catalog" in parts:
            return True
        if ("noctalia-state" in parts or "noctalia" in parts) and "clipboard" in parts:
            return True
    return False


TOKEN = re.compile(
    rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|"
    rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|"
    rb"tskey-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}|"
    rb"-----BEGIN (?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY-----)"
)
LITERAL = re.compile(
    rb"\b(?:access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|password|passwd)"
    rb"[\"']?\s*(?:=|:)\s*[\"']([^\"'$\r\n]{8,})[\"']", re.I
)


def secret_line(data):
    for number, line in enumerate(data.splitlines(), 1):
        if TOKEN.search(line):
            return number, "token/private-key pattern"
        for match in LITERAL.finditer(line):
            value = match[1].lower()
            placeholder = value.startswith((
                b"fixture-", b"test-", b"dummy-", b"example-", b"your_", b"your-", b"<",
            )) or value in {b"changeme", b"placeholder", b"redacted"}
            if not placeholder:
                return number, "literal credential assignment"
    return None


def git(repo, *args):
    return subprocess.check_output(["git", "-C", repo, *args], stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    try:
        records = git(args.repo, "ls-files", "--stage", "-z").split(b"\0")
        failures = []
        count = 0
        for record in records:
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, blob, stage = metadata.split()
            path = raw_path.decode("utf-8", "surrogateescape")
            count += 1
            if stage != b"0" or mode not in {b"100644", b"100755", b"120000"}:
                failures.append((path, "unmerged or unsupported index entry"))
                continue
            if not allowed_path(path) or forbidden_path(path):
                failures.append((path, "unapproved/private/generated path"))
                continue
            data = git(args.repo, "cat-file", "blob", blob.decode("ascii"))
            secret = secret_line(data)
            if secret:
                failures.append((path, f"line {secret[0]}: {secret[1]}"))
        for path, reason in failures:
            print(f"REFUSED {path!r}: {reason}; content not displayed", file=sys.stderr)
        if failures:
            return 1
        print(f"Publication path and content checks passed for {count} staged files.")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("Publication scan failed; no secret values were displayed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
