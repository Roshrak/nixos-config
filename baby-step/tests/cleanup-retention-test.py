#!/usr/bin/env python3
import sys,os,time,importlib.util,unittest,tempfile,datetime as dt,fcntl,errno,json,hashlib
from pathlib import Path
from unittest import mock
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
REPO=Path(os.environ.get('BACKUP_REPO',str(Path.home()/'nixos-config')))
SCRIPT=Path(os.environ.get('CLEAN_SYSTEM_SCRIPT',str(REPO/'dotfiles/.hermes/scripts/clean-system.py')))
s=importlib.util.spec_from_file_location('cleaner_candidate',SCRIPT);m=importlib.util.module_from_spec(s);sys.modules[s.name]=m;s.loader.exec_module(m)
_fixtures=tempfile.TemporaryDirectory(prefix='cleanup-retention-test.');fixture=Path(_fixtures.name)
class Tests(unittest.TestCase):
 def setUp(self):self.t=tempfile.TemporaryDirectory(dir=fixture);self.p=Path(self.t.name);self.cut=time.time()-30*m.DAY_SECONDS
 def tearDown(self):self.t.cleanup()
 def old(self,p,data='old'):
  p.parent.mkdir(parents=True,exist_ok=True);p.write_text(data);old=time.time()-45*m.DAY_SECONDS;os.utime(p,(old,old));return p
 def trash(self):
  root=self.p/'Trash';(root/'files').mkdir(parents=True);(root/'info').mkdir();(root/'files/old').write_text('trash');date=(dt.datetime.now().astimezone()-dt.timedelta(days=45)).isoformat();(root/'info/old.trashinfo').write_text('[Trash Info]\nDeletionDate='+date+'\n');return root
 def test_static_ancestor_symlink(self):
  outside=self.p/'outside';sent=self.old(outside/'thumbnails/old');home=self.p/'home';home.mkdir();(home/'.cache').symlink_to(outside);r=m.clean_old_cache_files('fixture',home/'.cache/thumbnails',self.cut,False);self.assertTrue(sent.exists());self.assertTrue(r.skipped or r.errors)
 def test_dynamic_ancestor_swap(self):
  root=self.p/'cache';sent=self.old(root/'sub/old');outside=self.p/'outside';outside.mkdir();(outside/'old').write_text('outside')
  orig=m._walk_files
  def walk(fd,errors):
   for parent,name,st in orig(fd,errors):
    if name=='old' and not (root/'sub').is_symlink():(root/'sub').rename(root/'held');(root/'sub').symlink_to(outside)
    yield parent,name,st
  with mock.patch.object(m,'_walk_files',walk):m.clean_old_cache_files('fixture',root,self.cut,False)
  self.assertEqual((outside/'old').read_text(),'outside');self.assertTrue((root/'sub').is_symlink())
 def test_new_inode_preserved(self):
  root=self.p/'cache';sent=self.old(root/'old');orig=m._walk_files
  def walk(fd,errors):
   for parent,name,st in orig(fd,errors):
    if name=='old':sent.rename(root/'original');sent.write_text('fresh')
    yield parent,name,st
  with mock.patch.object(m,'_walk_files',walk):r=m.clean_old_cache_files('fixture',root,self.cut,False)
  self.assertEqual(sent.read_text(),'fresh');self.assertTrue(r.errors)
 def test_refreshed_inode_preserved(self):
  root=self.p/'cache';sent=self.old(root/'old');orig=m.quarantine
  def q(fd,name,selected,cutoff=None):sent.write_text('fresh on same inode');return orig(fd,name,selected,cutoff)
  with mock.patch.object(m,'quarantine',q):r=m.clean_old_cache_files('fixture',root,self.cut,False)
  self.assertEqual(sent.read_text(),'fresh on same inode');self.assertTrue(r.errors)
 def test_swap_during_rename_restored(self):
  root=self.p/'cache';sent=self.old(root/'old');orig=m.rename_noreplace;done=False
  def rename(a,n,b,d):
   nonlocal done
   if n=='old' and not done:done=True;sent.rename(root/'original');sent.write_text('fresh')
   return orig(a,n,b,d)
  with mock.patch.object(m,'rename_noreplace',rename):r=m.clean_old_cache_files('fixture',root,self.cut,False)
  self.assertEqual(sent.read_text(),'fresh');self.assertTrue(r.errors);self.assertFalse(list(root.glob('.hermes-clean-quarantine-*')))
 def test_restore_conflict_preserved_no_overwrite(self):
  root=self.p/'cache';sent=self.old(root/'old');orig=m.rename_noreplace;done=False
  def rename(a,n,b,d):
   nonlocal done
   if n=='old' and not done:
    done=True;sent.rename(root/'original');sent.write_text('substitution');v=orig(a,n,b,d);sent.write_text('later writer');return v
   return orig(a,n,b,d)
  with mock.patch.object(m,'rename_noreplace',rename):r=m.clean_old_cache_files('fixture',root,self.cut,False)
  self.assertEqual(sent.read_text(),'later writer');qs=list(root.glob('.hermes-clean-quarantine-*'));self.assertEqual(len(qs),1);self.assertEqual((qs[0]/'item').read_text(),'substitution');self.assertTrue(r.errors)
 def test_trash_replacement_preserves_pair(self):
  root=self.trash();orig=m.quarantine
  def q(fd,name,selected,cutoff=None):
   if name=='old':(root/'files/old').rename(root/'files/original');(root/'files/old').write_text('new trash data')
   return orig(fd,name,selected,cutoff)
  with mock.patch.object(m,'quarantine',q):r=m.clean_expired_trash(root,self.cut,False)
  self.assertEqual((root/'files/old').read_text(),'new trash data');self.assertTrue((root/'info/old.trashinfo').exists());self.assertTrue(r.errors)
 def test_trash_metadata_symlink_preserves_pair(self):
  root=self.trash();(root/'info/old.trashinfo').unlink();outside=self.p/'outside';outside.write_text('protected');(root/'info/old.trashinfo').symlink_to(outside);r=m.clean_expired_trash(root,self.cut,False);self.assertTrue((root/'files/old').exists());self.assertEqual(outside.read_text(),'protected');self.assertTrue(r.errors)
 def test_trash_directory_symlink_does_not_follow(self):
  root=self.trash();(root/'files/old').unlink();outside=self.p/'outside';outside.mkdir();(outside/'private').write_text('protected');(root/'files/old').symlink_to(outside);r=m.clean_expired_trash(root,self.cut,False);self.assertEqual((outside/'private').read_text(),'protected');self.assertEqual(r.removed,1)
 def test_trash_directory_and_stale_metadata(self):
  root=self.trash();(root/'files/old').unlink();(root/'files/old').mkdir();(root/'files/old/content').write_text('trash');r=m.clean_expired_trash(root,self.cut,False);self.assertEqual(r.removed,1);self.assertFalse((root/'files/old').exists())
  root=self.p/'Trash';(root/'info/stale.trashinfo').write_text('[Trash Info]\nDeletionDate=2000-01-01T01:01:01\n');r=m.clean_expired_trash(root,self.cut,False);self.assertEqual(r.removed,1)
 def test_rename_failure_preserves_pair(self):
  root=self.trash();orig=m.rename_noreplace
  def rename(a,n,b,d):
   if n=='old':raise PermissionError(errno.EACCES,'injected refusal')
   return orig(a,n,b,d)
  with mock.patch.object(m,'rename_noreplace',rename):r=m.clean_expired_trash(root,self.cut,False)
  self.assertTrue((root/'files/old').exists());self.assertTrue((root/'info/old.trashinfo').exists());self.assertTrue(r.errors)
 def test_fifo_trash_metadata_is_nonblocking_and_preserved(self):
  root=self.trash();info=root/'info/old.trashinfo';info.unlink();os.mkfifo(info);r=m.clean_expired_trash(root,self.cut,False);self.assertTrue(info.exists());self.assertTrue((root/'files/old').exists());self.assertTrue(r.errors)
 def test_partial_recursive_removal_never_claims_intact_pair(self):
  root=self.trash();payload=root/'files/old';payload.unlink();payload.mkdir();(payload/'first').write_text('delete');(payload/'second').write_text('preserve')
  def partially_remove(path,*,dir_fd):
   child=os.open(path,os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=dir_fd)
   try:os.unlink('first',dir_fd=child)
   finally:os.close(child)
   raise PermissionError(errno.EACCES,'injected after first child deletion')
  with mock.patch.object(m.shutil,'rmtree',partially_remove):
   # Keep the same capability assertion as the real descriptor-safe rmtree.
   m.shutil.rmtree.avoids_symlink_attacks=True
   r=m.clean_expired_trash(root,self.cut,False)
  self.assertFalse((payload/'first').exists());self.assertTrue((payload/'second').exists());self.assertTrue((root/'info/old.trashinfo').exists());self.assertEqual(r.removed_bytes,0);self.assertEqual(r.partial_removals,1);self.assertTrue(any('Possibly partial Trash deletion' in e and 'unknown' in e for e in r.errors));self.assertFalse(any('before any removal' in e for e in r.errors))
 def test_metadata_delete_failure_reports_partial_payload(self):
  root=self.trash();orig=m._remove_quarantined
  def remove(fd,selected):
   if os.readlink('/proc/self/fd/'+str(fd)).startswith(str(root/'info')):raise PermissionError(errno.EACCES,'injected metadata deletion failure')
   return orig(fd,selected)
  with mock.patch.object(m,'_remove_quarantined',remove):r=m.clean_expired_trash(root,self.cut,False)
  self.assertFalse((root/'files/old').exists());self.assertTrue((root/'info/old.trashinfo').exists());self.assertEqual(r.removed,0);self.assertEqual(r.removed_bytes,len('trash'));self.assertTrue(any('Partial Trash cleanup' in e for e in r.errors))
 def test_quarantine_finish_failure_reports_completed_delete(self):
  root=self.trash();orig=m.finish_quarantine
  def finish(parent,fd,name):
   if os.readlink('/proc/self/fd/'+str(parent))==str(root/'files'):raise PermissionError(errno.EACCES,'injected final directory removal failure')
   return orig(parent,fd,name)
  with mock.patch.object(m,'finish_quarantine',finish):r=m.clean_expired_trash(root,self.cut,False)
  self.assertFalse((root/'files/old').exists());self.assertTrue((root/'info/old.trashinfo').exists());self.assertEqual(r.removed_bytes,len('trash'));self.assertTrue(any('Partial Trash cleanup' in e for e in r.errors));self.assertEqual(len(list((root/'files').glob('.hermes-clean-quarantine-*'))),1)
 def test_dryrun_has_no_lock_or_new_files(self):
  home=self.p/'home';home.mkdir();sent=self.old(home/'.cache/thumbnails/old');before={str(p.relative_to(home)) for p in home.rglob('*')};m.run_cleanup(home,home/'.local/share',home/'.cache',True);self.assertEqual(before,{str(p.relative_to(home)) for p in home.rglob('*')});self.assertTrue(sent.exists())
 def test_cooperative_lock_busy(self):
  home=self.p/'home';home.mkdir();sent=self.old(home/'.cache/thumbnails/old');p=home/'.hermes-clean-system.lock';fd=os.open(p,os.O_CREAT|os.O_RDWR,0o600)
  try:
   fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);code,r,_,_=m.run_cleanup(home,home/'.local/share',home/'.cache',False);self.assertEqual(code,75);self.assertTrue(sent.exists());self.assertTrue(r[0].errors)
  finally:os.close(fd)
 def test_hardlink_is_preserved(self):
  root=self.p/'cache';sent=self.old(root/'old');os.link(sent,self.p/'outside');r=m.clean_old_cache_files('fixture',root,self.cut,False);self.assertTrue(sent.exists());self.assertTrue(r.errors)


cleaner=m
class CleanupFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hermes-clean-fixture-")
        self.home = Path(self.temp.name)
        self.data = self.home / ".local" / "share"
        self.cache = self.home / ".cache"

    def tearDown(self):
        self.temp.cleanup()

    def write_trash_item(self, name, deleted_days_ago, content):
        trash_files = self.data / "Trash" / "files"
        trash_info = self.data / "Trash" / "info"
        trash_files.mkdir(parents=True, exist_ok=True)
        trash_info.mkdir(parents=True, exist_ok=True)
        (trash_files / name).write_text(content)
        deleted = dt.datetime.now().astimezone() - dt.timedelta(days=deleted_days_ago)
        (trash_info / f"{name}.trashinfo").write_text(
            "[Trash Info]\nPath=/home/test/" + name + "\nDeletionDate="
            + deleted.isoformat(timespec="seconds") + "\n"
        )

    def test_trash_dry_run_preserves_then_expires_only_old_entry(self):
        self.write_trash_item("old.txt", 45, "old")
        self.write_trash_item("recent.txt", 2, "recent")
        root = self.data / "Trash"
        cutoff = time.time() - cleaner.RETENTION_DAYS * cleaner.DAY_SECONDS

        preview = cleaner.clean_expired_trash(root, cutoff, dry_run=True)
        self.assertEqual(preview.eligible, 1)
        self.assertTrue((root / "files" / "old.txt").exists())

        applied = cleaner.clean_expired_trash(root, cutoff, dry_run=False)
        self.assertEqual(applied.removed, 1)
        self.assertFalse((root / "files" / "old.txt").exists())
        self.assertFalse((root / "info" / "old.txt.trashinfo").exists())
        self.assertEqual((root / "files" / "recent.txt").read_text(), "recent")

    def test_cache_cleanup_keeps_recent_files_and_symlink_targets(self):
        root = self.cache / "thumbnails"
        root.mkdir(parents=True)
        old_file = root / "old.cache"
        recent_file = root / "recent.cache"
        old_file.write_text("old-cache")
        recent_file.write_text("recent-cache")
        old_time = time.time() - 45 * cleaner.DAY_SECONDS
        os.utime(old_file, (old_time, old_time))

        outside = self.home / "outside.txt"
        outside.write_text("preserve-me")
        (root / "outside-link").symlink_to(outside)
        outside_dir = self.home / "outside-dir"
        outside_dir.mkdir()
        (outside_dir / "keep.txt").write_text("still-here")
        (root / "outside-dir-link").symlink_to(outside_dir, target_is_directory=True)

        cutoff = time.time() - cleaner.RETENTION_DAYS * cleaner.DAY_SECONDS
        preview = cleaner.clean_old_cache_files("fixture cache", root, cutoff, dry_run=True)
        self.assertEqual(preview.eligible, 1)
        self.assertTrue(old_file.exists())

        applied = cleaner.clean_old_cache_files("fixture cache", root, cutoff, dry_run=False)
        self.assertEqual(applied.removed, 1)
        self.assertFalse(old_file.exists())
        self.assertTrue(recent_file.exists())
        self.assertEqual(outside.read_text(), "preserve-me")
        self.assertEqual((outside_dir / "keep.txt").read_text(), "still-here")
        self.assertTrue((root / "outside-link").is_symlink())
        self.assertTrue((root / "outside-dir-link").is_symlink())

    def test_running_chromium_skips_its_cache(self):
        chromium_cache = self.cache / "chromium" / "Default" / "Cache"
        chromium_cache.mkdir(parents=True)
        old_file = chromium_cache / "old.cache"
        old_file.write_text("browser-cache")
        old_time = time.time() - 45 * cleaner.DAY_SECONDS
        os.utime(old_file, (old_time, old_time))

        with mock.patch.object(cleaner, "running_browser_processes", return_value=["chromium"]):
            _, results, _, _ = cleaner.run_cleanup(self.home, self.data, self.cache, dry_run=False)

        browser_result = next(result for result in results if result.label == "Chromium cache retention")
        self.assertTrue(browser_result.skipped)
        self.assertTrue(old_file.exists())

    def test_symlinked_trash_root_is_preserved(self):
        real_trash = self.home / "real-trash"
        (real_trash / "files").mkdir(parents=True)
        (real_trash / "info").mkdir()
        sentinel = real_trash / "files" / "user.txt"
        sentinel.write_text("keep")
        self.data.mkdir(parents=True)
        (self.data / "Trash").symlink_to(real_trash, target_is_directory=True)

        result = cleaner.clean_expired_trash(
            self.data / "Trash",
            time.time() - cleaner.RETENTION_DAYS * cleaner.DAY_SECONDS,
            dry_run=False,
        )
        self.assertTrue(result.skipped)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_malformed_trash_metadata_is_preserved_as_warning(self):
        trash = self.data / "Trash"
        (trash / "files").mkdir(parents=True)
        (trash / "info").mkdir()
        metadata = trash / "info" / "unknown.txt.trashinfo"
        metadata.write_text("[Trash Info]\nDeletionDate=not-a-date\n")
        (trash / "files" / "unknown.txt").write_text("keep")

        result = cleaner.clean_expired_trash(
            trash, time.time() - cleaner.RETENTION_DAYS * cleaner.DAY_SECONDS, dry_run=False
        )
        self.assertEqual(result.errors, [])
        self.assertTrue(result.warnings)
        self.assertTrue(metadata.exists())
        self.assertTrue((trash / "files" / "unknown.txt").exists())


suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(Tests),unittest.defaultTestLoader.loadTestsFromTestCase(CleanupFixtureTests)])
result=unittest.TextTestRunner(verbosity=2).run(suite)
_fixtures.cleanup()
raise SystemExit(0 if result.wasSuccessful() else 1)
