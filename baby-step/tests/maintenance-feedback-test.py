#!/usr/bin/env python3
"""Fixture checks for truthful progress, private logs and runtime identity."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FeedbackTests(unittest.TestCase):
    def run_shell(self, body, extra=None):
        with tempfile.TemporaryDirectory(prefix="baby-feedback.") as scratch:
            env = dict(os.environ, BABY_STEP_DIR=scratch, NO_COLOR="1", BABY_STEP_PROGRESS_INTERVAL="1")
            env.update(extra or {})
            return subprocess.run(["bash", "-c", '. "$1"; ' + body, "fixture", str(ROOT/"lib/common.sh")],
                                  env=env, text=True, capture_output=True, timeout=15)

    def test_unique_private_logs_preserve_first(self):
        result = self.run_shell('start_log test; first=$LOG_FILE; printf sentinel >> "$first"; '
                                'start_log test; test "$first" != "$LOG_FILE" && '
                                'grep sentinel "$first" && test "$(stat -c %a "$LOG_FILE")" = 600')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_symlink_lock_does_not_truncate_user_data(self):
        result=self.run_shell('ensure_baby_dirs; target="$BABY_STEP_DIR/sentinel"; printf preserve > "$target"; '
                              'ln -s "$target" "$STATE_DIR/maintenance.lock"; '
                              '(acquire_maintenance_lock); status=$?; test "$status" != 0 && test "$(cat "$target")" = preserve')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_lock_reuses_existing_content_without_truncating(self):
        result=self.run_shell('ensure_baby_dirs; printf existing > "$STATE_DIR/maintenance.lock"; '
                              'acquire_maintenance_lock; test "$(cat "$STATE_DIR/maintenance.lock")" = existing')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_symlink_log_directory_is_preserved_and_refused(self):
        result=self.run_shell('mkdir "$BABY_STEP_DIR/elsewhere"; ln -s "$BABY_STEP_DIR/elsewhere" "$LOG_DIR"; '
                              'ensure_baby_dirs; test "$?" != 0')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_command_failure_propagates_without_caller_pipefail(self):
        result = self.run_shell('start_log test; run_logged failure bash -c "printf failed-output; exit 17"')
        self.assertEqual(result.returncode, 17)
        self.assertIn("EXIT 17", result.stdout)
        self.assertIn("failed-output", result.stdout)

    def test_logging_failure_is_not_success(self):
        result = self.run_shell('start_log test; tee() { cat >/dev/null; return 44; }; run_logged logger true')
        self.assertNotEqual(result.returncode, 0)

    def test_silent_command_has_heartbeat(self):
        result = self.run_shell('start_log test; run_logged sleeping sleep 1.3')
        self.assertEqual(result.returncode, 0)
        self.assertIn("WAIT", result.stdout)
        self.assertIn("EXIT 0", result.stdout)

    def test_fast_command_does_not_wait_for_heartbeat_sleep(self):
        started=time.monotonic()
        result=self.run_shell('start_log test; run_logged fast true', {"BABY_STEP_PROGRESS_INTERVAL":"10"})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(time.monotonic()-started,2)

    def test_progress_has_label_time_and_plain_log(self):
        result = self.run_shell('start_log test; show_step 2 4 "Validate candidate"; show_warning "Example limitation"; '
                                'cat "$LOG_FILE"', {"BABY_STEP_COLOR": "always"})
        self.assertEqual(result.returncode, 0)
        self.assertIn("[02/04]", result.stdout)
        self.assertIn("Example limitation", result.stdout)
        self.assertIn("(0s)", result.stdout)
        self.assertNotIn("\x1b", result.stdout)  # NO_COLOR takes precedence.

    def test_synthetic_credentials_redacted(self):
        token = "gh" + "p_" + "A"*36
        result = self.run_shell('start_log test; run_logged redaction printf "%s\\n" "$FIXTURE_TOKEN" '
                                '"https://fixture-user:fixture-password@example.invalid/path"; cat "$LOG_FILE"',
                                {"FIXTURE_TOKEN": token})
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(token, result.stdout)
        self.assertNotIn("fixture-password", result.stdout)
        self.assertIn("REDACTED", result.stdout)

    def test_runtime_generation_differs_from_staged_profile(self):
        result = self.run_shell(r'''
readlink() { case "$2" in
 /run/current-system|/nix/var/nix/profiles/system-128-link) printf '/nix/store/live-128\n';;
 /nix/var/nix/profiles/system-129-link) printf '/nix/store/staged-129\n';;
 *) return 1;; esac; }
nixos-rebuild() { printf '[{"generation":129,"current":true},{"generation":128,"current":false}]'; }
test "$(current_generation)" = 128
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_generation_query_is_not_accepted(self):
        result=self.run_shell(r'''
readlink() { printf '/nix/store/same\n'; }
nixos-rebuild() { printf '[{"generation":129,"current":true}]'; return 7; }
current_generation
''')
        self.assertNotEqual(result.returncode,0)

    def test_extra_arguments_fail_before_work(self):
        for name in ("check-system.sh", "rebuild-system.sh", "update-system.sh", "backup-config.sh", "update-and-push.sh"):
            result = subprocess.run(["bash", str(ROOT/name), "--help", "--unexpected"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
