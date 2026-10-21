#!/bin/sh
# Explicit public publishing. Never triggered by build, tests or install.
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO"
NAME=${1:-lsposed-guardian}
case "$NAME" in ''|*[!a-zA-Z0-9._-]*) echo 'Use a simple GitHub repo name (letters/numbers/._-)' >&2;exit 2;; esac
command -v gh >/dev/null 2>&1 || { echo 'gh is not installed';exit 127; }
command -v git >/dev/null 2>&1 || { echo 'git is not installed';exit 127; }
gh auth status || exit 1
[ -d .git ] || { echo 'Initialize and commit locally before publishing';exit 2; }
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo 'No local commit; run git add/commit';exit 2; }
[ -z "$(git status --porcelain)" ] || { echo 'Working tree is dirty; commit or discard before publishing';exit 2; }
if git remote get-url origin >/dev/null 2>&1; then
  echo 'An origin remote already exists; refusing to publish over it.' >&2; exit 2
fi
echo "Creating PUBLIC GitHub repository: $(gh api user --jq .login)/$NAME"
gh repo create "$NAME" --public --source=. --remote=origin --push
gh repo view --json nameWithOwner,url,visibility --jq '{nameWithOwner,url,visibility}'
