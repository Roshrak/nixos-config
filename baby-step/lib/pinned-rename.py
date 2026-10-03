#!/usr/bin/env python3
"""No-follow, directory-handle-relative rename for backup transactions."""

from __future__ import annotations

import argparse
import ctypes
import os
import stat
import sys
from typing import NoReturn

DIRECTORY_FLAGS = (
    getattr(os, "O_PATH", os.O_RDONLY)
    | os.O_DIRECTORY
    | os.O_NOFOLLOW
    | getattr(os, "O_CLOEXEC", 0)
)
RENAME_NOREPLACE = 1


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def check_absolute(path: str) -> list[str]:
    if not path.startswith("/") or os.path.normpath(path) != path:
        fail(f"path is not normalized and absolute: {path!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in path):
        fail("path contains a control character")
    components = path.split("/")[1:]
    if any(component in ("", ".", "..") for component in components):
        fail(f"path has an unsafe component: {path!r}")
    return components


def object_identity(metadata: os.stat_result) -> str:
    return f"{metadata.st_dev}:{metadata.st_ino}"


def open_absolute_directory(path: str) -> int:
    components = check_absolute(path)
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in components:
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            fail(f"not a directory: {path}")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_repository(root: str, expected_identity: str) -> int:
    descriptor = open_absolute_directory(root)
    if object_identity(os.fstat(descriptor)) != expected_identity:
        os.close(descriptor)
        fail("repository root identity changed")
    return descriptor


def open_relative_parent(root_descriptor: int, relative_path: str) -> tuple[int, str]:
    components = relative_path.split("/")
    if not components or any(component in ("", ".", "..") for component in components):
        fail(f"unsafe repository-relative path: {relative_path!r}")
    descriptor = os.dup(root_descriptor)
    try:
        for component in components[:-1]:
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor, components[-1]
    except BaseException:
        os.close(descriptor)
        raise


def open_parent(path: str, root: str, root_descriptor: int) -> tuple[int, str]:
    check_absolute(path)
    root_prefix = root.rstrip("/") + "/"
    if path.startswith(root_prefix):
        relative = path[len(root_prefix) :]
        return open_relative_parent(root_descriptor, relative)
    parent = os.path.dirname(path)
    leaf = os.path.basename(path)
    if not leaf or leaf in (".", ".."):
        fail(f"path has no safe leaf: {path!r}")
    return open_absolute_directory(parent), leaf


def open_absolute_parent(path: str) -> tuple[int, str]:
    check_absolute(path)
    leaf = os.path.basename(path)
    if not leaf or leaf in (".", ".."):
        fail(f"path has no safe leaf: {path!r}")
    return open_absolute_directory(os.path.dirname(path)), leaf


def parent_identity(path: str, root: str, expected_root: str) -> str:
    root_descriptor = open_repository(root, expected_root)
    try:
        descriptor, _leaf = open_parent(path, root, root_descriptor)
        try:
            return object_identity(os.fstat(descriptor))
        finally:
            os.close(descriptor)
    finally:
        os.close(root_descriptor)


def absolute_parent_identity(path: str) -> str:
    descriptor, _leaf = open_absolute_parent(path)
    try:
        return object_identity(os.fstat(descriptor))
    finally:
        os.close(descriptor)


def stat_leaf(descriptor: int, leaf: str) -> os.stat_result:
    metadata = os.stat(leaf, dir_fd=descriptor, follow_symlinks=False)
    if stat.S_ISLNK(metadata.st_mode):
        fail(f"refusing a symlink leaf: {leaf}")
    if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
        fail(f"refusing a non-file/non-directory leaf: {leaf}")
    return metadata


def _renameat2(source_fd: int, source_leaf: str, destination_fd: int, destination_leaf: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        operation = libc.renameat2
    except AttributeError:
        fail("libc renameat2 is unavailable; refusing an unsafe fallback")
    operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    operation.restype = ctypes.c_int
    result = operation(
        source_fd,
        os.fsencode(source_leaf),
        destination_fd,
        os.fsencode(destination_leaf),
        RENAME_NOREPLACE,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), destination_leaf)


def _path_parent_still_matches(
    path: str,
    root: str,
    root_identity: str,
    expected_parent_identity: str,
) -> bool:
    try:
        root_fd = open_repository(root, root_identity)
        try:
            parent_fd, _leaf = open_parent(path, root, root_fd)
            try:
                return object_identity(os.fstat(parent_fd)) == expected_parent_identity
            finally:
                os.close(parent_fd)
        finally:
            os.close(root_fd)
    except (OSError, RuntimeError):
        return False


def pinned_rename(
    source: str,
    destination: str,
    expected_source_identity: str,
    source_parent_identity: str,
    destination_parent_identity: str,
    root: str,
    root_identity: str,
) -> None:
    root_fd = open_repository(root, root_identity)
    source_fd = destination_fd = -1
    try:
        source_fd, source_leaf = open_parent(source, root, root_fd)
        destination_fd, destination_leaf = open_parent(destination, root, root_fd)
        if object_identity(os.fstat(source_fd)) != source_parent_identity:
            fail("source parent identity changed")
        if object_identity(os.fstat(destination_fd)) != destination_parent_identity:
            fail("destination parent identity changed")
        source_metadata = stat_leaf(source_fd, source_leaf)
        if object_identity(source_metadata) != expected_source_identity:
            fail("source object identity changed before rename")

        # RENAME_NOREPLACE moves the leaf itself. It never follows a raced
        # destination symlink and cannot overwrite a concurrently created leaf.
        _renameat2(source_fd, source_leaf, destination_fd, destination_leaf)
        moved_back = False
        try:
            moved_metadata = stat_leaf(destination_fd, destination_leaf)
            if object_identity(moved_metadata) != expected_source_identity:
                fail("moved object identity changed during rename")
            if stat.S_IFMT(moved_metadata.st_mode) != stat.S_IFMT(source_metadata.st_mode):
                fail("moved object type changed during rename")
            if not _path_parent_still_matches(
                source, root, root_identity, source_parent_identity
            ) or not _path_parent_still_matches(
                destination, root, root_identity, destination_parent_identity
            ):
                fail("a path parent changed while the rename was in flight")
        except BaseException:
            try:
                _renameat2(destination_fd, destination_leaf, source_fd, source_leaf)
                moved_back = True
            except OSError:
                pass
            if not moved_back:
                print(
                    f"pinned-rename: object remains recoverable at {destination}",
                    file=sys.stderr,
                )
            raise
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)
        os.close(root_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    root_parser = subparsers.add_parser("root-identity")
    root_parser.add_argument("root")
    parent_parser = subparsers.add_parser("parent-identity")
    parent_parser.add_argument("--root", required=True)
    parent_parser.add_argument("--root-identity", required=True)
    parent_parser.add_argument("--path", required=True)
    absolute_parser = subparsers.add_parser("absolute-parent-identity")
    absolute_parser.add_argument("--path", required=True)
    rename_parser = subparsers.add_parser("rename")
    rename_parser.add_argument("--root", required=True)
    rename_parser.add_argument("--root-identity", required=True)
    rename_parser.add_argument("--source", required=True)
    rename_parser.add_argument("--destination", required=True)
    rename_parser.add_argument("--source-identity", required=True)
    rename_parser.add_argument("--source-parent-identity", required=True)
    rename_parser.add_argument("--destination-parent-identity", required=True)
    args = parser.parse_args()
    try:
        if args.command == "root-identity":
            descriptor = open_absolute_directory(args.root)
            try:
                print(object_identity(os.fstat(descriptor)))
            finally:
                os.close(descriptor)
        elif args.command == "parent-identity":
            print(parent_identity(args.path, args.root, args.root_identity))
        elif args.command == "absolute-parent-identity":
            print(absolute_parent_identity(args.path))
        else:
            pinned_rename(
                args.source,
                args.destination,
                args.source_identity,
                args.source_parent_identity,
                args.destination_parent_identity,
                args.root,
                args.root_identity,
            )
            print(f"renamed {args.source} -> {args.destination}")
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"pinned-rename: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
