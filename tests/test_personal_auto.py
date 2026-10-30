"""Opt-in automation exercised against isolated fake Vector; never Android."""
import json
import pathlib
import time
import unittest
import test_guardian as guardian_fixture


class PersonalAutomationTests(unittest.TestCase):
    def setUp(self):
        self.fixt = guardian_fixture.GuardianTests('test_normal_boot_saves_consistent_snapshot_and_clears_pending')
        self.fixt.setUp()
        self.fixt.boot.write_text('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.addCleanup(self.fixt.doCleanups)
        self.fixt.good_boot()

    def run_guard(self, *args, expect=0):
        return self.fixt.run_shell('guardian.sh', *args, expect=expect)

    def configure(self):
        p=self.fixt.state/'config.conf'
        s=p.read_text().replace('PASSIVE_CRASH_MONITOR=0','PASSIVE_CRASH_MONITOR=1').replace('HISTORY_MONITOR=0','HISTORY_MONITOR=1')
        p.write_text(s)
        # Historical scopes of one module are explicit and verified.
        self.fixt.env['FAKE_SCOPES_JSON']=json.dumps({'mod.alpha':[{'APP_PACKAGE':'org.example.app','USER_ID':0}]})
        self.run_guard('auto-allow','mod.alpha','--apply')
        self.run_guard('history-capture')
        now=int(time.time())
        for d in ('history','monitor'):
            base=self.fixt.state/d
            base.mkdir(parents=True,exist_ok=True)
            for k,v in {'last-boot':'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','last-result':'ok','last-epoch':str(now)}.items():
                (base/k).write_text(v+'\n')
        self.run_guard('auto-arm','--apply')
        return now

    def write_events(self, now, app='org.example.app',pids=(401,402,403)):
        d=self.fixt.state/'crashes';d.mkdir(exist_ok=True)
        (d/'events.tsv').write_text(''.join(f'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\t{now}\t{app}\t{pid}\n' for pid in pids))

    def enabled(self):
        return json.loads(self.fixt.mods.read_text())['mod.alpha']

    def test_default_no_automatic_changes(self):
        self.write_events(int(time.time()))
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())
        self.assertIn('auto_quarantine=0',self.run_guard('auto-status'))

    def test_arm_requires_an_explicit_allowlist_and_fresh_heartbeats(self):
        self.run_guard('auto-arm','--apply',expect=1)
        self.run_guard('auto-allow','mod.alpha','--apply')
        self.run_guard('auto-arm','--apply',expect=1)
        self.assertTrue(self.enabled())

    def test_protected_packages_are_refused(self):
        for pkg in ('com.openai.chatgpt','com.android.systemui','lspd','android'):
            self.run_guard('auto-allow',pkg,'--apply',expect=2)
        self.assertTrue(self.enabled())

    def test_repeated_crashes_trigger_only_authorized_module_and_keep_journal(self):
        now=self.configure()
        self.write_events(now)
        out=self.run_guard('auto-tick','--apply')
        self.assertIn('QUARANTINED mod.alpha',out)
        self.assertFalse(self.enabled())
        self.assertIn('AUTO_CORRELATED_NOT_CAUSAL',(self.fixt.state/'quarantine/events.tsv').read_text())
        self.assertIn('attempted_boot=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',self.run_guard('auto-status'))
        self.run_guard('auto-tick','--apply')
        self.assertEqual(len((self.fixt.state/'quarantine/events.tsv').read_text().splitlines()),1)
        self.run_guard('rollback','mod.alpha','--apply')
        self.assertTrue(self.enabled())

    def test_only_one_pid_does_not_trigger(self):
        now=self.configure()
        self.write_events(now,pids=(900,900,900))
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())

    def test_excluded_app_never_triggers(self):
        now=self.configure()
        self.write_events(now,app='com.openai.chatgpt')
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())

    def test_missing_same_boot_historical_checkpoint_refuses(self):
        now=self.configure()
        (self.fixt.state/'history/samples.tsv').write_text('')
        self.write_events(now)
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())

    def test_stale_monitor_heartbeat_refuses(self):
        now=self.configure()
        (self.fixt.state/'monitor/last-epoch').write_text('1\n')
        self.write_events(now)
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())

    def test_live_collector_reloads_policy_between_polls(self):
        source=(pathlib.Path(__file__).resolve().parents[1]/'crash-monitor.sh').read_text()
        self.assertIn('load_config\n  [ "$PASSIVE_CRASH_MONITOR" = 1 ] || break',source)

    def test_disarm_stops_automation(self):
        now=self.configure()
        self.run_guard('auto-disarm')
        self.write_events(now)
        self.run_guard('auto-tick','--apply')
        self.assertTrue(self.enabled())

    def test_safe_mode_never_mutates_vector_sqlite_in_fixture(self):
        self.run_guard('safe-mode-arm','--apply')
        self.fixt._make_db(version=0)
        for boot in ('boot-two','boot-three','boot-four'):
            self.fixt.next_boot(boot)
        self.assertEqual(self.fixt.get_version(),0)
        self.assertFalse((self.fixt.state/'boot/safe-mode-request').exists())

    def test_legacy_offline_restore_inert_even_when_config_is_armed(self):
        p=self.fixt.state/'config.conf'
        p.write_text(p.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self.fixt._make_db(version=0)
        self.run_guard('arm',expect=1)
        for boot in ('boot-two','boot-three','boot-four'):
            self.fixt.next_boot(boot)
        self.assertEqual(self.fixt.get_version(),0)

    def test_single_switch_enables_all_eligible_scoped_modules_without_allowlist(self):
        conf=self.fixt.state/'config.conf'
        conf.write_text(conf.read_text().replace('PASSIVE_CRASH_MONITOR=0','PASSIVE_CRASH_MONITOR=1').replace('HISTORY_MONITOR=0','HISTORY_MONITOR=1'))
        self.fixt.env['FAKE_SCOPES_JSON']=json.dumps({'mod.alpha':[{'APP_PACKAGE':'org.example.app','USER_ID':0}]})
        self.run_guard('history-capture')
        stamp=int(time.time())
        for d in ('monitor','history'):
            base=self.fixt.state/d
            base.mkdir(parents=True,exist_ok=True)
            for k,v in {'last-boot':'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','last-result':'ok','last-epoch':str(stamp)}.items():
                (base/k).write_text(v+'\n')
        out=self.run_guard('automatic-on','--apply')
        self.assertIn('PASS_GUARDIAN_AUTOMATIC_MODE_ARMED',out)
        status=self.run_guard('automatic-status')
        self.assertIn('policy=all_scoped',status)
        self.assertIn('safe_mode_armed=1',status)
        self.assertIn('auto_bootloop_reboot=1',status)
        self.write_events(stamp)
        self.run_guard('auto-tick','--apply')
        self.assertFalse(self.enabled())
        out=self.run_guard('automatic-off')
        self.assertIn('PASS_GUARDIAN_AUTOMATIC_MODE_DISARMED',out)
        self.assertIn('auto_quarantine=0',self.run_guard('automatic-status'))
        self.assertIn('safe_mode_armed=0',self.run_guard('automatic-status'))
        self.assertFalse(self.enabled()) # disarm must never silently roll back

    def test_single_switch_fails_when_legacy_flag_is_armed(self):
        p=self.fixt.state/'config.conf'
        p.write_text(p.read_text().replace('AUTO_RECOVERY=0','AUTO_RECOVERY=1'))
        self.run_guard('automatic-on','--apply',expect=1)
        self.assertIn('auto_quarantine=0',self.run_guard('automatic-status'))

    def test_single_switch_requires_apply(self):
        self.run_guard('automatic-on',expect=2)
        self.assertIn('auto_quarantine=0',self.run_guard('automatic-status'))

    def test_notification_opt_in_transport_is_explicit_and_fail_closed(self):
        self.assertIn('notifications_enabled=0',self.run_guard('notifications-status'))
        self.run_guard('notifications-test','--apply',expect=1)
        self.run_guard('notifications-on','--apply')
        out=self.run_guard('notifications-status')
        self.assertIn('notifications_enabled=1',out)
        self.assertIn('delivery_confirmation=NOT_AVAILABLE_FROM_SHELL',out)
        self.run_guard('notifications-test','--apply',expect=1)
        self.assertIn('notifications_last_result=unavailable_or_rejected',self.run_guard('notifications-status'))
        self.run_guard('notifications-off')
        self.assertIn('notifications_enabled=0',self.run_guard('notifications-status'))
        self.run_guard('notifications-on',expect=2)
        self.run_guard('notifications-test',expect=2)

    def test_webui_crash_exclusions_and_cooldown_are_real_root_policy(self):
        out=self.run_guard('automatic-status')
        self.assertIn('crash_exclude_packages=com.openai.chatgpt',out)
        self.assertIn('cooldown_seconds=43200',out)
        self.assertIn('history_monitor_enabled=',out)
        self.run_guard('exclusion-add','org.example.app','--apply')
        self.assertIn('org.example.app',self.run_guard('automatic-status'))
        self.run_guard('exclusion-add','org.example.app','--apply')
        self.assertEqual(self.run_guard('automatic-status').count('org.example.app'),1)
        self.run_guard('exclusion-remove','org.example.app','--apply')
        self.assertNotIn('org.example.app',self.run_guard('automatic-status'))
        self.run_guard('exclusion-remove','com.openai.chatgpt','--apply',expect=2)
        self.run_guard('exclusion-add','invalid;reboot','--apply',expect=2)
        self.run_guard('exclusion-add','com.android.systemui','--apply',expect=2)
        self.assertIn('com.openai.chatgpt',self.run_guard('automatic-status'))
        self.run_guard('cooldown-set','86400','--apply')
        self.assertIn('cooldown_seconds=86400',self.run_guard('automatic-status'))
        self.run_guard('cooldown-set','1','--apply',expect=2)
        self.run_guard('cooldown-set','86400',expect=2)
        self.assertIn('cooldown_seconds=86400',self.run_guard('automatic-status'))

    def test_structured_module_scopes_and_verified_history(self):
        self.fixt.env['FAKE_SCOPES_JSON']=json.dumps({'mod.alpha':[{'APP_PACKAGE':'org.example.app','USER_ID':0}]})
        count=self.run_guard('scope-structured','mod.alpha')
        self.assertIn('scope_count=1',count)
        self.assertIn('scope=org.example.app|0',count)
        self.run_guard('history-capture')
        h=self.run_guard('history-module','mod.alpha')
        self.assertRegex(h,r'module_observation=\d+\|1\|1')
        # Mismatched checksums must not generate unverifiable observations.
        checkpoints=self.fixt.state/'history/checkpoints'
        original=next(checkpoints.glob('*.tsv'))
        original.write_text(original.read_text()+'S\tmod.alpha\torg.bad.app\t0\n')
        self.run_guard('history-module','mod.alpha',expect=1)
        self.run_guard('scope-structured','invalid;reboot',expect=2)

    def test_sampler_background_failure_remains_visible_after_manual_capture(self):
        base=self.fixt.state/'history';base.mkdir(parents=True,exist_ok=True)
        (base/'last-background-failure-reason').write_text('vector_scope_unavailable\n')
        (base/'last-background-failure-module').write_text('mod.alpha\n')
        self.run_guard('history-capture')
        status=self.run_guard('history-health')
        self.assertIn('history_last_failure_reason=vector_scope_unavailable',status)
        self.assertIn('history_last_failure_module=mod.alpha',status)
        self.assertIn('history_manual_or_background_capture_reason=none',status)

    def test_writable_policy_fields_are_restricted_to_enumerated_values(self):
        out=self.run_guard('automatic-status')
        self.assertIn('policy=allowlist',out)
        self.assertIn('legacy_unjournaled_sqlite_restore=DISABLED',out)

if __name__=='__main__': unittest.main()
