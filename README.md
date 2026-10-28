<div align="center">

# pane

**Windows-style window management for the Mac.**

A taskbar in place of the Dock, a Start menu, snapping, Alt+Tab between windows,<br>
and apps that quit when their last window closes.

[![CI](https://github.com/lemonadesaltbagel/pane/actions/workflows/ci.yml/badge.svg)](https://github.com/lemonadesaltbagel/pane/actions/workflows/ci.yml)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://lemonadesaltbagel.github.io/assets/readme/pane-dark.png">
  <img src="https://lemonadesaltbagel.github.io/assets/readme/pane-light.png" width="880" alt="A Mac running pane: three windows snapped into a layout above pane's taskbar">
</picture>

<sub>Try it in your browser at <a href="https://lemonadesaltbagel.github.io">lemonadesaltbagel.github.io</a>: the page works like pane.</sub>

</div>

<br>

## Features

| Feature | What it does |
|---|---|
| **Taskbar** | One button per window or per app, pinned apps, badges and attention, drag to reorder, auto-hide, a clock with its calendar, and show desktop at the far corner. The Dock stays out of the way, and comes back as it was when pane quits. |
| **Every display** | A taskbar on each display, which lists windows the way Windows does. Maximize and snaps use each display's own work area, and windows keep their snap when they move between displays. Unplugging a display brings its windows home. |
| **Snapping** | Drag a window to an edge or a corner and see where it lands. Title-bar double-click and the green button maximize, and keyboard snapping follows Windows' Win+Arrow rules. Edges shared between displays let the pointer through. |
| **Start** | Tap <kbd>⌘</kbd>. Search apps, keep favourites in Pinned, browse All apps as a grid or a list, and lock, sleep, restart or shut down at once, as on Windows. |
| **Alt+Tab** | <kbd>⌥</kbd> <kbd>Tab</kbd> steps through every window, most recent first, not every app. |
| **Full screen** | Windows-style full screen on the desktop you're on, with no separate Space. Only that display's taskbar hides. |
| **Quit on last window** | An app quits when its last window closes, with a list of apps to keep open. |
| **Settings and welcome** | Every option in a Settings window, a first-run welcome, a check for other apps that do the same jobs, and an update check. |
| **Extension points** | `PaneExtension` and `PaneHost`, for features built on the engine. See [`ENGINE-API.md`](ENGINE-API.md). |

This repository is pane's engine. The official build, pane Pro, adds more through those extension points, such as
live previews, virtual desktops and Snap Layouts. Its code isn't in this repository; the
[website](https://lemonadesaltbagel.github.io/#editions) compares the two.

## Shortcuts

pane keeps every macOS shortcut and adds these. Each one can be changed in Settings ▸ Keyboard.

| Action | On Windows | With pane |
|---|---|---|
| Open Start | Win | tap <kbd>⌘</kbd> |
| Switch windows | Alt+Tab | <kbd>⌥</kbd> <kbd>Tab</kbd> |
| Snap left or right | Win+← / → | <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>←</kbd> or <kbd>→</kbd> |
| Maximize, or restore and minimize | Win+↑ / ↓ | <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>↑</kbd> or <kbd>↓</kbd> |
| Move a window to another display | Win+Shift+← / → | <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>←</kbd> or <kbd>→</kbd> |
| Full screen | F11 | <kbd>⌃</kbd> <kbd>⌘</kbd> <kbd>F</kbd> |
| Close the window | Alt+F4 | <kbd>⌥</kbd> <kbd>F4</kbd> |
| pane Settings | Win+I | <kbd>⌃</kbd> <kbd>⌘</kbd> <kbd>I</kbd> |

## Build and run

pane runs on **macOS 14 or later** (developed on macOS 26). Building needs **Swift 6** and the **macOS 26 SDK**: the
Command Line Tools for macOS 26 are enough, or Xcode 26.

```sh
swift build
.build/debug/pane            # from Terminal; Ctrl-C quits and restores everything
```

<details>
<summary><b>As a Mac app</b></summary>
<br>

```sh
scripts/make-app.sh          # builds .build/app/pane.app (ad-hoc signed, for trying pane as an app)
open .build/app/pane.app
```

It runs without a Dock icon, and you quit it from its menu-bar icon. `pane --report <file>` writes what macOS lets
that copy of pane do: its permissions, its login item and its version.

</details>

<details>
<summary><b>What pane changes on your Mac, and how it puts it back</b></summary>
<br>

While it runs, pane changes a few macOS settings: the Dock's size and position (so it sits under the taskbar), and
edge tiling (so pane's snapping works). It backs each one up first, and restores them when it quits, on Ctrl-C, on a
logout, or at the next start after a crash. `.build/debug/pane --restore-only` restores without starting.

</details>

## Permissions

pane needs one permission: **Accessibility** (System Settings ▸ Privacy & Security ▸ Accessibility). Every window and
keyboard behaviour goes through it, so pane waits until it's granted. Run from Terminal, pane is covered by Terminal's
grant. As an app, macOS asks for pane itself.

<details>
<summary><b>Private APIs</b></summary>
<br>

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

pane isn't affiliated with, endorsed by or sponsored by Microsoft. "Windows" describes the behaviour pane brings to
the Mac.
