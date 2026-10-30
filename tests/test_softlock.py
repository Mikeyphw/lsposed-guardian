"""Post-boot softlock tests: all host-isolated, no root/device writes or real reboot."""
import json
import pathlib
import unittest
import test_guardian as fixture

class SoftlockTests(unittest.TestCase):
    def setUp(self):
        self.f = fixture.GuardianTests('test_normal_boot_saves_consistent_snapshot_and_clears_pending')
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.f.boot.write_text('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n')
        self.f.env['FAKE_SL_WINDOW'] = 'absent'
        (self.f.fakebin/'dumpsys').write_text('''#!/bin/sh
case "$FAKE_SL_WINDOW" in
visible) cat <<'EOF'
WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #0 Window{2a u0 Normal App}:
    mAttrs=WM.LayoutParams{ty=1}
    isOnScreen=true
  Window #1 Window{2b u0 Boot Progress}:
    mAttrs=WM.LayoutParams{ty=2021}
    isOnScreen=true
EOF
;;
uncertain) cat <<'EOF'
  Window #0 Window{2b u0 Boot Progress}:
    mAttrs=WM.LayoutParams{ty=2021}
    mHasSurface=true
EOF
;;
spoof) cat <<'EOF'
  Window #0 Window{2b u0 Normal App}:
    mAttrs=WM.LayoutParams{ty=1}
    isOnScreen=true
  # ty=2021 in a policy comment, NOT a window
EOF
;;
absent) cat <<'EOF'
  Window #0 Window{2a u0 Normal App}:
    mAttrs=WM.LayoutParams{ty=1}
    isOnScreen=true
EOF
;;
hidden) cat <<'EOF'
  Window #0 Window{2b u0 Boot Progress}:
    mAttrs=WM.LayoutParams{ty=2021}
    isVisible=false
EOF
;;
empty) echo 'WINDOW MANAGER WINDOWS';;
fail) exit 42;;
*) exit 1;; esac
''')
        (self.f.fakebin/'timeout').write_text('#!/bin/sh\nshift\nexec "$@"\n')
        for x in ('dumpsys','timeout'):(self.f.fakebin/x).chmod(0o755)
        self.f.run_shell('post-fs-data.sh')

    def guard(self,*cmd,expect=0):
        return self.f.run_shell('guardian.sh',*cmd,expect=expect)

    def service(self,mode):
        self.f.env['FAKE_SL_WINDOW']=mode
        self.f.run_shell('service.sh')

    def test_normal_progress_absent_clears_boot_and_does_not_rescue(self):
        self.service('absent')
        self.assertIn('softlock_decision=clear',self.guard('softlock-status'))
        self.assertEqual((self.f.state/'boot/last-success-id').read_text().strip(),self.f.boot.read_text().strip())
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())
        self.assertFalse((self.f.state/'boot/safe-mode-request').exists())

    def test_persistent_visible_stalls_success_even_with_stable_systemui(self):
        self.service('visible')
        self.assertIn('softlock_decision=confirmed',self.guard('softlock-status'))
        self.assertIn('persistent_visible_boot_progress',self.guard('softlock-events'))
        self.assertFalse((self.f.state/'boot/last-success-id').exists())
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())
        report=json.loads(self.guard('report'))
        self.assertEqual(report['softlock_state'],'confirmed')
        self.assertFalse(report['softlock_rescue_armed'])

    def test_unverified_visibility_never_claims_softlock_or_rescue(self):
        self.service('uncertain')
        self.assertIn('softlock_decision=unverified',self.guard('softlock-status'))
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())

    def test_policy_text_or_type_without_window_does_not_trigger(self):
        self.service('spoof')
        self.assertIn('softlock_decision=clear',self.guard('softlock-status'))

    def test_hidden_window_without_explicit_visibility_is_unverified(self):
        self.service('hidden')
        self.assertIn('softlock_decision=unverified',self.guard('softlock-status'))

    def test_unparseable_oem_window_format_is_unverified(self):
        self.service('empty')
        self.assertIn('softlock_decision=unverified',self.guard('softlock-status'))

    def test_armed_but_unverified_vector_marker_path_refuses_reboot(self):
        cfg=self.f.state/'config.conf'
        cfg.write_text(cfg.read_text()+'\nAUTO_SOFTLOCK=1\nAUTO_SAFE_MODE=1\nAUTO_BOOTLOOP_REBOOT=1\n')
        self.service('visible')
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())
        self.assertIn('softlock_decision=confirmed',self.guard('softlock-status'))
        self.assertIn('softlock_reason=vector_marker_not_safe',self.guard('softlock-status'))

    def test_dumpsys_failure_is_unverified_no_recovery(self):
        self.service('fail')
        self.assertIn('softlock_decision=unverified',self.guard('softlock-status'))
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())

    def test_manual_probe_does_not_change_boot_decision(self):
        self.f.env['FAKE_SL_WINDOW']='visible'
        self.assertIn('softlock_probe=visible_boot_progress',self.guard('softlock-probe'))
        self.assertIn('softlock_decision=not_observed_this_boot',self.guard('softlock-status'))

    def test_softlock_arm_independently_enables_bounded_fallback(self):
        self.service('absent')
        self.guard('softlock-on','--apply')
        out=self.guard('softlock-status')
        self.assertIn('softlock_enabled=1',out)
        automatic=self.guard('automatic-status')
        self.assertIn('safe_mode_armed=1',automatic)
        self.assertIn('auto_bootloop_reboot=1',automatic)
        self.assertIn('auto_quarantine=0',automatic)
        self.assertFalse((self.f.state/'softlock/recovery-attempt').exists())

    def test_softlock_arm_refuses_unsupported_rom_or_visible_dialog(self):
        self.service('absent')
        self.f.env['FAKE_SL_WINDOW']='empty'
        self.guard('softlock-on','--apply',expect=1)
        self.f.env['FAKE_SL_WINDOW']='visible'
        self.guard('softlock-on','--apply',expect=1)
        self.assertIn('softlock_enabled=0',self.guard('softlock-status'))

    def test_disarm_stops_future_softlock_actions(self):
        cfg=self.f.state/'config.conf'
        cfg.write_text(cfg.read_text()+'\nAUTO_SOFTLOCK=1\n')
        self.guard('softlock-off')
        self.assertIn('softlock_enabled=0',self.guard('softlock-status'))
        self.assertIn('AUTO_SOFTLOCK=0',cfg.read_text())

    def test_config_validation_refuses_malformed_timeout(self):
        cfg=self.f.state/'config.conf';cfg.write_text(cfg.read_text()+'\nSOFTLOCK_GRACE_SECONDS=1\n')
        self.assertIn('softlock_grace_seconds=180',self.guard('softlock-status'))

if __name__=='__main__':unittest.main()
