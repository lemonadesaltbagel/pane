#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 lemonadesaltbagel
# Builds PanePreview and installs it as ~/Library/Application Support/Pane/PanePreview.app.
#
# The app is ad-hoc signed, and macOS ties its Screen Recording grant to the code hash, so this script only
# replaces the installed binary when it actually changed (otherwise the grant you gave would be lost).
# After the first install, launch it once and allow it in
# System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.
set -euo pipefail
cd "${0:A:h}/.."

swift build --product PanePreview --quiet
built=.build/debug/PanePreview
app="$HOME/Library/Application Support/Pane/PanePreview.app"
installed="$app/Contents/MacOS/PanePreview"

if [[ -f "$installed" ]] && cmp -s "$built" "$installed"; then
  echo "PanePreview unchanged — keeping the installed (granted) copy."
  exit 0
fi

pkill -x PanePreview 2>/dev/null || true
mkdir -p "$app/Contents/MacOS"
cp "$built" "$installed"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.pane.preview</string>
  <key>CFBundleName</key><string>PanePreview</string>
  <key>CFBundleExecutable</key><string>PanePreview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "Installed $app (new code hash: re-allow Screen Recording if it was granted before)."
