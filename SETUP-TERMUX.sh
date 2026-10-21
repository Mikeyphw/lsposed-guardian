#!/bin/sh
# Run only AFTER extracting Guardian's repository bundle into a temporary directory.
# Copies into ~/Code/lsposed-guardian without touching an existing checkout.
set -eu
SRC=${1:?Usage: SETUP-TERMUX.sh EXTRACTED_BUNDLE_DIRECTORY}
[ -d "$SRC/repo" ] || { echo 'ERROR: repo/ missing from extracted bundle' >&2;exit 2; }
[ -f "$SRC/PAYLOAD_SHA256SUMS.txt" ] || { echo 'ERROR: missing manifest' >&2;exit 2; }
( cd "$SRC" && sha256sum -c PAYLOAD_SHA256SUMS.txt ) >/dev/null || { echo 'ERROR: payload SHA-256 mismatch' >&2;exit 2; }
DEST="$HOME/Code/lsposed-guardian"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "ERROR: destination exists, preserving it: $DEST" >&2
  exit 3
fi
mkdir -p "$HOME/Code"
STAGE=$(mktemp -d "$HOME/Code/.lsposed-guardian.XXXXXX") || exit 1
DONE=0
cleanup() {
  [ "$DONE" = 1 ] || rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM
cp -a "$SRC/repo/." "$STAGE/"
chmod 755 "$STAGE/devtoolw" "$STAGE"/tools/*.sh
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "Destination appeared while copying; refusing to overwrite: $DEST" >&2
  exit 3
fi
mv "$STAGE" "$DEST"
DONE=1
cd "$DEST"
git init -b main
# No credentials stored, and nothing is published without ./tools/publish.sh.
git add -A
if git commit -m 'Initial Guardian v0.9.0 source with Devtool workflow integration'; then
  echo 'PASS_GUARDIAN_LOCAL_GIT_COMMIT'
else
  echo 'NOTE: local repository created but commit failed (configure git user.name/user.email, then commit).'
fi
echo "PASS_GUARDIAN_LOCAL_REPOSITORY: $DEST"
echo 'Run: cd ~/Code/lsposed-guardian'
echo 'Then: devtool -r . wrapper seal --json'
echo 'Then: ./devtoolw check'
echo 'To publish publicly: ./tools/publish.sh'
