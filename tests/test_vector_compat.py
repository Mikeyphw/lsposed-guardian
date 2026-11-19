"""Future Vector versions: capability-based monitoring; unknown schemas refuse mutation."""
import json
import unittest
import test_guardian as fixture


class VectorCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.f = fixture.GuardianTests('test_normal_boot_saves_consistent_snapshot_and_clears_pending')
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)

    def test_future_version_works_with_verified_cli_contract(self):
        for version in (100, 3113, 999999):
            with self.subTest(version=version):
                self.f.vector_prop.write_text(f'id=zygisk_vector\nversionCode={version}\n')
                out = self.f.run_shell('guardian.sh', 'vector-capabilities')
                self.assertIn(f'vector_version_code={version}', out)
                self.assertIn('vector_module_toggle=available_with_transaction_checks', out)
                if version != 3112:
                    self.assertIn('vector_offline_restore=blocked_unqualified_version', out)

    def test_compact_json_counts_all_members(self):
        cli=self.f.vector
        cli.write_text(cli.read_text().replace('indent=2','separators=(",", ":")'))
        self.f.vector_prop.write_text('id=zygisk_vector\nversionCode=888888\n')
        self.assertIn('vector_module_toggle=available_with_transaction_checks',
          self.f.run_shell('guardian.sh','vector-capabilities'))

    def test_duplicate_json_members_block_mutations(self):
        cli=self.f.vector
        cli.write_text(cli.read_text().replace("'data':data},indent=2)","'data':data+data},indent=2)"))
        self.assertIn('vector_module_toggle=blocked',
          self.f.run_shell('guardian.sh','vector-capabilities'))
        before=self.f.mods.read_text()
        self.f.run_shell('guardian.sh','quarantine','mod.alpha','--apply',expect=1)
        self.assertEqual(before,self.f.mods.read_text())

    def test_changed_future_inventory_schema_refuses_writes(self):
        cli=self.f.vector
        cli.write_text(cli.read_text().replace("'PACKAGE':k,'STATUS':", "'packageName':k,'STATUS':"))
        self.f.vector_prop.write_text('id=zygisk_vector\nversionCode=5000\n')
        out=self.f.run_shell('guardian.sh', 'vector-capabilities')
        self.assertIn('vector_module_toggle=blocked', out)
        before=self.f.mods.read_text()
        self.f.run_shell('guardian.sh', 'quarantine', 'mod.alpha', '--apply', expect=1)
        self.assertEqual(before, self.f.mods.read_text())

    def test_wrong_module_identity_refuses_writes_even_same_cli(self):
        self.f.vector_prop.write_text('id=unrecognized_vector\nversionCode=3112\n')
        out=self.f.run_shell('guardian.sh', 'vector-capabilities')
        self.assertIn('vector_identity=unverified', out)
        self.assertIn('vector_module_toggle=blocked', out)
        self.f.run_shell('guardian.sh','quarantine','mod.alpha','--apply',expect=1)
        self.assertTrue(json.loads(self.f.mods.read_text())['mod.alpha'])

    def test_malformed_future_version_refuses_module_mutations(self):
        self.f.vector_prop.write_text('id=zygisk_vector\nversionCode=something\n')
        out=self.f.run_shell('guardian.sh', 'vector-capabilities')
        self.assertIn('vector_module_toggle=blocked', out)
        self.assertIn('vector_offline_restore=blocked_unqualified_version', out)


if __name__=='__main__':unittest.main()
