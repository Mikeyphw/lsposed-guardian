"""Manual-only verified DB snapshots; never writes a live restore."""
import pathlib
import subprocess
import unittest
import test_guardian as fixture

class VaultTests(unittest.TestCase):
    def setUp(self):
        self.f=fixture.GuardianTests('test_normal_boot_saves_consistent_snapshot_and_clears_pending')
        self.f.setUp();self.addCleanup(self.f.doCleanups)
        self.f.good_boot()
    def cmd(self,*a,expect=0):return self.f.run_shell('guardian.sh',*a,expect=expect)
    def test_manual_only_disabled_by_default(self):
        self.assertIn('backup_vault_enabled=0',self.cmd('backup','status'))
        self.cmd('backup','create','--apply',expect=1)
        self.assertFalse((self.f.state/'backup-vault/snapshots').exists())
    def test_verified_snapshots_multiple_same_second_and_retention(self):
        self.cmd('backup-enable','--apply')
        ids=[]
        for _ in range(7):
            line=self.cmd('backup','create','--apply')
            ids.append(line.split('id=')[1].split()[0])
        self.assertEqual(len(set(ids)),7)
        out=self.cmd('backup','list')
        self.assertEqual(out.count(' status=verified'),5)
        self.assertNotIn(ids[0]+' status=',out)
        self.assertIn(ids[-1]+' status=verified',out)
    def test_tampered_snapshot_and_live_restore_refused(self):
        self.cmd('backup-enable','--apply')
        out=self.cmd('backup','create','--apply')
        ident=out.split('id=')[1].split()[0]
        self.assertIn('integrity=verified',self.cmd('backup','verify',ident))
        self.cmd('backup','restore',ident,expect=1)
        snap=self.f.state/'backup-vault/snapshots'/ident
        (snap/'modules_config.db').write_bytes(b'garbled')
        self.cmd('backup','verify',ident,expect=1)
    def test_full_configuration_archive_and_comparison(self):
        self.cmd('backup-enable','--apply')
        self.f.db.parent.joinpath('preferences.xml').write_text('<config>test</config>')
        a=self.cmd('backup','create','--apply').split('id=')[1].split()[0]
        self.f.db.parent.joinpath('preferences.xml').write_text('<config>new</config>')
        b=self.cmd('backup','create','--apply').split('id=')[1].split()[0]
        self.assertIn('comparison='+a+'..'+b,self.cmd('backup','compare',a,b))
        archive=self.f.state/'backup-vault/snapshots'/b/'config.tar.gz'
        self.assertTrue(archive.is_file())
        import tarfile
        with tarfile.open(archive,'r:gz') as t:
            self.assertIn('config/modules_config.db',t.getnames())
            self.assertIn('config/preferences.xml',t.getnames())
        self.assertIn('mod.alpha',self.cmd('backup','modules',b))

    def test_archive_tamper_is_rejected_without_restore(self):
        self.cmd('backup-enable','--apply')
        name=self.cmd('backup','create','--apply').split('id=')[1].split()[0]
        snap=self.f.state/'backup-vault/snapshots'/name
        (snap/'config.tar.gz').write_bytes(b'invalid tar')
        self.cmd('backup','verify',name,expect=1)
        self.assertIn('status=invalid',self.cmd('backup','list'))
        self.cmd('backup','restore',name,expect=1)

    def test_same_second_limit_is_configurable(self):
        self.cmd('backup-enable','--apply')
        self.cmd('backup','limit','3','--apply')
        self.assertIn('backup_vault_limit=3',self.cmd('backup','status'))
        self.cmd('backup','limit','0','--apply',expect=2)
        for _ in range(5): self.cmd('backup','create','--apply')
        self.assertEqual(self.cmd('backup','list').count('status=verified'),3)

    def test_unsafe_config_symlink_blocks_capture(self):
        self.cmd('backup-enable','--apply')
        self.f.db.parent.joinpath('untrusted.xml').symlink_to(self.f.db)
        self.cmd('backup','create','--apply',expect=1)
        self.assertEqual(self.cmd('backup','list').count('status=verified'),0)

    def test_terminal_menu_read_only_status_and_exit(self):
        cp=subprocess.run(['/bin/sh',str(fixture.ROOT/'guardian.sh'),'backup','menu'],
          input='7\n0\n',text=True,capture_output=True,env=self.f.env,timeout=15)
        self.assertEqual(cp.returncode,0,cp.stderr)
        self.assertIn('backup_vault_mode=manual_only',cp.stdout)

    def test_sqlite_module_query_failure_is_not_masked_by_sort(self):
        self.cmd('backup-enable','--apply')
        sqlite=self.f.fakebin/'sqlite3'
        src=sqlite.read_text()
        sqlite.write_text(src.replace('con=sqlite3.connect',
          "if 'module_pkg_name FROM modules' in sys.argv[-1]: sys.exit(19)\ncon=sqlite3.connect"))
        self.cmd('backup','create','--apply',expect=1)
        self.assertEqual(self.cmd('backup','list').count('status=verified'),0)

    def test_symlinked_snapshot_refused(self):
        self.cmd('backup-enable','--apply')
        vault=self.f.state/'backup-vault/snapshots'
        vault.mkdir(parents=True)
        (vault/'snap-20261118_120000_000001').symlink_to(self.f.db.parent)
        self.cmd('backup','verify','snap-20261118_120000_000001',expect=1)
        self.assertNotIn('20261118',self.cmd('backup','list'))
if __name__=='__main__':unittest.main()
