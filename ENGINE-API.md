# pane engine API

How the UI and extensions plug into pane's engine.

- **`Sources/PaneKit`:** the engine. Behavior, window state, input and system settings. It's tested.
- **`Sources/PaneShell`:** the UI: the taskbar, Start, Alt+Tab, Settings and onboarding.
- **`Sources/PaneApp`:** the agent that wires them together (`PaneAgent`, `PaneMain`), and the extension points
  (`PaneExtension`, `PaneHost`).

For each part below:
- **Data** is what it renders.
- **Actions** are what it calls.
- **Events** are what it gets told.
- **Rules** come from measurements.

## Ground rules for every surface

- **Threads:**
  - Engine callbacks say which queue they arrive on; most are main.
  - Read `NSScreen` on the main thread only. Off the main thread it returned stale values.
  - AX and focus calls block for up to about 0.7 s, so run them off the main thread.
- **Reuse views, don't rebuild them.** On macOS 26, every `NSButton` created leaves about 14 KVO records in AppKit
  forever, even after it's freed. Key views by the IDs below and update them in place.
- **Panels that must take the first click:**
  - set `becomesKeyOnlyIfNeeded = true`;
  - have views return `acceptsFirstMouse → true`;
  - order the panel in with `orderFrontRegardless()`;
  - never use a modal `NSMenu` for pickers (a modal menu blocked SIGTERM).
- **Panel levels and Spaces:**
  - The taskbar is `CGWindowLevelForKey(.dockWindow) + 1`.
  - Set `isFloatingPanel` before `level`; it resets the level.
  - Use `animationBehavior = .none`; the zoom animation scales the frame.
  - Collection behavior is `[.canJoinAllSpaces, .stationary, .ignoresCycle]`.
  - Hide on full-screen Spaces (`PrivateAPI.activeSpace()?.kind == .fullscreen`).
- **Coordinates:** AX and the window server use a top-left origin; AppKit uses bottom-left.
  `Geometry.cocoaToAX(_:primaryHeight:)` converts.
- **Logging:** `PaneLog.write(_:)` writes `[pane HH:mm:ss.SSS] …` (UTC) to stderr.

## Window list (feeds everything)

`WindowInventory`:
- **Data:** `windows: [ManagedWindow]`.
  - Fields: id (CGWindowID), pid, title, appName, bundleID, frame, isMinimized, isOnVisibleSpace, isFocused, seat.
  - `seat` is creation order, stable across refreshes, so buttons never jump around.
- **Events:** `onChange([ManagedWindow])` on main.
  - It fires about 100 ms after a real change.
  - A 0.5 s grace period hides minimize and Space blinks.
- **Actions:**
  - `start()`, `stop()`;
  - `scheduleRefresh()`;
  - `refreshNow()` (synchronous, for tests);
  - `element(for:)` (AX handle; cached handles work across Spaces).
- **Rules:**
  - Idle cost is about 0.6% of a core.
  - Feed `FocusHistory.update(_:)` from every `onChange`.

## Taskbar

`TaskbarLayout` / `TaskbarActions` / `GroupCycle` / `GroupFlyout` (TaskbarGroups.swift, Taskbar.swift), drawn by
`TaskbarPanel`:
- **Data:**
  - `TaskbarLayout.groups(windows:pinned:history:)` gives `[TaskbarGroup]`: an app with its windows, MRU order and
    pinned flag.
  - `TaskbarLayout.present(groups:mode:metrics:availableWidth:previous:)` gives a `TaskbarPresentation`:
    - `buttons`, each with `id`, `kind` (window, group or pinnedApp), label, `showsLabel`, `windowCount`, `isActive`,
      `isMinimized` and `width`;
    - `overflow`.
  - Pass `previous` for hysteresis. `CombineMode` is `.always` (Windows default), `.whenFull` or `.never`.
  - **Reuse button views keyed by `TaskbarButton.id`.**
- **Actions (call off the main thread):**
  - `TaskbarActions.click(window:inventory:)`: focus, or minimize if already active.
  - `clickGroup(_:inventory:)` → `GroupClick` (focus / showFlyout / launch).
  - `focus(_:inventory:history:)`: focus only (for cycling).
  - `middleClick(bundleID:pid:)`: new window or new instance.
  - `close(_:inventory:)`.
  - `launch(bundleID:)`.
  - `perform(GroupCommand, on:)` with restoreAll / minimizeAll / closeAll / sideBySide / stacked / cascade.
  - Ctrl-click cycling: `GroupCycle.next(group)`.
  - Win+N cycling: same, with a 1.5 s timeout.
- **Group pop-up:** `GroupFlyout.make(for:previewsAvailable:maxThumbnails:)` returns entries (wid, title, active /
  minimized / other-Space) and `.thumbnails` or `.list`.
  - Thumbnails come from `WindowThumbnails.provider`, an extension's. Without one the pop-up is a list of titles.
- **Badges, progress, attention:** `TaskbarPanel.signals: [bundleID: DockSignals.Signal]`, fed by `DockSignals`, which
  reads the Dock's tiles. Each button shows them, and its accessibility value reads e.g. "badge 7; progress 40%; needs
  attention".
- **Drag to reorder:** built into the buttons. Pinned order goes through `onPinnedChanged`.
- **Show desktop:** the "Show desktop" sliver calls `onShowDesktop`; the agent toggles `ShowDesktop`.
- **Dock replacement:** `DockReservation(settings:).apply(height:)` reserves exactly the bar height (28 pt Dock tile →
  48 pt). Call `restore()` on quit.
- **Auto-hide:** `TaskbarPanel.autoHide`, setting `taskbar.autoHide`. Nothing is reserved. The macOS Dock auto-hides,
  and `DockHoverShield.setTaskbarAutoHide` keeps the bottom edge for pane.
- **Hide when asked:** full screen and full-screen Spaces (see Full screen).
- **The notification area** is an extension's (`TaskbarPanel.makeTray`, a `TaskbarTray`). Without one the taskbar has
  none.

## Alt+Tab switcher

`SwitcherController(inventory:history:options:)`, drawn by `SwitcherPanel`:
- **Events (main):**
  - `onShow(items, selected)`;
  - `onSelect(index)`;
  - `onHide(committed)`: release commits; Esc gives nil.
- **Options:**
  - `modifier`: ⌥ by default (⌘ for "⌘Tab opens pane's switcher").
  - `ignoredApps`.
  - `windowFilter` (the agent filters by `DesktopMembership`).
- **Data:** `items: [ManagedWindow]` in MRU order. `SwitcherPanel.showsPreviews` turns thumbnails on, when a
  `WindowThumbnails.provider` is set.

## Full screen

`FullScreenService`:
- **Actions:**
  - `toggle(window)`, bound to ⌃⌘F.
  - `focusChanged(to:)`: feed it from inventory changes; it only acts on real changes.
  - `prune(alive:)` and `shutdown()`.
- **Events:** `onTaskbarSuppressed(Bool)` on main: hide the taskbar while a full-screen window is focused.
- **Rule:** the menu bar can't be covered from outside.

## Start

`StartMenuController(model: StartMenuModel(index:store:prefs:))` (PaneShell/Start) is Windows 11's Start. Setting
`start.menu = "apps"` uses macOS's Apps panel instead (`AppsPanel.toggleVerified()`).

- **Engine (PaneKit):**
  - **`AppIndex`:** apps with categories and live installs; launch counts; `byCategory`, `byLetter`, `mostUsed`,
    `recentlyAdded`.
  - **`StartStore`:** `start.json`, with pins and folders (`PANE_START_FILE` points elsewhere).
  - **`StartSearch`:** `instant` finds apps, System Settings panes and pane's settings; `files` searches Spotlight.
  - **`RecentFiles`:** items with `relativeTime`. The files themselves come from an extension
    (`StartMenuModel.recentFiles`).
  - **`Power`:** `perform`. `PANE_FAKE_POWER` logs instead, and a test agent always refuses.
  - **`Account`, `StartPlace`.**
- **Extension points on `StartMenuModel`:** `recentFiles`, `extraAllViews` (more All-apps views), `overlay`,
  `canMakeFolders`, `onWillShow`, `changed()`.
- **Agent link:** `start:toggle`, `start:hide`, `start-search:<text>`.
- **Accessibility identifiers:**
  - panel and search: `pane.start`, `start.search`, `start.results`, `start.result.<n>`, `start.preview`;
  - Pinned: `start.pinned`, `start.pinned.<bundle>`, `start.folder.<n>`, `start.folder.open`, `start.showAllPins`;
  - Recent: `start.recent`, `start.recent.<n>`;
  - All: `start.all`, `start.all.view`, `start.all.<bundle>`, `start.all.index.<letter>`, `start.jumpGrid`,
    `start.jump.<letter>`;
  - bottom bar: `start.account`, `start.place.<name>`, `start.power`.

## Snapping

`SnapService`:
- **Events:**
  - `onPreview(CGRect?)`: drag-to-edge preview; nil hides it.
  - `onLayoutsRequested(window, buttonFrame)`: hover dwell on the green button (when `layoutsOnHover`).
  - `onLayoutsDismissed`.
  - `onTopDrag(point?)`: a window dragged to the top centre (when `topDragLayouts`).
  - `onAssist(window, zone)`: after a snap into a zone (when `assistEnabled`).
  - `onShake(window)`: a title-bar shake (when `shakeEnabled`).
- The gestures are detected here and answered by an extension. With nothing answering, the agent leaves them off.
- **Actions:**
  - `snap(window, to: Geometry.Snap)`;
  - `toggleMaximize`, `restore`;
  - `arrow(_:on:)` / `arrowOnFocusedWindow` (Win+arrow state machine);
  - `state(of:)`; `gap` (points between snapped windows).
- **Data:** `Geometry.rect(for:in:)` and `Geometry.workArea`.

## Menus and Alt mode

`MenuMirror`, `Mnemonics`, `MirroredMenu`:
- **Data:**
  - `MenuMirror.topLevel(of: pid)` and `items(of: entry)` give `MenuEntry` (title, enabled, separator, submenu,
    shortcut).
  - `Mnemonics.assign(titles)` gives the underlined letters.
- **Actions:** `MenuMirror.perform(entry, for: window)` works for background windows too.
- **Alt mode (⌥ tap, then a letter):** `HotkeyService.menuMnemonics` (you provide them) and `onMenuMnemonic(index)`.
  The agent asks extensions first (`menuMnemonics()`, `openMenu(_:)`), else uses the app's menu bar
  (`MirroredMenu`).

## Keyboard

`HotkeyService(options:snap:)`. Its events all arrive on main:
- `onStart` (⌘ tap);
- `onMenuKey` (⌥ tap);
- `onFullScreenKey` (⌃⌘F);
- `onShowDesktop`, `onFileExplorer`, `onSettings` (Win+I: ⌃⌘I);
- `onTaskbarIndex(n)` (⌘1…9 when `winNumbers`).

Also:
- ⌥F4 is handled inside.
- **Extension shortcuts:** an extension binds its own with `bind(_:_:)` before `start()`. Only shortcuts someone
  answers are bound, so without that extension its chords reach the apps.
- **`binds(_:)`** says whether an extension took a chord. The agent turns macOS's ⌘Tab off only then.
- **`options`** (bindings, `winArrows`, `winNumbers`, `ignoredApps`) can be adjusted before `start()`.

## Lifecycle and system settings

`LifecycleService` (quit on last window, opt-out list) and `SystemSettings` (crash-safe backup → apply → restore) run
without UI.

The agent:
- holds an exclusive lock (`Pane/agent.lock`), so only one runs;
- restores everything on quit, on SIGINT/SIGTERM/SIGHUP, and on the next launch after a crash;
- also brings back windows an extension parked off screen (`ParkedWindows`), even in a build without that extension.

## Settings (`Sources/PaneKit/Settings.swift`)

The engine gives the Settings window one catalog to render, one store to read and write, and key bindings with
conflict checks.

**Catalog: `PaneSettings`.** Every setting is a typed `Setting<Value>`:
- `id`: the stable stored key, e.g. `"taskbar.alignment"`. Never rename it.
- `defaultValue`.
- `info`:
  - `section`;
  - `title`, `help`;
  - `kind`: toggle, choice (value → label), number (range, step, unit), text, app list, multi-choice or shortcut;
  - `status`: `.live` (applies at once), `.restart` (pane must restart), `.planned` (reserved for a feature not built
    yet; hide it or show it greyed out);
  - `perApp`: can be overridden per bundle ID;
  - `advanced`.

Each `Shortcut` (Start, snap, taskbar 1…9, …) has a setting `keys.<action>` holding `KeyBinding?`, where nil means off.

**Registering more (extensions, before a `SettingsStore` loads):**
- `PaneSettings.register(_:dependsOn:keywords:builtInOverrides:legacyAppLists:)`. Afterwards `all`, `setting(id:)`,
  `dependsOn`, `keywords` and `builtInOverrides` include what was registered.
- `Shortcut` is a struct (`rawValue`, `title`, `defaultBinding`, `isImplemented`): `Shortcut.register`,
  `Shortcut.allCases`.
- **Presets:** `ShortcutPresets.register(name, bindings)` and `bindings(name)`. The engine ships "mac": snap on ⌃⌥
  arrows, next display ⌃⌥⌘→, no ⌘ digits. It collides with nothing in macOS.
  `SettingsStore.applyShortcutPreset(name)` writes one.

**Store: `SettingsStore`** (main actor; `~/Library/Application Support/Pane/config.json`):
- **Read:** `store[PaneSettings.alignment]` for the global value; `store.value(setting, for: bundleID)` for one app.
- **Write:** `try store.set(setting, value)`. It throws `SettingsError.invalid` for an out-of-range number or an
  unknown choice. Also `reset(setting)` and `resetAll()`.
- **By id:** `json(_:)`, `set(id:json:)`, `reset(id:)`, `isDefault(id:)`, `setOverride(id:json:for:)`,
  `appsWithOverrides()`, `overrides(for:)`, `removeOverrides(for:)`.
- **Per app:** `setOverride(setting, value, for: bundleID)`, where nil removes the override, and `overrides(setting)`
  returns the bundle → value map. VMs and remote-desktop apps ship with "ignore pane's shortcuts".
- **Observe:** `observe(setting) { newValue in … }` and `observeAll { id in … }`. Keep the returned
  `SettingsObservation`; it cancels when released. `watchFile()` applies hand edits to config.json live; the agent
  turns it on.
- **Locks:** `setLocks(_:userOverrides:)` makes settings read as fixed values (an extension's editions). The Free build
  never locks anything. Also `isLocked(id:)` and `storedJSON(_:)`.
- **Import / export:** `exportData()` and `importData(_:)` (v1 or v2; returns the problems found). For full backups,
  `PaneBackup.exportData(store, sections:)` and `importData(_:store:sections:)` carry named `BackupSection`s too
  (Start's layout from the engine).
- **Problems:** `issues` lists what was wrong in the file. A bad value falls back to its default; it never stops pane.

**File format:** version 2, `{"version": 2, "settings": {id: value}, "apps": {bundleID: {id: value}}}`.
- Only non-default values are written, so later releases can change defaults.
- Keys this build doesn't know are kept, so a build without an extension doesn't erase the extension's settings.
- The old flat file (v1) is read as is and rewritten as v2 on the first change.

**Keys:**
- **`KeyBinding`:** written as `"ctrl+cmd+left"` or `"tap:cmd"`, shown as `display` ("⌃⌘←"). Modifiers are ctrl, alt,
  shift, cmd.
- **`ShortcutConflicts.check(store, macOS:)`** finds two actions on one chord, and chords that would swallow a macOS
  shortcut (⌘Q/W/C/V…, ⌘←/→ in text, ⌘1…9 in browsers, Mission Control, screenshots…). It includes the user's own
  macOS shortcuts (`macOSShortcuts()`). Show each conflict next to the action it affects.
  `ShortcutConflicts.appShortcutsOnCtrl` tells it when app shortcuts have moved to Ctrl (an extension's keyboard).
- Rebound chords take effect after pane restarts; the Settings window offers *Restart pane*.

## Settings window

- **Window:** `SettingsWindowController(model: SettingsModel(store:))` in PaneShell/Settings. The agent makes it on
  first use, in `openSettings(page:)`.
  - **Pages:** `SettingsPages.all` (PaneKit). The engine's are general, colors, start, taskbar, multitasking, keyboard,
    apps, advanced and about.
  - A page with nothing to show is left out. `page("shortcuts")` and similar aliases work.
  - **Extensions add:** `SettingsPages.add(page:after:)`, `add(_:page:group:at:groupAfter:groupFirst:)` and
    `addExceptionColumns`.
  - `--open-settings <page>` also accepts `search:<words>`.
- **Opening Settings.** Each of these goes through the agent's `openSettings(page:)`, which logs "open settings":
  - starting pane a second time, or `pane --open-settings <page>`;
  - the menu-bar icon's *pane Settings…*;
  - Win+I (`keys.settings`: ⌃⌘I);
  - the taskbar's right-click → *Taskbar settings* (page `taskbar`).
- **Model hooks:**
  - `pendingRestart` feeds the restart bar; `onRestart(page)` restarts and reopens on that page.
  - `backupSections` and `onImported` handle full backups.
  - `onShowWelcome` reopens onboarding.
  - **For extensions:** `pageSections` (a view after a page's settings), `customRows` (a row an extension draws),
    `shortcutPresets` (Keyboard's restore buttons), `lockBadge` / `lockPage` (the badge on locked rows).
- **Accessibility identifiers:**
  - each control: its setting id;
  - window and navigation: `pane.settings`, `settings.sidebar.<page>`, `settings.search`, `settings.advancedToggle`;
  - restart bar and notices: `settings.restartBar`, `settings.restartButton`, `settings.notice`;
  - shortcuts: `keys.<action>.recorder` (AXValue: the binding text or "recording"), `.conflict`, `.clear`, `.reset`;
  - app lists: `<id>.add`, `<id>.remove.<bundle>`;
  - Advanced: `settings.export`, `settings.import`, `settings.resetAll`, `settings.restoreNow`, `settings.showWelcome`.
- **Shortcut recording:** while recording, send `recording:on` / `recording:off` (AgentLink), or call
  `ShortcutRecording.begin()` / `end()` in process. pane's keys stand down and macOS's ⌘Tab is off (so ⌘Tab itself can be recorded).
- **The look** is SwiftUI's grouped `Form`, like System Settings. Restyle freely; tests find controls by identifier.

## Permissions, conflicts, what pane changes

- **Permissions:**
  - `Permissions.shared` has `accessibility` (`.granted` / `.missing`), `previews`, `onAccessibilityChange`,
    `requestAccessibility()` and `openAccessibilitySettings()`.
  - Without Accessibility the agent waits and starts its services when the grant arrives. A revoke stops every tap at
    once.
  - Tests fake the state with `PANE_FAKE_PERMISSIONS_FILE`.
- **Restart:** `pane --restart`, or the AgentLink message `restart`.
  - It's a handover: the Dock isn't restored and re-applied.
  - `pendingRestart` lists the `.restart` settings changed since launch.
- **Conflicts:**
  - `Conflicts.runningApps()` lists running window, menu-bar and Dock managers, each with what overlaps.
    `Conflicts.quit(app)` is *Quit it*.
  - `Conflicts.macOSFeatures()` reports macOS edge tiling and Stage Manager when they're on.
- **What pane changes:**
  - `SystemChanges.describe(store)` returns rows: title, detail, and the setting that turns the change off. Extensions
    add rows with `SystemChanges.extra`; a row may bring its own `isOn` / `set`.
  - `SystemChanges.promise` is the restore promise, word for word.
  - `SystemChanges.restoreAll(store)` is *Restore now*.
- **pane's menu-bar icon:** `MenuBarIcon` (*pane Settings…*, *Pause pane*, *Quit pane*), setting
  `general.showMenuBarIcon` (live). `onBuy` adds an extension's purchase item.

## Onboarding

- **Window:** `OnboardingWindowController(model: OnboardingModel(store:))` in PaneShell/Onboarding.
  - Steps: welcome, accessibility, previews, conflicts, changes, login. There's also a keyboard step when an extension
    supplies it (`keyboardStep`).
  - `model.onFinish` is the agent's hook. It writes the version, closes, and restarts when a launch-time setting
    changed.
  - **For extensions:** `keyboardStep`, `welcomeNote`, `welcomeFeatures`.
- **When it shows:**
  - at launch while `Onboarding.isNeeded(store)` is true (setting `general.onboardingDone`; test agents need
    `PANE_ONBOARDING=1`);
  - on Settings ▸ Advanced ▸ *Show welcome again*;
  - on a second start before it's finished.
- **Accessibility identifiers:**
  - window and navigation: `pane.onboarding`, `onboarding.step.<step>`, `onboarding.continue`, `onboarding.back`;
  - Accessibility: `onboarding.accessibility.status` (AXValue granted/missing), `.grant`;
  - previews: `onboarding.previews.status` (granted/missing/skipped), `.allow`;
  - conflicts: `onboarding.conflict.<bundle>` with `.quit` and `.ignore`, or `onboarding.conflicts.none`;
  - changes: `onboarding.change.<setting>`, `onboarding.promise`;
  - login: `onboarding.login`.

## Extensions

`PaneExtension` (PaneApp) is how a build adds features to the engine. `PaneMain.run(extensions:)` takes them; the
`pane` executable passes none.

**Hooks**, in the order the agent calls them, all optional except `start`:
- **`launch(host)`:** before anything reads the settings (an edition can set locks here).
- **`prepare(host)`:** the taskbar is made, before it shows.
- **`start(host)`:** services start; hotkeys and Start exist.
- **While running:** `windowsChanged(_:)`, `menuMnemonics()`, `openMenu(_:)`, `handle(message)` (AgentLink messages
  the engine doesn't know), `configureSettings(model)`, `configureOnboarding(model)`.
- **`suspend()`:** Accessibility was revoked. The default is `stop()`.
- **`stop()`:** quit or restart: bring everything back.

**`PaneHost`:**
- **Shared objects:** `prefs`, `inventory`, `taskbar`, `fullScreen`, `snap`, `history`, `hotkeys`, `switcherPanel`,
  `startMenu`.
- **Desktops:** `desktops` (`DesktopMembership`: `set(_:)`, `isOnCurrent(_:for:)`, `showEveryDesktop(_:_:)`) and
  `isOnCurrentDesktop(_:)`.
- **Apps:** `isHidden`, `leftAlone`.
- **Editions:** `isPro`, `setEdition(isPro:locks:lockingOverrides:summary:reopenSettings:)`, `buyPro`.
- **Agent actions:** `openSettings`, `toggleShowDesktop`, `menuBarMenu`, `menuBarChevron`, `log`.
- **Tests:** `scope`.

**Engine slots extensions fill:**
- the notification area: `TaskbarPanel.makeTray` / `trayProvider`;
- thumbnails: `WindowThumbnails.provider`;
- Start: `recentFiles`, `extraAllViews`, `overlay`, `canMakeFolders`;
- Settings: `pageSections`, `customRows`, `backupSections`, `shortcutPresets`;
- shortcuts: `HotkeyService.bind`;
- onboarding: `keyboardStep`, `welcomeFeatures`, `SystemChanges.extra`.

## Testing support (`Tests/PaneTestKit`)

The library the engine's tests use, public so an extension's own tests can use it too:
- **The fixture app:** `Fixture`, `FixtureBundle`.
- **Polling and findings:** `eventually`, `settle`, `Report`.
- **The root of every integration suite:** `IntegrationTests`.
- **Helpers, as protocols with defaults:**
  - `AgentHarness`: launching a test agent, its log and its config copy;
  - `SettingsUIHarness`: the Settings window over Accessibility;
  - `LiveSettingsHarness`: live settings, Alt+Tab and drags;
  - `StartUIHarness`: Start over Accessibility.
- **Which agent:** `Harness.agentBinaryName` selects the agent a runner tests.
