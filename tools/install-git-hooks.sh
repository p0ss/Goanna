#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Point this checkout's git hooks at tools/git-hooks, so the commit message
# rules in docs/style.md are checked at commit time. Worktrees share the
# setting. Undo with: git config --unset core.hooksPath
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac
cd "$(dirname "$0")/.."
git config core.hooksPath tools/git-hooks
echo "core.hooksPath set to tools/git-hooks"
