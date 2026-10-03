#!/usr/bin/env python3
"""Deterministic no-follow and parent-swap tests for pinned-rename.py."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import tempfile


def load_helper(path: pathlib.Path):
    specification = importlib.util.spec_from_file_location("pinned_rename", path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load helper: {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def main() -> None:
    if len(sys.argv) > 2:
        raise SystemExit("usage: backup-pinned-rename-test.py [PINNED_RENAME_HELPER]")
    sys.dont_write_bytecode = True
    helper_path = pathlib.Path(sys.argv[1]) if len(sys.argv) == 2 else pathlib.Path(__file__).resolve().parents[1]/"lib/pinned-rename.py"
    helper = load_helper(helper_path)
    with tempfile.TemporaryDirectory(prefix="backup-pinned-rename-test.") as scratch_text:
        scratch = pathlib.Path(scratch_text)
        repository = scratch / "repository"
        prepared = scratch / "prepared"
        outside = scratch / "outside"
        repository.mkdir()
        (repository / "tree").mkdir()
        prepared.mkdir()
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_text("outside data\n")
        root_identity = helper.object_identity(os.stat(repository, follow_symlinks=False))

        source = prepared / "snapshot"
        source.write_text("verified payload\n")
        destination = repository / "tree" / "snapshot"
        source_parent = helper.absolute_parent_identity(str(source))
        destination_parent = helper.parent_identity(
            str(destination), str(repository), root_identity
        )
        helper.pinned_rename(
            str(source),
            str(destination),
            helper.object_identity(os.stat(source, follow_symlinks=False)),
            source_parent,
            destination_parent,
            str(repository),
            root_identity,
        )
        assert destination.read_text() == "verified payload\n"
        assert not source.exists()
        print("Pinned rename publishes the expected object: PASS")

        # A leaf changed to a symlink immediately before rename must produce
        # EEXIST. RENAME_NOREPLACE leaves both the link and outside data alone.
        source2 = prepared / "snapshot-2"
        source2.write_text("must not escape\n")
        destination2 = repository / "tree" / "snapshot-2"
        source2_parent = helper.absolute_parent_identity(str(source2))
        destination2_parent = helper.parent_identity(
            str(destination2), str(repository), root_identity
        )
        real_rename = helper._renameat2
        injected = False

        def insert_leaf_symlink(source_fd, source_leaf, destination_fd, destination_leaf):
            nonlocal injected
            if not injected:
                os.symlink(str(sentinel), destination_leaf, dir_fd=destination_fd)
                injected = True
            return real_rename(source_fd, source_leaf, destination_fd, destination_leaf)

        helper._renameat2 = insert_leaf_symlink
        try:
            helper.pinned_rename(
                str(source2),
                str(destination2),
                helper.object_identity(os.stat(source2, follow_symlinks=False)),
                source2_parent,
                destination2_parent,
                str(repository),
                root_identity,
            )
            raise AssertionError("leaf symlink race was accepted")
        except FileExistsError:
            pass
        finally:
            helper._renameat2 = real_rename
        assert destination2.is_symlink()
        assert source2.read_text() == "must not escape\n"
        assert sentinel.read_text() == "outside data\n"
        print("Leaf symlink race fails without following or overwriting: PASS")

        # Swap an ancestor after its descriptor has been opened but before the
        # kernel rename. The operation must stay on the pinned directory, undo
        # its publication, and leave the outside target unchanged.
        source3 = prepared / "snapshot-3"
        source3.write_text("ancestor race payload\n")
        destination3 = repository / "tree" / "snapshot-3"
        source3_parent = helper.absolute_parent_identity(str(source3))
        destination3_parent = helper.parent_identity(
            str(destination3), str(repository), root_identity
        )
        real_tree = repository / "tree"
        held_tree = repository / "tree-held"
        injected = False

        def swap_ancestor_then_rename(source_fd, source_leaf, destination_fd, destination_leaf):
            nonlocal injected
            if not injected:
                os.rename(real_tree, held_tree)
                os.symlink(str(outside), real_tree)
                injected = True
            return real_rename(source_fd, source_leaf, destination_fd, destination_leaf)

        helper._renameat2 = swap_ancestor_then_rename
        try:
            helper.pinned_rename(
                str(source3),
                str(destination3),
                helper.object_identity(os.stat(source3, follow_symlinks=False)),
                source3_parent,
                destination3_parent,
                str(repository),
                root_identity,
            )
            raise AssertionError("ancestor symlink race was accepted")
        except RuntimeError as error:
            assert "parent changed" in str(error)
        finally:
            helper._renameat2 = real_rename
            if real_tree.is_symlink():
                real_tree.unlink()
            os.rename(held_tree, real_tree)
        assert source3.read_text() == "ancestor race payload\n"
        assert not (real_tree / "snapshot-3").exists()
        assert sentinel.read_text() == "outside data\n"
        print("Ancestor symlink race stays on pinned parent and rolls back: PASS")

        # A symlink already present in a parent path is rejected before rename.
        (repository / "tree-link").symlink_to(outside, target_is_directory=True)
        try:
            helper.parent_identity(
                str(repository / "tree-link" / "never-created"),
                str(repository),
                root_identity,
            )
            raise AssertionError("symlinked parent was accepted")
        except OSError:
            pass
        assert sentinel.read_text() == "outside data\n"
        print("Symlinked parent is rejected during handle-relative traversal: PASS")


if __name__ == "__main__":
    main()
