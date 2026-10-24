# Running and testing pane

## Run the agent

```sh
swift build
.build/debug/pane                     # run from Terminal (its Accessibility grant covers pane); Ctrl-C quits
.build/debug/pane                     # again, while it runs: opens Settings (the second process exits)
.build/debug/pane --open-settings taskbar          # a Settings page; also "search:aero shake"
.build/debug/pane --restart           # restart the running pane (a handover: the Dock doesn't flicker)
.build/debug/pane --dry-run           # don't touch system settings (Dock / native tiling stay as they are)
.build/debug/pane --lifecycle-scope com.example.App   # only ever auto-quit this app (repeatable)
.build/debug/pane --desktop-scope com.example.App     # virtual desktops manage only this app's windows (tests; repeatable)
.build/debug/pane --restore-only      # put back settings (and parked windows) left by a crashed run, then exit
```

## Tests

Integration tests launch **PaneFixture** (a small AppKit app from `Sources/PaneFixture`) and drive it only through Accessibility and the WindowServer, the way pane drives any app. Tests never touch your own apps, with two exceptions:
- The taskbar and takeover suites temporarily change the Dock and tiling settings, with backup and restore. A crashed run is restored by the next one.
- `pane-probe realapps` opens and closes throwaway windows in Finder, Edge and VS Code.

```sh
scripts/test.sh            # everything (~16 min, 263 tests; fixture windows appear, the mouse moves, keys are synthesized)
scripts/test.sh --unit     # pure logic + environment checks only, no windows
scripts/test.sh --filter SwitcherTests
```

Measured behavior (not just pass/fail) is written to `test-results/findings.md` on every run.

**Test isolation:**
- **Config:** test agents run on a copy of your config (`PANE_CONFIG` → `$TMPDIR/pane-test-config.json`).
- **Defaults and status items:** test agents use their own defaults (`PANE_DEFAULTS_SUITE`) and `PaneTest…` status-item names.
- **Login items:** test agents never touch yours, unless a test points `PANE_LAUNCH_AGENTS_DIR` at its own folder.
- **Welcome:** it shows in a test agent only with `PANE_ONBOARDING=1`.
- **Permissions:** faked with `PANE_FAKE_PERMISSIONS_FILE` (`accessibility=missing`).
- **Conflicting apps:** `PANE_EXTRA_CONFLICTS` makes the fixture count as a conflicting app.
- **Pictures:** captures of the Settings pages and onboarding steps go to `test-results/previews/` (they need the preview helper).

**Soak (long run, off by default):**

```sh
PANE_SOAK_MINUTES=180 PANE_SOAK_SEED=7 scripts/test.sh --filter soak   # live log: test-results/soak.md
PANE_STRESS=1 scripts/test.sh --filter desktopChordsLeaveNoModifierHeld  # 150 desktop chords, modifier check
```

- The soak drives the real agent with seeded random actions on fixture apps:
  - launch, ⌘N, close, minimize;
  - focus, including parked windows;
  - desktop chords, ⌃⌘F, ⌥F4;
  - tray overflow, idle.
- It checks invariants after every step and measures idle CPU and memory every 10 minutes.
- At the end it checks that everything is restored and that your own windows didn't move.
- Keys that act on a window are only sent while a fixture is frontmost.
- The agent runs with `--desktop-scope` and `--lifecycle-scope` set to the fixture, so your apps are never parked or quit.
- Same seed means the same action sequence.

### Requirements

| | |
|---|---|
| Accessibility for your terminal | **required** for integration tests (System Settings ▸ Privacy & Security ▸ Accessibility) |
| Screen Recording | optional; enables the thumbnail test, `kCGWindowName`, and (later) tray icons |
| Toolchain | Command Line Tools are enough. Tests use Swift Testing through an executable runner (`pane-tests`), because with CLT only SwiftPM doesn't generate a Swift Testing entry point for `swift test`. The runner hosts the tests inside `NSApp.run()`, because SkyLight window notifications are only delivered through an AppKit event loop |
| While it runs | don't use the Mac. Fixture windows are activated and raised, the **mouse moves and clicks**, and **keys are synthesized**. The suite releases any modifier key it leaves held and fails if one is still down |

**Spaces:** `kAXWindows` omits windows on Spaces that aren't shown. The fixture harness fronts windows by WindowServer id to switch Spaces when needed, so runs work from fullscreen Spaces too.

### Suites

| Suite | What it proves |
|---|---|
| Geometry, Placement, Lifecycle policy, Snap zones, Snap transitions, Snap layouts, Taskbar layout, Menu mnemonics, Start menu search, System settings | Pure logic (and settings backup/restore on a throwaway domain) |
| Environment | Permissions granted; private symbols present on this macOS |
| 1 · Per-window activation | Only the target window comes forward (public vs SkyLight; minimized; across Spaces) |
| 2 · Quit on last window | Close detection per signal; no false positives (palettes, minimized, other Spaces) |
| 3 · Per-window controls | AX buttons, minimize/restore, Alt+F4, AX menu bar |
| 4 / 4b · Maximize, snap, mouse | Exact frames; native behaviors vs pane's MouseTap overrides |
| 5 / 6 · Taskbar inventory, instances | AX↔WindowServer mapping, tabs, thumbnails, `open -n`, background "New Window" |
| 7 / 7b · Keyboard | Taps, hotkeys, Win+Arrow, Alt+F4, lone ⌘/⌥ taps |
| M0 · Window inventory | Live list across open/close/minimize/tabs/other Spaces; push latency |
| M1 · Native tiling takeover, Services | Live pref effect; SnapService (drag preview, unsnap, Win+Arrow), HotkeyService, LifecycleService (opt-out, ⌘H) |
| M2 · Taskbar | Dock reservation = bar height, native Fill respects it, panel level/Spaces, clicks, middle-click |
| M3 · Switcher | ⌥Tab MRU cycling, commit on release, Esc, precedence over AltTab |
| M4 · Tray | Extras via AX (incl. hidden), open + pick item, taskbar tray area |
| M5 · Per-window menus | Mirror + run items for background windows, strip tracking/z-order, Alt mode with and without strips |
| Taskbar grouping | One button per app, pop-up with live previews, ⌃-click cycle, group menu, hover |
| M4 · Tray, M4b experiments | Divider hides icons; ^ overflow; rebuilt menu at the tray; reveal-and-press; promote/demote |
| Click-through, Experiments · inactive window input | Native scroll/first-click behavior; pane's click-through (one click acts, drags, ⌘-click, title bar) |
| Experiments · tray pop-up position, popover, Control Center module | Where hidden items' menus/popovers/panels open and that pane lands them above the tray |
| Previews (helper) | Visible and minimized window previews via PanePreview (images saved to `test-results/previews/`) |
| Windows full screen, Full-screen taskbar | Fill below the menu bar, taskbar/Dock out of the way while focused, exact restore; taskbar click into a macOS full-screen window |
| Virtual desktop model, Virtual desktops | Desktop rules (new/close/move/plan); parking, exact restore, focus follow, crash recovery, 30-window switch time, full-screen Spaces never managed |
| Experiments · window parking, Windows full screen | How far AppKit lets a window go off-screen; menu bar/Dock clamps |
| Menu-bar tray | pane's chevron opens the bar under the menu bar; static menu rebuilt there; action icon pressed in place; icons hidden again (gated variants: your BetterDisplay / iStat stay open in one position; notch icons open) |
| Tray look | Captures of the tray row and overflow (`test-results/previews/tray-*.png`); overflow on screen, cells square |
| Virtual desktops · empty desktop focus | ⌃⌘D to an empty desktop leaves no window focused (pane fronted without windows) |
| E2E · pane agent | The real agent process: reservation, taskbar click, drag snap, quit-on-last-window, restore on exit, ⌃⌘F full screen, virtual desktop chords |

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
```

The overall conclusions are in `KNOWLEDGE.md`; status per milestone is in `PLAN.md`.
