"""Host-only FallbackHome and one-shot selective zygote restart safety tests."""
import json
import time
import unittest
import test_softlock

class ExtendedSoftlockTests(unittest.TestCase):
    def setUp(self):
        self.s = test_softlock.SoftlockTests('test_normal_progress_absent_clears_boot_and_does_not_rescue')
        self.s.setUp()
        self.addCleanup(self.s.f.doCleanups)
        f=self.s.f
        (f.fakebin/'dumpsys').write_text('''#!/bin/sh
case "$1" in
  window)
    echo '  Window #0 Window{2a u0 Normal App}:'
    echo '    mAttrs=WM.LayoutParams{ty=1}'
    echo '    isOnScreen=true' ;;
  activity)
    case "$FAKE_SL_ACTIVITY" in
      fallback) echo 'topResumedActivity=ActivityRecord{123 u0 com.android.settings/.FallbackHome t1}' ;;
      home) echo 'topResumedActivity=ActivityRecord{123 u0 com.android.launcher/.Launcher t1}' ;;
      failure) exit 7 ;;
    esac ;;
esac
''')
        (f.fakebin/'getprop').write_text('''#!/bin/sh
case "$1" in
 sys.boot_completed) echo 1 ;;
 init.svc.zygote) echo running ;;
esac
''')
        (f.fakebin/'pidof').write_text('''#!/bin/sh
case "$1" in
 system_server) echo 333 ;;
 com.android.systemui) echo 444 ;;
esac
''')
        (f.fakebin/'setprop').write_text('''#!/bin/sh
[ "$FAKE_RESTART_FAILED" = 1 ] && exit 42
printf '%s %s\\n' "$1" "$2" >> "$FAKE_SOFT_RESTART_LOG"
''')
        for p in ('getprop','pidof','dumpsys','setprop'):(f.fakebin/p).chmod(0o755)
        f.env['FAKE_SL_ACTIVITY']='home'
        f.env['FAKE_RESTART_FAILED']='0'
        f.env['FAKE_SOFT_RESTART_LOG']=str(f.base/'restarts.log')
        (f.base/'restarts.log').write_text('')

    def test_normal_home_qualified_without_restart(self):
        self.s.f.run_shell('service.sh')
        self.assertIn('softlock_decision=clear', self.s.guard('softlock-status'))
        self.assertEqual((self.s.f.base/'restarts.log').read_text(),'')

    def test_fallback_without_failure_never_qualified_or_mutated(self):
        self.s.f.env['FAKE_SL_ACTIVITY']='fallback'
        self.s.f.run_shell('service.sh')
        self.assertIn('softlock_decision=unverified',self.s.guard('softlock-status'))
        self.assertIn('fallback_home_no_independent_failure_evidence',self.s.guard('softlock-status'))
        self.assertFalse((self.s.f.state/'boot/last-success-id').exists())
        self.assertFalse((self.s.f.state/'boot/pending-id').exists())
        self.assertEqual((self.s.f.state/'boot/failures').read_text().strip(), '0')
        self.assertTrue(json.loads(self.s.f.mods.read_text())['mod.alpha'])
        self.assertEqual((self.s.f.base/'restarts.log').read_text(),'')

    def test_fallback_with_current_boot_keyguard_failure_confirmed_no_auto(self):
        self.s.f.env['FAKE_SL_ACTIVITY']='fallback'
        self.s.f.log_fixture.write_text(f'{int(time.time())}.123 CR DEAD com.android.systemui/.keyguard.KeyguardService')
        self.s.f.run_shell('service.sh')
        out=self.s.guard('softlock-status')
        self.assertIn('softlock_decision=confirmed',out)
        self.assertIn('persistent_fallback_keyguard_failure',out)
        self.assertFalse((self.s.f.state/'boot/last-success-id').exists())
        self.assertEqual((self.s.f.base/'restarts.log').read_text(),'')

    def test_explicit_suspect_quarantined_then_single_restart(self):
        f=self.s.f
        f.env['FAKE_SL_ACTIVITY']='fallback'
        f.log_fixture.write_text(f'{int(time.time())}.123 CR DEAD com.android.systemui/.keyguard.KeyguardService')
        cfg=f.state/'config.conf'
        cfg.write_text(cfg.read_text()+'\nSOFTLOCK_SELECTIVE=1\nSOFTLOCK_ZYGOTE_RESTART=1\nSOFTLOCK_SUSPECT=mod.alpha\nAUTO_SOFTLOCK=1\n')
        f.run_shell('service.sh')
        self.assertFalse(json.loads(f.mods.read_text())['mod.alpha'])
        self.assertTrue((f.state/'quarantine/active/mod.alpha.record').exists())
        self.assertEqual((f.base/'restarts.log').read_text().strip(),'ctl.restart zygote')
        self.assertIn('quarantined_restart_unverified',self.s.guard('softlock-status'))
        self.assertFalse((f.state/'softlock/recovery-attempt').exists())
        self.assertFalse((f.state/'boot/last-success-id').exists())
        self.assertEqual((f.base/'restarts.log').read_text().count('ctl.restart'),1)

    def test_no_resumed_activity_is_unverified_not_healthy(self):
        f=self.s.f
        f.env['FAKE_SL_ACTIVITY']='failure'
        f.run_shell('service.sh')
        self.assertIn('softlock_decision=unverified',self.s.guard('softlock-status'))
        self.assertFalse((f.state/'boot/last-success-id').exists())

    def test_stale_keyguard_death_does_not_authorize_recovery(self):
        f=self.s.f
        f.env['FAKE_SL_ACTIVITY']='fallback'
        f.log_fixture.write_text(f'{int(time.time())-86400}.123 CR DEAD com.android.systemui/.keyguard.KeyguardService')
        f.run_shell('service.sh')
        self.assertIn('softlock_decision=unverified',self.s.guard('softlock-status'))
        self.assertFalse((f.state/'softlock/selective-attempt').exists())

    def test_manual_verification_cannot_manufacture_success(self):
        f=self.s.f
        (f.state/'softlock').mkdir(exist_ok=True)
        (f.state/'softlock/restart-request').write_text(f.boot.read_text().strip())
        (f.state/'softlock/restart-verification').write_text('framework_restart_unverified')
        self.s.guard('softlock-verify',expect=1)
        self.assertEqual((f.state/'softlock/restart-verification').read_text(),'framework_restart_unverified')

    def test_failed_restart_never_falls_through_to_full_reboot(self):
        f=self.s.f
        f.env.update({'FAKE_SL_ACTIVITY':'fallback','FAKE_RESTART_FAILED':'1'})
        f.log_fixture.write_text(f'{int(time.time())}.123 CR DEAD com.android.systemui/.keyguard.KeyguardService')
        cfg=f.state/'config.conf'
        cfg.write_text(cfg.read_text()+'\nSOFTLOCK_SELECTIVE=1\nSOFTLOCK_ZYGOTE_RESTART=1\nSOFTLOCK_SUSPECT=mod.alpha\nAUTO_SOFTLOCK=1\n')
        f.run_shell('service.sh')
        self.assertFalse(json.loads(f.mods.read_text())['mod.alpha'])
        self.assertIn('quarantined_restart_unverified',self.s.guard('softlock-status'))
        self.assertFalse((f.state/'softlock/recovery-attempt').exists())
        self.assertEqual((f.base/'restarts.log').read_text(),'')

if __name__=='__main__': unittest.main()
