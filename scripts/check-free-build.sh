#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 lemonadesaltbagel
# O5 (research/plan-open-core.md): the Free build (`pane`) contains none of pane Pro.
#
#   scripts/check-free-build.sh [--release]
#
# Checks the `pane` binary for:
#   1. symbols from the PanePro module, and the names of the types PanePro declares;
#   2. pane Pro's setting and shortcut ids, and its license strings.
# Pro's names are read from Sources/PanePro (absent in the public repo: then only the module check runs).
set -euo pipefail # (grep -q reads here-strings: in a pipe it would end the writer early, failing under pipefail)
cd "${0:A:h}/.."

config=debug
[[ "${1:-}" == "--release" ]] && config=release
swift build -c $config --product pane > .build/check-free-build.log 2>&1 || { cat .build/check-free-build.log; exit 1; }
binary=.build/$config/pane
pro=Sources/PanePro
failures=0

symbols=$(nm "$binary" | xcrun swift-demangle)
if grep -q "PanePro\." <<< "$symbols"; then
  echo "✘ PanePro symbols in $binary:"; print -r -- "$symbols" | grep "PanePro\." | head -10; failures=$((failures + 1))
else
  echo "✔ no PanePro module symbols"
fi

if [[ -d $pro ]]; then
  types=(${(f)"$(grep -hoE '^(public |@MainActor |final |private |fileprivate )*(class|struct|enum|protocol|actor) [A-Z][A-Za-z0-9]+' $pro/*.swift | awk '{print $NF}' | sort -u)"})
  found=()
  for t in $types; do
    grep -qE "(^|[^A-Za-z0-9])$t([^A-Za-z0-9]|$)" <<< "$symbols" && found+=$t
  done
  if (( ${#found} )); then echo "✘ Pro types in $binary: $found"; failures=$((failures + 1)); else echo "✔ none of Pro's ${#types} types"; fi

  # Setting ids ("tray.hideMenuBarIcons"…), shortcut ids (keys.taskView…), and the license format.
  ids=(${(f)"$(grep -hoE 'Setting(<[^>]*>)?\("[a-zA-Z]+\.[a-zA-Z]+"' $pro/*.swift | grep -oE '"[^"]+"' | tr -d '"' | sort -u)"})
  ids+=(${(f)"$(grep -hoE 'Shortcut\("[a-zA-Z]+"' $pro/*.swift | grep -oE '"[^"]+"' | tr -d '"' | sed 's/^/keys./' | sort -u)"})
  ids+=("PANE-" "license.json")
  text=$(strings -a "$binary")
  leaked=()
  for id in $ids; do grep -qF -- "$id" <<< "$text" && leaked+=$id; done
  if (( ${#leaked} )); then echo "✘ Pro strings in $binary: $leaked"; failures=$((failures + 1)); else echo "✔ none of Pro's ${#ids} setting, shortcut and license strings"; fi
fi

(( failures == 0 )) && echo "Free build is clean ($binary)" || { echo "$failures check(s) failed"; exit 1; }
