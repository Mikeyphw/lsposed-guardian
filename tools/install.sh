#!/bin/sh
# Invoked through Devtool job:flash-ksu. Retains the terminal for interactive module installers.
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
VERSION=$(sed -n 's/^version=//p' "$REPO/module.prop" | head -n 1)
ZIP="$REPO/dist/LSPosed-Guardian-v${VERSION#v}.zip"
[ -f "$ZIP" ] || { echo "No built ZIP: $ZIP" >&2; exit 2; }
python3 -S "$REPO/tools/verify_build.py"
case "$ZIP" in *"'"*) echo 'Unsafe ZIP path' >&2; exit 2;; esac
if [ "${GUARDIAN_INSTALL_DRY_RUN:-0}" = 1 ]; then
  echo "PASS_GUARDIAN_INSTALL_DRY_RUN: ksud module install $ZIP"
  exit 0
fi
[ "$(uname -o 2>/dev/null || true)" != 'GNU/Linux' ] || : # Termux itself uses the Linux kernel.
command -v su >/dev/null 2>&1 || { echo 'ERROR: su is required (KernelSU root)' >&2; exit 127; }
# No piped output, background job, or input redirection. A custom installer can use the TTY.
# Evidence captured before install; no existing state or history is changed.
if [ "$(id -u)" -eq 0 ]; then
  sh "$REPO/tools/upgrade_receipt.sh" pre-install
else
  su -c "'/system/bin/sh' '$REPO/tools/upgrade_receipt.sh' pre-install"
fi
printf 'Installing verified Guardian %s with KernelSU (interactive terminal)...\n' "$VERSION"
if [ "$(id -u)" -eq 0 ]; then
  command -v ksud >/dev/null 2>&1 || { echo 'ERROR: ksud unavailable as root' >&2; exit 127; }
  python3 -S "$REPO/tools/pty_install.py" ksud module install "$ZIP"
else
  python3 -S "$REPO/tools/pty_install.py" su -c "ksud module install '$ZIP'"
fi
echo 'PASS_GUARDIAN_KSU_MODULE_INSTALL_RETURNED_SUCCESS'
if [ "$(id -u)" -eq 0 ]; then
  sh "$REPO/tools/upgrade_receipt.sh" post-install
else
  su -c "'/system/bin/sh' '$REPO/tools/upgrade_receipt.sh' post-install"
fi
# KernelSU normally stages under modules_update and requires a reboot.
# Do not confuse expected active-vs-staged differences with an installed bug.
python3 "$REPO/tools/runtime_parity.py"
echo 'Reboot manually to activate the updated module. Never automatically reboot from this workflow.'
