#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 lemonadesaltbagel
# Builds a local app bundle around a pane agent, to run pane as an app: an agent Info.plist (no Dock icon), the
# preview helper inside, an ad-hoc signature. It's for trying and testing pane as an app; it doesn't sign for release,
# notarize or install anything.
#
#   scripts/make-app.sh [--release] [--version 0.1.0] [--product pane] [--name pane] [--bundle-id dev.pane.app]
#                       [--package DIR] [--out DIR]
#
# --package builds another package's product (an extension's agent); the app lands in DIR/.build/app/<name>.app.
# PANE_SIGN_IDENTITY signs with that identity instead of ad hoc. macOS ties privacy grants (Accessibility, Screen
# Recording) to an ad-hoc signature's code hash, so files are only replaced when they changed: a rebuild without
# changes keeps the signature, and the grants with it.
set -euo pipefail
engine=${0:A:h:h}
product=pane name=pane bundle_id=dev.pane.app config=debug package=$engine out="" version=0.1.0
while (( $# )); do
  case $1 in
    --release) config=release; shift ;;
    --version) version=$2; shift 2 ;;
    --product) product=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --bundle-id) bundle_id=$2; shift 2 ;;
    --package) package=${2:A}; shift 2 ;;
    --out) out=${2:A}; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
out=${out:-$package/.build/app}
identity=${PANE_SIGN_IDENTITY:--}

(cd $package && swift build -c $config --product $product --quiet && swift build -c $config --product PanePreview --quiet)
bin=$package/.build/$config
app=$out/$name.app
helper=$app/Contents/Helpers/PanePreview.app
changed=0

# Copies `from` to `to` only when it differs.
place() {
  local from=$1 to=$2
  if [[ -f $to ]] && cmp -s $from $to; then return; fi
  mkdir -p ${to:h}
  cp $from $to
  changed=1
}

plist() { # bundle id, name, executable, version, extra keys
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$4</string>
  <key>CFBundleVersion</key><string>$4</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
$5
</dict></plist>
PLIST
}

tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

# The helper first (it's signed before the app that contains it).
plist dev.pane.preview PanePreview PanePreview 1.0 "" > $tmp/helper.plist
place $bin/PanePreview $helper/Contents/MacOS/PanePreview
place $tmp/helper.plist $helper/Contents/Info.plist
helper_changed=$changed

usage='  <key>NSAppleEventsUsageDescription</key><string>pane restarts, shuts down or logs out the Mac when you choose that in Start.</string>'
plist $bundle_id $name $product $version $usage > $tmp/app.plist
place $bin/$product $app/Contents/MacOS/$product
place $tmp/app.plist $app/Contents/Info.plist

if (( changed )) || ! codesign --verify --deep --strict $app 2>/dev/null; then
  if (( helper_changed )) || ! codesign --verify --strict $helper 2>/dev/null; then
    codesign --force --sign $identity --timestamp=none $helper
  fi
  codesign --force --sign $identity --timestamp=none $app
  echo "Built $app (new signature: grant Accessibility and Screen Recording again if they were granted before)."
else
  echo "Built $app (unchanged: the signature and its grants are kept)."
fi
codesign --verify --deep --strict $app
