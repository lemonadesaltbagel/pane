# Running and testing pane

## Run the agent

```sh
swift build
.build/debug/pane                     # run from Terminal (its Accessibility grant covers pane); Ctrl-C quits
.build/debug/pane                     # again, while it runs: opens Settings (the second process exits)
.build/debug/pane --open-settings taskbar          # a Settings page; also "search:hide taskbar"
.build/debug/pane --restart           # restart the running pane (a handover: the Dock doesn't flicker)
.build/debug/pane --dry-run           # don't touch system settings (Dock / native tiling stay as they are)
.build/debug/pane --lifecycle-scope com.example.App   # only ever auto-quit this app (repeatable; tests)
.build/debug/pane --restore-only      # put back settings (and any parked windows) left by a crashed run, then exit
```

**First run:**
- **Steps:** a welcome, then Accessibility, other apps, what pane changes, and start at login.
- **Without Accessibility,** pane stays up and starts by itself when it's granted.
- **To see the welcome again:** Settings ▸ Advanced ▸ *Show welcome again*.

**Settings:** open them by starting pane again, with ⌃⌘I, from pane's menu-bar icon, or by right-clicking the taskbar
▸ *Taskbar settings*.
- They live in `~/Library/Application Support/Pane/config.json`. The format is version 2:
  `{"version": 2, "settings": {id: value}, "apps": {bundle: {id: value}}}`; the ids are in `ENGINE-API.md`.
- Hand edits apply while pane runs. Settings marked "After restart" show a *Restart pane* bar.

**What pane changes** while it runs. Each change has an off switch in Settings and onboarding. Every value is backed up
first in `~/Library/Application Support/Pane/system-settings-backup.plist`, and restored on quit, Ctrl-C, SIGTERM, or
the next launch after a crash.
- **The Dock:** small, no magnification, at the bottom, so it sits exactly under the 48 pt taskbar. With auto-hide, it
  hides.
- **macOS edge tiling:** off.
- **⌘Tab:** pane's while it runs, with "⌘Tab opens pane's switcher".
- **The Dock's pinned apps:** changed only with "Sync pinned apps with the macOS Dock".

**Window previews:**
1. Run `scripts/install-preview-helper.sh` once.
2. Allow **PanePreview** in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.

The script won't replace the installed helper unless its code changed, so the grant survives rebuilds. pane starts the
helper itself.

**Keyboard:**
- **Mac shortcuts:** pane keeps every macOS shortcut.
  - Snap: ⌃⌥←/→ halves, ⌃⌥↑ maximize, ⌃⌥↓ restore or minimize.
  - Start: tap ⌘.
  - Menu mode: tap ⌥, then a letter.
  - Settings: ⌃⌘I.
- **Everywhere:**
  - Alt+Tab is ⌥Tab, and Alt+F4 is ⌥F4.
  - ⌃⌘F is full screen on the current desktop.
- **Rebinding:** every shortcut can be rebound in Settings ▸ Keyboard; *Restore Mac shortcuts* puts the Mac set back.

**Start:**
- Tap ⌘ or click Start for pane's Windows 11 Start: search, Pinned, Recent, All, account and power.
- Settings ▸ Start chooses "macOS Apps" instead.
- Test agents use `PANE_START_FILE`, `PANE_FAKE_POWER` and `PANE_START_APP_ROOTS`.

## Tests

Integration tests launch **PaneFixture**, a small AppKit app from `Sources/PaneFixture`. They drive it only through
Accessibility and the WindowServer, the way pane drives any app. Tests never touch your own apps, with two exceptions:
- **The taskbar and takeover suites** temporarily change the Dock and tiling settings, with backup and restore. A
  crashed run is restored by the next one.
- **`pane-probe realapps`** opens and closes throwaway windows in Finder, Edge and VS Code.

```sh
scripts/test.sh            # everything (~10 min; fixture windows appear, the mouse moves, keys are synthesized)
scripts/test.sh --unit     # pure logic + environment checks only, no windows
scripts/test.sh --filter SwitcherTests
scripts/check-free-build.sh   # the build contains nothing but the engine
```

Measured behavior (not just pass/fail) is written to `test-results/findings.md` on every run.

**Test isolation:**
- **Config:** test agents run on a copy of your config (`PANE_CONFIG` → `$TMPDIR/pane-test-config.json`).
- **Defaults and status items:** test agents use their own defaults (`PANE_DEFAULTS_SUITE`) and `PaneTest…`
  status-item names.
- **Login items:** test agents never touch yours, unless a test points `PANE_LAUNCH_AGENTS_DIR` at its own folder.
- **Power:** a test agent never sleeps, restarts or shuts down the Mac (`PANE_FAKE_POWER` logs the action instead).
- **Welcome:** it shows in a test agent only with `PANE_ONBOARDING=1`.
- **Permissions:** faked with `PANE_FAKE_PERMISSIONS_FILE` (`accessibility=missing`).
- **Conflicting apps:** `PANE_EXTRA_CONFLICTS` makes the fixture count as a conflicting app.
- **Pictures:** captures of the Settings pages and onboarding steps go to `test-results/previews/` (they need the
  preview helper).
- **The shared harness:** `Tests/PaneTestKit` holds the fixture, polling, findings, the integration root, and
  launching a test agent (`ENGINE-API.md`, Testing support).

### Requirements

| | |
|---|---|
| Accessibility for your terminal | **required** for integration tests (System Settings ▸ Privacy & Security ▸ Accessibility) |
| Screen Recording | optional; enables the thumbnail tests and `kCGWindowName` |
| Toolchain | Command Line Tools are enough. Tests use Swift Testing through an executable runner (`pane-tests`), because with CLT only SwiftPM doesn't generate a Swift Testing entry point for `swift test`. The runner hosts the tests inside `NSApp.run()`, because SkyLight window notifications are only delivered through an AppKit event loop |
| While it runs | don't use the Mac. Fixture windows are activated and raised, the **mouse moves and clicks**, and **keys are synthesized**. The suite releases any modifier key it leaves held and fails if one is still down |

**Spaces:** `kAXWindows` omits windows on Spaces that aren't shown. The fixture harness fronts windows by WindowServer
id to switch Spaces when needed, so runs work from fullscreen Spaces too.

### Suites

| Suite | What it proves |
|---|---|
| Geometry, Placement, Lifecycle policy, Snap zones, Snap transitions, Taskbar layout, Menu mnemonics, Start menu search, Settings, System settings | Pure logic (and settings backup/restore on a throwaway domain) |
| Environment | Permissions granted; private symbols present on this macOS |
| 1 · Per-window activation | Only the target window comes forward (public vs SkyLight; minimized; across Spaces) |
| 2 · Quit on last window | Close detection per signal; no false positives (palettes, minimized, other Spaces) |
| 3 · Per-window controls | AX buttons, minimize/restore, Alt+F4, AX menu bar |
| 4 / 4b · Maximize, snap, mouse | Exact frames; native behaviors vs pane's MouseTap overrides |
| 5 / 6 · Taskbar inventory, instances | AX↔WindowServer mapping, tabs, `open -n`, background "New Window" |
| 7 / 7b · Keyboard | Taps, hotkeys, Win+Arrow, Alt+F4, lone ⌘/⌥ taps |
| M0 · Window inventory | Live list across open/close/minimize/tabs/other Spaces; push latency |
| M1 · Native tiling takeover, Services | Live pref effect; SnapService (drag preview, unsnap, Win+Arrow), HotkeyService, LifecycleService (opt-out, ⌘H) |
| M2 · Taskbar | Dock reservation = bar height, native Fill respects it, panel level/Spaces, clicks, middle-click |
| M3 · Switcher | ⌥Tab MRU cycling, commit on release, Esc, precedence over AltTab |
| Taskbar grouping | One button per app, the pop-up (a list of titles without thumbnails), ⌃-click cycle, group menu, hover |
| Click-through | Native scroll/first-click behavior; pane's click-through (one click acts, drags, ⌘-click, title bar) |
| Previews (helper) | Visible and minimized window captures via PanePreview (images saved to `test-results/previews/`) |
| Windows full screen, Full-screen taskbar | Fill below the menu bar, taskbar/Dock out of the way while focused, exact restore; taskbar click into a macOS full-screen window |
| Start menu | The panel, search, Recent, the bottom bar and power (faked), looks |
| Settings window, Onboarding, Settings · honoured | Every page and control by id, live and restart settings, the welcome's steps |
| E2E · pane agent | The real agent process: reservation, taskbar click, drag snap, quit-on-last-window, restore on exit |

### pane-probe

```sh
pane-probe perms
pane-probe list --bundle com.apple.TextEdit     # AX vs WindowServer windows (+ Spaces) + lifecycle decision
pane-probe zorder
pane-probe focus <pid> "<title>" [publicActivate|axFrontmost|skyLight]
pane-probe focus-wid <pid> <wid>
pane-probe snap <pid> "<title>" maximize|leftHalf|…
pane-probe minimize|unminimize <pid> "<title>"
pane-probe watch <pid> [seconds]                 # AX notifications and detected open/close
pane-probe watch-ws <pid> [seconds]              # SkyLight window notifications
pane-probe press <pid> "File>New Window"         # press a menu item through AX
pane-probe survey                                # read-only: how pane's rules see every running app
pane-probe menu-survey                           # read-only: menu-bar fidelity per app
pane-probe realapps [bundleID]                   # throwaway windows in Finder/Edge/VS Code: snap, focus, close
pane-probe noise SECONDS X Y W H [--clicks] [--scroll]   # plays an active user inside a rectangle
```

The research behind the engine is in `docs/research/`.
