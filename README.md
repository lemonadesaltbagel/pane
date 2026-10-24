# pane

Windows-style window management for macOS: a taskbar in place of the Dock, a Start menu, Windows snapping,
Alt+Tab between windows, and apps that quit when their last window closes.

pane is not affiliated with, endorsed by or sponsored by Microsoft. "Windows" is used only to describe the behaviour
pane brings to the Mac.

## What's here

This repository is pane's engine, under the GNU Affero General Public License, version 3 or any later version (see
`LICENSE`):

- **Windows and focus:** the window list, focus, Accessibility and WindowServer access.
- **Snapping:** edge drag, maximize, keyboard snapping and click-through.
- **The taskbar:** pins, grouping, badges and auto-hide, plus the Dock reservation that keeps the Dock out of its way.
- **Start:** search, Pinned, All apps and power.
- **Alt+Tab** with app icons, and **Show desktop**.
- **Settings and onboarding:** the Settings window and the welcome.
- **Apps:** quit on last window, with system settings backed up and restored.
- **Extension points:** `PaneExtension` and `PaneHost` (see `ENGINE-API.md`).

The official build, pane Pro, adds features through those extension points. Its code isn't in this repository.

## Build and run

You need macOS 14 or later (developed on macOS 26) and Swift 6. The Command Line Tools are enough; Xcode isn't needed.

```sh
swift build
.build/debug/pane            # run it from Terminal; Ctrl-C quits and restores everything
```

pane needs the **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility). When you run it
from Terminal, Terminal's grant covers it.

- **What pane changes:** while it runs it changes a few macOS settings (Dock size and position, edge tiling). It backs
  each one up first and restores it on quit, on Ctrl-C, or at the next start after a crash.
  `.build/debug/pane --restore-only` restores without starting.
- **More:** `TESTING.md` has everything about running and testing.

## Private APIs

pane uses some private macOS APIs (SkyLight / CoreGraphics Services, and `_AXUIElementGetWindow`) where public ones
can't do the job: focusing one window of an app, reading window lists across Spaces, telling desktops apart. None of
them needs System Integrity Protection turned off. Private APIs can change with any macOS update, and an app that uses
them can't go on the Mac App Store.

## Tests

```sh
scripts/test.sh --unit      # no windows, no permissions needed
scripts/test.sh             # everything: integration tests open test windows and take over the screen for a while
```

Integration tests only act on their own fixture app (`PaneFixture`) and on a copy of your settings. They never quit,
move or close your apps.

## Contributing

See `CONTRIBUTING.md`. Every contribution needs the contributor licence agreement (`CLA.md`), because pane's author
also ships pane in the official build.

## Licence

- **This repository:** GNU Affero General Public License, version 3 or any later version (`LICENSE`).
- **Credits:** third-party credits are in `NOTICE`.
