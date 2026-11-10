#!/bin/bash
# Points this clone (and its worktrees) at the hooks in scripts/git-hooks. Run once per clone.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/git-hooks
echo "git hooks: on (pre-commit, commit-msg, pre-push in scripts/git-hooks)"
