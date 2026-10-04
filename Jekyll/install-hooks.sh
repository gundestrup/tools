#!/bin/bash
# Drop-in hook enabler — copy to <repo>/bin/install-hooks.sh with the
# companion hooks/ dir -> <repo>/bin/hooks/. Run once after cloning.
#
# Hooks live in bin/hooks/ as TRACKED files and git is pointed at them
# via core.hooksPath — no copying, so the installed hooks can never
# drift from the committed ones. This supersedes the older pattern of
# generating hooks into .git/hooks (which drifted — see
# lessons-learned).
#
# Adjust the echo lines to describe your actual gates.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

git -C "$REPO_ROOT" config core.hooksPath bin/hooks

echo "✅ Git hooks enabled (core.hooksPath=bin/hooks):"
echo "   pre-commit:  rubocop + semgrep (fast)"
echo "   pre-push:    rake quick (full quality gate)"
echo ""
echo "   Skip with: git commit --no-verify  /  git push --no-verify"
