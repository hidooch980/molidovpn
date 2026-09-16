#!/usr/bin/env bash
set -euo pipefail
# One-time setup: turns THIS folder into a GitHub repo, pushes it and starts the first run.
# Prereqs: git + GitHub CLI, then: gh auth login && bash setup.sh [repo-name]

REPO_NAME="${1:-vpn-sub}"
cd "$(dirname "$0")"

gh auth status >/dev/null 2>&1 || { echo "Not logged in. Run: gh auth login"; exit 1; }

if [ ! -d .git ]; then
  git init -q -b main
fi
git add -A
git diff --cached --quiet || git commit -q -m "vpn config aggregator"

if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO_NAME" --public --source=. --remote=origin --push
else
  git push -u origin main
fi

OWNER=$(gh api user --jq .login)
echo "==> Enabling workflow and triggering first run..."
sleep 5
gh workflow enable update.yml -R "$OWNER/$REPO_NAME" >/dev/null 2>&1 || true
gh workflow run update.yml -R "$OWNER/$REPO_NAME" || echo "  Run it once manually from the Actions tab."

echo
echo "Subscription links (ready a few minutes after the run finishes):"
for f in sub_base64.txt sub.txt fastest.txt singbox.json; do
  echo "  https://raw.githubusercontent.com/$OWNER/$REPO_NAME/sub/$f"
done
