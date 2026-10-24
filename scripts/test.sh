#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 lemonadesaltbagel
# Runs pane's local test suite.
#
#   scripts/test.sh              unit + integration (integration launches fixture windows and takes focus ~1 min)
#   scripts/test.sh --unit       unit/environment tests only (no windows)
#   scripts/test.sh --filter X   any Swift Testing filter
#
# Needs Accessibility for your terminal (System Settings ▸ Privacy & Security ▸ Accessibility).
# Screen Recording is optional (enables the thumbnail test). Findings go to test-results/findings.md.
set -euo pipefail
cd "${0:A:h}/.."

# Integration runs take over the screen, keyboard and mouse, and start pane agents: never two at once.
if pgrep -f "\.build/debug/pane-tests" >/dev/null || pgrep -f "\.build/(debug|release)/pane(-pro|-dev)?( |$)" >/dev/null; then
  echo "another test run or pane agent is running; stop it first" >&2
  exit 3
fi

swift build --quiet
runners=(pane-tests)
if [[ "${1:-}" == "--unit" ]]; then
  shift
  export PANE_SKIP_INTEGRATION=1
fi
result=0
for runner in $runners; do
  [[ -x .build/debug/$runner ]] || continue
  echo "== $runner"
  .build/debug/$runner "$@" || result=$?
done
exit $result
