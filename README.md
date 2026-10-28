<div align="center">

# pane

**Windows-style window management for the Mac.**

A taskbar in place of the Dock, a Start menu, Windows snapping, Alt+Tab between windows,
and apps that quit when their last window closes.

[![CI](https://github.com/lemonadesaltbagel/pane/actions/workflows/ci.yml/badge.svg)](https://github.com/lemonadesaltbagel/pane/actions/workflows/ci.yml)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

[Features](#features) · [Shortcuts](#shortcuts) · [Build and run](#build-and-run) · [Permissions](#permissions) · [Tests](#tests) · [Contributing](#contributing)

</div>

> [!NOTE]
> pane is not affiliated with, endorsed by or sponsored by Microsoft. "Windows" is used only to describe the
> behaviour pane brings to the Mac.

## Features

| | |
|---|---|
| 🪟 **Taskbar** | One button per window or per app, pinned apps, badges and attention, drag to reorder, auto-hide, the clock with its calendar, and show desktop at the far corner. The Dock stays out of its way, and comes back as it was when pane quits. |
| 🖥️ **Every display** | A taskbar on each display, with Windows' choice of which taskbar lists a window. Maximize and snaps use the display's own work area, and windows move between displays with their snap kept. Unplugging a display brings its windows home. |
| 🧲 **Snapping** | Drag to an edge or corner, with a preview. Title-bar double-click and the green button maximize, and keyboard snapping follows Windows' Win+Arrow rules. Edges shared between displays let the pointer through. |
| 🚀 **Start** | Search apps, Pinned, All apps as a grid or a list, your folders, and power (lock, sleep, restart, shut down) acting at once, as on Windows. |
| 🔀 **Alt+Tab** | A per-window switcher on ⌥Tab, most recent first. |
| ⛶ **Full screen** | Windows-style full screen on the current desktop (no separate Space), hiding only that display's taskbar. |
| 🚪 **Quit on last window** | Apps quit when their last window closes, with an opt-out list. |
| ⚙️ **Settings and welcome** | Every option in a Settings window, a first-run welcome, a check for other apps that do the same job, and an update check. |
| 🧩 **Extension points** | `PaneExtension` and `PaneHost`, for features built on the engine (see [`ENGINE-API.md`](ENGINE-API.md)). |

This repository is pane's engine. The official build, pane Pro, adds features through those extension points. Its
code isn't in this repository.

## Shortcuts

The Mac keyboard keeps every macOS shortcut and adds these. Each one can be changed in Settings ▸ Keyboard.

| Action | Keys |
|---|---|
| Start | tap ⌘ |
| Switch windows | ⌥ Tab |
| Snap left / right | ⌃ ⌥ ← / → |
| Maximize / restore or minimize | ⌃ ⌥ ↑ / ↓ |
| Move window to the next / previous display | ⌃ ⌥ ⌘ → / ← |
| Full screen | ⌃ ⌘ F |
| Close window | ⌥ F4 |
| pane Settings | ⌃ ⌘ I |

## Build and run

pane runs on **macOS 14 or later** (developed on macOS 26). Building needs **Swift 6** and the **macOS 26 SDK**:
the Command Line Tools for macOS 26 are enough, or Xcode 26.

```sh
swift build
.build/debug/pane            # from Terminal; Ctrl-C quits and restores everything
```

<details>
<summary><b>As a Mac app</b></summary>

```sh
scripts/make-app.sh          # builds .build/app/pane.app (ad-hoc signed, for trying pane as an app)
open .build/app/pane.app
```

It runs without a Dock icon, and you quit it from its menu-bar icon. `pane --report <file>` writes what macOS lets
that copy of pane do: its permissions, its login item and its version.

</details>

<details>
<summary><b>What pane changes on your Mac, and how it puts it back</b></summary>

While it runs, pane changes a few macOS settings: the Dock's size and position (so it sits under the taskbar), and
edge tiling (so pane's snapping works). It backs each one up first. It restores them when it quits, on Ctrl-C, on a
logout, or at the next start after a crash. `.build/debug/pane --restore-only` restores without starting.

</details>

## Permissions

pane needs one permission: **Accessibility** (System Settings ▸ Privacy & Security ▸ Accessibility). Every window and
keyboard behaviour goes through it, so pane waits until it's granted. Run from Terminal, pane is covered by Terminal's
grant. As an app, macOS asks for pane itself.

<details>
<summary><b>Private APIs</b></summary>

pane uses some private macOS APIs (SkyLight / CoreGraphics Services, and `_AXUIElementGetWindow`) where public ones
can't do the job: focusing one window of an app, reading window lists across Spaces, telling desktops apart. None of
them needs System Integrity Protection turned off. Private APIs can change with any macOS update, and an app that uses
them can't go on the Mac App Store.

</details>

## Tests

```sh
scripts/test.sh --unit      # no windows, no permissions needed (what CI runs)
scripts/test.sh             # everything: test windows open, and the screen is busy for a while
```

Integration tests act only on their own fixture app and on a copy of your settings. They never quit, move or close
your apps. Tests about multiple displays add a virtual display for a moment, so no second monitor is needed. More in
[`TESTING.md`](TESTING.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Every contribution needs the contributor licence agreement
([`CLA.md`](CLA.md)), because pane's author also ships pane in the official build.

## Licence

pane's engine is licensed under the [GNU Affero General Public License, version 3 or any later version](LICENSE).
Third-party credits are in [`NOTICE`](NOTICE).
