#!/usr/bin/env python3
"""Run the actual source-selection helper against private disposable state."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

COMMON = Path(__file__).resolve().parents[1] / 'lib/common.sh'

class SourceRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='source-routing.')
        self.root = Path(self.temp.name)
        (self.root/'state').mkdir(mode=0o700)
        self.pointer = self.root/'state/nixos-source.path'
    def tearDown(self): self.temp.cleanup()
    def check(self, content=None, mode=0o600, override=None):
        if content is not None:
            self.pointer.write_text(content); self.pointer.chmod(mode)
        env = dict(os.environ, BABY_STEP_DIR=str(self.root), COMMON=str(COMMON))
        env.pop('NIXOS_DIR', None)
        if override is not None: env['NIXOS_DIR'] = override
        r = subprocess.run(['bash','-c', '. "$COMMON"; printf "%s|%s" "$NIXOS_SOURCE_POLICY_INVALID" "$NIXOS_DIR"'], env=env, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout
    def test_default(self): self.assertEqual(self.check(), '0|/etc/nixos')
    def test_valid_pointer(self): self.assertEqual(self.check('/etc/nixos/gen129-recovery\n'), '0|/etc/nixos/gen129-recovery')
    def test_explicit_override(self): self.assertEqual(self.check('/bad\n', override='/fixture/source'), '0|/fixture/source')
    def test_multiline_and_unterminated_tail(self):
        for value in ('/etc/nixos\n/bad', '/etc/nixos\n/bad\n', 'relative\n', '/etc/nixos\r\n', '/etc/nixos'):
            with self.subTest(value=value): self.assertEqual(self.check(value), '1|')
    def test_publicly_writable_pointer(self): self.assertEqual(self.check('/etc/nixos\n', 0o644), '1|')
    def test_link_pointer(self):
        target=self.root/'target';target.write_text('/etc/nixos\n');target.chmod(0o600)
        self.pointer.symlink_to(target)
        self.assertEqual(self.check(), '1|')
    def test_path_reference(self):
        text=COMMON.read_text()
        self.assertIn('FLAKE_TARGET="path:$NIXOS_DIR#$FLAKE_ATTR"', text)

if __name__ == '__main__': unittest.main()
