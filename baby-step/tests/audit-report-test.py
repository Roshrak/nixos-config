#!/usr/bin/env python3
"""Disposable audit-report publication, redaction and timeout checks."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class AuditReportTests(unittest.TestCase):
    def run_report(self, root, *args, env=None):
        return subprocess.run(['bash',str(ROOT/'generate-system-audit.sh'),*args],
                              env=dict(os.environ,NO_COLOR='1',**(env or {})),capture_output=True,text=True,timeout=20)

    def test_help_does_not_generate_report(self):
        with tempfile.TemporaryDirectory(prefix='baby-report.') as tmp:
            report=Path(tmp)/'report.md'
            r=self.run_report(tmp,'--help','--output',str(report))
            self.assertEqual(r.returncode,0,r.stderr); self.assertFalse(report.exists())

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory(prefix='baby-report.') as tmp:
            report=Path(tmp)/'report.md'; report.write_text('original evidence')
            r=self.run_report(tmp,'--quick','--output',str(report))
            self.assertNotEqual(r.returncode,0); self.assertEqual(report.read_text(),'original evidence')

    def test_symlink_output_refused(self):
        with tempfile.TemporaryDirectory(prefix='baby-report.') as tmp:
            root=Path(tmp); target=root/'target'; target.write_text('protected'); report=root/'report.md'; report.symlink_to(target)
            r=self.run_report(tmp,'--quick','--output',str(report))
            self.assertNotEqual(r.returncode,0); self.assertEqual(target.read_text(),'protected')

    def test_quick_report_is_private_redacted_and_has_real_capture_status(self):
        with tempfile.TemporaryDirectory(prefix='baby-report.') as tmp:
            root=Path(tmp); bins=root/'bin'; bins.mkdir(); report=root/'report.md'
            token='gh'+'p_'+'A'*36
            (bins/'hostname').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$FIXTURE_TOKEN"\n'); (bins/'hostname').chmod(0o755)
            (bins/'systemctl').write_text('#!/usr/bin/env bash\nprintf "fixture systemctl query denied\\n" >&2\nexit 5\n'); (bins/'systemctl').chmod(0o755)
            r=self.run_report(tmp,'--quick','--output',str(report),env={'PATH':str(bins)+':'+os.environ['PATH'],'FIXTURE_TOKEN':token})
            self.assertEqual(r.returncode,0,r.stderr)
            text=report.read_text(); self.assertNotIn(token,text); self.assertIn('[REDACTED]',text)
            self.assertIn('[command exit status: 5]',text); self.assertIn('2 command failures/timeouts',r.stdout)
            self.assertEqual(report.stat().st_mode & 0o777,0o600)
            self.assertEqual(list(root.glob('.system-audit.*')),[])

    def test_slow_capture_is_bounded_and_recorded(self):
        with tempfile.TemporaryDirectory(prefix='baby-report.') as tmp:
            root=Path(tmp); bins=root/'bin'; bins.mkdir(); report=root/'report.md'
            (bins/'hostname').write_text('#!/usr/bin/env bash\nsleep 2\n'); (bins/'hostname').chmod(0o755)
            r=self.run_report(tmp,'--quick','--output',str(report),env={'PATH':str(bins)+':'+os.environ['PATH'],'BABY_STEP_AUDIT_TIMEOUT':'1'})
            self.assertEqual(r.returncode,0,r.stderr); self.assertIn('[command exit status: 124]',report.read_text())


if __name__=='__main__': unittest.main(verbosity=2)
