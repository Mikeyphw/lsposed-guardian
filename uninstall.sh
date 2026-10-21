#!/system/bin/sh
# Preserve snapshots and logs for a potential recovery/reinstall. Disarm on uninstall.
STATE=/data/adb/lsposed-guardian
CFG="$STATE/config.conf"
if [ -f "$CFG" ]; then
  sed 's/^AUTO_RECOVERY=.*/AUTO_RECOVERY=0/' "$CFG" > "$CFG.uninstall-tmp" &&
    chmod 600 "$CFG.uninstall-tmp" && mv -f "$CFG.uninstall-tmp" "$CFG"
fi
rm -f "$STATE/boot/manual-restore"
exit 0
