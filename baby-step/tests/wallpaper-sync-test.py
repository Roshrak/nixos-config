#!/usr/bin/env python3
"""No network: wallpaper transfer arguments and failure behavior."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class WallpaperTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='baby-wallpaper.'); self.root=Path(self.tmp.name)
        bins=self.root/'bin'; bins.mkdir()
        (bins/'rclone').write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1]=='listremotes': print('gdrive:')
elif sys.argv[1] in ('size','copy'): sys.exit(int(os.environ.get('FIXTURE_RCLONE_EXIT','0')))
else: sys.exit(99)
'''); (bins/'rclone').chmod(0o755)
        self.local=self.root/'wallpapers'
        self.env=dict(os.environ,PATH=str(bins)+':'+os.environ['PATH'],BABY_STEP_DIR=str(self.root/'state-root'),
                      BABY_STEP_WALLPAPER_DIR=str(self.local),FIXTURE_CALLS=str(self.root/'calls'),NO_COLOR='1')

    def tearDown(self): self.tmp.cleanup()

    def run_sync(self,*args,**env):
        r=subprocess.run(['bash',str(ROOT/'sync-wallpapers.sh'),*args],env=dict(self.env,**env),
                         text=True,capture_output=True,timeout=15)
        calls=[json.loads(x) for x in (self.root/'calls').read_text().splitlines()]
        return r,calls

    def test_upload_uses_non_deleting_copy(self):
        self.local.mkdir(); (self.local/'keep.jpg').write_text('user data')
        r,calls=self.run_sync('upload')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(any(c[0]=='copy' for c in calls)); self.assertFalse(any(c[0]=='sync' for c in calls))
        self.assertEqual((self.local/'keep.jpg').read_text(),'user data')

    def test_missing_upload_source_is_preserved_as_missing(self):
        r,calls=self.run_sync('upload')
        self.assertNotEqual(r.returncode,0); self.assertFalse(self.local.exists())
        self.assertFalse(any(c[0]=='copy' for c in calls))

    def test_download_preview_does_not_create_directory(self):
        r,calls=self.run_sync('download','--check-only')
        self.assertEqual(r.returncode,0,r.stderr); self.assertFalse(self.local.exists())
        self.assertTrue(any(c[0]=='copy' and '--dry-run' in c for c in calls))

    def test_remote_status_failure_is_visible_and_nonzero(self):
        r,_=self.run_sync('status',FIXTURE_RCLONE_EXIT='52')
        self.assertNotEqual(r.returncode,0); self.assertIn('EXIT 52',r.stdout)
        self.assertNotIn('STATUS QUERY COMPLETED',r.stdout)

    def test_transfer_failure_never_reports_completion(self):
        self.local.mkdir(); r,_=self.run_sync('upload',FIXTURE_RCLONE_EXIT='9')
        self.assertNotEqual(r.returncode,0); self.assertNotIn('COPY COMPLETED',r.stdout)


if __name__=='__main__': unittest.main(verbosity=2)
