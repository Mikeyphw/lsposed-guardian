#!/system/bin/sh
ui_print ' - LSPosed Guardian 0.9.0'
ui_print ' - Independent Vector/LSPosed recovery monitor'
ui_print ' - Default mode: observe (no automatic restoration)'
ui_print ' - Offline restoration remains UNQUALIFIED / not armed'
# KernelSU manages webroot permissions and SELinux context; do not modify it.
set_perm_recursive "$MODPATH/lib" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/guardian.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

set_perm "$MODPATH/crash-monitor.sh" 0 0 0755
set_perm "$MODPATH/selftest.sh" 0 0 0755

set_perm "$MODPATH/history-monitor.sh" 0 0 0755
