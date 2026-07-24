#!/usr/bin/env bash
# Create/push the public GitHub repo using CLI auth.
# Auth options (pick one):
#   1) Device code:  gh auth login --hostname github.com --git-protocol ssh --web
#   2) Token:        printf '%s\n' "$GH_TOKEN" | gh auth login --with-token
#   3) After SSH-only push: create empty public repo on GitHub, then:
#        git remote add origin git@github.com:USER/privet.git && git push -u origin master
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
cd "$ROOT"

if ! gh auth status >/dev/null 2>&1; then
  echo "Not logged in. Starting device-code login (CLI)..."
  echo "Open https://github.com/login/device and enter the code printed below."
  gh auth login --hostname github.com --git-protocol ssh --web
fi

USER_LOGIN="$(gh api user --jq .login)"
REPO_NAME="${PRIVET_GITHUB_REPO:-privet}"
FULL="${USER_LOGIN}/${REPO_NAME}"

if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "Repo exists: https://github.com/$FULL"
else
  gh repo create "$REPO_NAME" --public --source=. --remote=origin --description "Privet messenger — web, Linux, Windows"
fi

git remote remove origin 2>/dev/null || true
git remote add origin "git@github.com:${FULL}.git" 2>/dev/null || git remote set-url origin "git@github.com:${FULL}.git"
git push -u origin HEAD:master

echo "Public repo: https://github.com/${FULL}"
echo "To publish desktop installers: git tag v0.1.0 && git push origin v0.1.0"
