# pane engine API, for building the real UI

This file describes how the real UI plugs into pane's engine.

- The engine is `Sources/PaneKit`: behavior, window state, input and system settings. It's tested.
- The current UI is `Sources/PaneShell` plus the agent in `Sources/PaneApp` (`PaneAgent`, `PaneMain`). It's a functional harness only, but it's the reference for how each part is wired.
- Replace the harness views. Keep the calls and callbacks.

For each UI part below:
- **Data** is what it renders.
- **Actions** are what it calls.
- **Events** are what it gets told.
- **Rules** come from measurements (KNOWLEDGE.md section in brackets).

## Ground rules for every surface

- **Threads:**
  - Engine callbacks say which queue they arrive on; most are main.
  - Read `NSScreen` on the main thread only. Off the main thread it returned stale values (§9).
  - AX and focus calls block for up to about 0.7 s, so run them off the main thread.
- **Reuse views, don't rebuild them.** On macOS 26, every `NSButton` created leaves about 14 KVO records in AppKit forever, even after it's freed (§14). Key views by the IDs below and update them in place.
- **Panels that must take the first click:**
  - set `becomesKeyOnlyIfNeeded = true`;
  - have views return `acceptsFirstMouse → true`;
  - order the panel in with `orderFrontRegardless()`;
  - never use a modal `NSMenu` for pickers (a modal menu blocked SIGTERM, §9).
- **Panel levels and Spaces:**
  - The taskbar is `CGWindowLevelForKey(.dockWindow) + 1`.
  - Set `isFloatingPanel` before `level`; it resets the level.
  - Use `animationBehavior = .none`; the zoom animation scales the frame.
  - Collection behavior is `[.canJoinAllSpaces, .stationary, .ignoresCycle]`.
  - Hide on full-screen Spaces (`PrivateAPI.activeSpace()?.kind == .fullscreen`).
- **Coordinates:** AX and the window server use a top-left origin; AppKit uses bottom-left. `Geometry.cocoaToAX(_:primaryHeight:)` converts.

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
  - Idle cost is about 0.6% of a core (§14).
  - Feed `FocusHistory.update(_:)` from every `onChange`.

## Taskbar

`TaskbarLayout` / `TaskbarActions` / `GroupCycle` / `GroupFlyout` (TaskbarGroups.swift, Taskbar.swift):
- **Data:**
  - `TaskbarLayout.groups(windows:pinned:history:)` gives `[TaskbarGroup]`: an app with its windows, MRU order and pinned flag.
  - `TaskbarLayout.present(groups:mode:metrics:availableWidth:previous:)` gives a `TaskbarPresentation`: `buttons` (each with `id`, `kind` window/group/pinnedApp, label, `showsLabel`, `windowCount`, `isActive`, `isMinimized`, `width`) plus `overflow`.
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
- **Group pop-up:** `GroupFlyout.make(for:previewsAvailable:maxThumbnails:)` returns entries (wid, title, active / minimized / other-Space) and `.thumbnails` or `.list`.
- **Previews:**
  - `PreviewClient.thumbnail(wid, maxDimension:)` is async and works for minimized and parked windows.
  - Load thumbnails in parallel; requests are serialized internally.
  - The helper must be installed (`scripts/install-preview-helper.sh`) and allowed for Screen Recording.
- **Dock replacement:** `DockReservation(settings:).apply(height:)` reserves exactly the bar height (28 pt Dock tile → 48 pt). Call `restore()` on quit.
- **Hide when asked:** full screen and full-screen Spaces (see Full screen).

## Alt+Tab switcher

`SwitcherController(inventory:history:options:)`:
- **Events (main):**
  - `onShow(items, selected)`;
  - `onSelect(index)`;
  - `onHide(committed)`: release commits; Esc gives nil.
- **Options:**
  - `modifier`: ⌥ by default.
  - `allSpaces`: false is Windows' current-desktop-only behavior.
  - `windowFilter`: set it to the current virtual desktop.
- **Data:** `items: [ManagedWindow]` in MRU order. Previews come from `PreviewClient`.

## Full screen

`FullScreenService`:
- **Actions:** `toggle(window)` (⌃⌘F) and `focusChanged(to:)`. Feed the latter from inventory changes; it only acts on real changes. Also `prune(alive:)` and `shutdown()`.
- **Events:** `onTaskbarSuppressed(Bool)` on main: hide the taskbar while a full-screen window is focused.
- **Rule:** the menu bar can't be covered from outside (§12).

## Start menu

The default Start is macOS's **Apps** panel, a searchable grid of all apps: `AppsPanel.toggleVerified()`.
- It's a Spotlight panel opened through the Dock.
- Opening is verified and retried; if Spotlight's panel controller is wedged, Spotlight is restarted.
- Don't toggle it during an icon capture (`TaskbarPanel.isCapturingIcons`).
- The pinned "Apps" button uses the same path.

`AppCatalog` (for a custom Start):
- `reload()`, `apps`, `search(query, limit:)` (ranked).
- To launch: `NSWorkspace.openApplication` or `TaskbarActions.launch(bundleID:)`.

## Snap, Snap Layouts, Snap Assist

`SnapService`:
- **Events:**
  - `onPreview(CGRect?)`: drag-to-edge preview; nil hides it.
  - `onLayoutsRequested(window, buttonFrame)`: hover dwell on the green button.
  - `onLayoutsDismissed`.
  - `onAssist(window, remainingZones)`: after a snap, offer the other windows for the leftover zones.
- **Actions:**
  - `snap(window, to: Geometry.Snap)`;
  - `toggleMaximize`, `restore`;
  - `arrow(_:on:)` / `arrowOnFocusedWindow` (Win+arrow state machine);
  - `state(of:)`.
- **Data:**
  - `Geometry.rect(for:in:)` and `Geometry.workArea`.

## Keyboard (who calls you)

`HotkeyService` events, all on main:
- `onStart` (⌘ tap);
- `onMenuKey` (⌥ tap);
- `onFullScreenKey` (⌃⌘F);
- `onDesktopCommand(.new / .close / .previous / .next / .moveWindowLeft / .moveWindowRight)`;
- `onTaskbarIndex(n)` (⌘1…9, off until the deferred ⌘ decision).

⌥F4 is handled inside.

## Lifecycle and system settings

`LifecycleService` (quit on last window, opt-out list) and `SystemSettings` (crash-safe backup → apply → restore) run without UI.

The agent:
- holds an exclusive lock (`Pane/agent.lock`), so only one runs;
- restores everything on quit, on SIGINT/SIGTERM/SIGHUP, and on the next launch after a crash.

## Settings (`Sources/PaneKit/Settings.swift`)

The settings window is yours. The engine gives you one catalog to render, one store to read and write, and key bindings with conflict checks. The design follows research/settings-and-keys.md (AltTab, Rectangle and Windows 11's Settings).

**Catalog: `PaneSettings`.** Every setting is a typed `Setting<Value>`:
- `id`: the stable stored key, e.g. `"taskbar.alignment"`. Never rename it.
- `defaultValue`.
- `info`:
  - `section`: General, Appearance, Taskbar, Notification area, Snap & windows, Keyboard, Alt+Tab, Desktops, Apps, Advanced;
  - `title`, `help`;
  - `kind`: toggle, choice (value → label), number (range, step, unit), text, app list, shortcut;
  - `status`: `.live` (applies at once), `.restart` (pane must restart), `.planned` (reserved for a feature not built yet; hide it or show it greyed out);
  - `perApp`: can be overridden per bundle ID;
  - `advanced`.

`PaneSettings.settings(in: .taskbar)` lists one pane's settings in display order. Each `Shortcut` action (Start, snap, desktops, taskbar 1…9, …) has a setting `keys.<action>` holding `KeyBinding?`, where nil means off.

**Store: `SettingsStore`** (main actor; `~/Library/Application Support/Pane/config.json`):
- **Read:** `store[PaneSettings.alignment]` for the global value; `store.value(setting, for: bundleID)` for one app.
- **Write:** `try store.set(setting, value)`. It throws `SettingsError.invalid` for an out-of-range number or an unknown choice. Also `reset(setting)` and `resetAll()`.
- **Per app:** `setOverride(setting, value, for: bundleID)`, where nil removes the override, and `overrides(setting)` returns the bundle → value map for an exceptions table. VMs and remote-desktop apps ship with "ignore pane's shortcuts".
- **Observe:** `observe(setting) { newValue in … }` and `observeAll { id in … }`. Keep the returned `SettingsObservation`; it cancels when released. `watchFile()` applies hand edits to config.json live; the agent turns it on.
- **Import / export:** `exportData()` and `importData(_:)` (accepts v1 or v2; returns the problems found).
- **Problems:** `issues` lists what was wrong in the file. A bad value falls back to its default; it never stops pane.

**File format:** version 2, `{"version": 2, "settings": {id: value}, "apps": {bundleID: {id: value}}}`.
- Only non-default values are written, so later releases can change defaults.
- Keys this build doesn't know are kept, so an older pane doesn't erase a newer one's settings.
- The old flat file (v1) is read as is. `optOut` becomes per-app `lifecycle.quitOnLastWindow = false`, and `keepNativeFullScreen` becomes per-app `fullScreen.convertNative = false`. The file is rewritten as v2 on the first change.

**Keys:**
- **`KeyBinding`:** written as `"ctrl+cmd+left"` or `"tap:cmd"`, shown as `display` ("⌃⌘←"). Modifiers are ctrl, alt, shift, cmd.
- **`ShortcutConflicts.check(store)`** finds two actions on one chord, and chords that would swallow a macOS shortcut (⌘Q/W/C/V…, ⌘←/→ in text, ⌘1…9 in browsers, Mission Control, screenshots…). Show each conflict next to the action it affects.
- **`store.applyKeyboardMode(.mac / .windows)`** writes a preset:
  - **`mac`:** snap on ⌃⌥ arrows, next display ⌃⌥⌘→, no ⌘ digits. It collides with nothing in macOS.
- Rebound chords take effect after pane restarts (`HotkeyService.Options.bindings`); the Settings window offers *Restart pane*.

**Onboarding:** built in Phase 3; see §Onboarding below.

## Taskbar additions (2026-10-22)
- **Badges, progress, attention:** `TaskbarPanel.signals: [bundleID: DockSignals.Signal]` (fed by `DockSignals`, which reads the Dock's tiles). Each button shows them, and its accessibility value reads e.g. "badge 7; progress 40%; needs attention".
- **Drag to reorder:** built into the buttons. Pinned order goes through `onPinnedChanged`.
- **Show desktop:** the "Show desktop" sliver calls `onShowDesktop`; the agent toggles `ShowDesktop`.
- **Auto-hide:** `TaskbarPanel.autoHide`, setting `taskbar.autoHide`. Nothing is reserved; the macOS Dock auto-hides and `DockHoverShield.setTaskbarAutoHide` keeps the bottom edge for pane.

## Settings status (2026-10-22)
- **Built:** every catalog setting except two, which stay `.planned`: `general.checkForUpdates` (release) and `taskbar.allDisplays` (needs a second display). `general.showMenuBarIcon` is live since Phase 1. A settings window can show the `.live` ones as instant switches and the `.restart` ones with "Restart pane".
- **The Win key is ⌘ (decision 12).** There's no Win-key choice. To stop a lone ⌘ tap opening Start, set `"keys.start": null`; any other shortcut can be rebound through `keys.*`.

## For the settings window and onboarding (Phase 1, 2026-10-23)
The engine side of research/plan-settings-onboarding.md. The window and onboarding live in the agent's process.
- **Permissions (E1, E2):**
  - `Permissions.shared`: `accessibility` (`.granted` / `.missing`), `previews`, `onAccessibilityChange`, `requestAccessibility()` (macOS's prompt the first time, then the System Settings page), `openAccessibilitySettings()`.
  - Without Accessibility the agent waits ("waiting for Accessibility") and starts its services when the grant arrives. A revoke stops every tap at once.
  - Tests fake the state with `PANE_FAKE_PERMISSIONS_FILE`.
- **Every setting by id (E4):** `json(_:)`, `set(id:json:)`, `reset(id:)`, `isDefault(id:)`, `setOverride(id:json:for:)`, `appsWithOverrides()`, `overrides(for:)`, `removeOverrides(for:)`. Also `PaneSettings.search(_:)` and `dependsOn` (a setting greyed out unless another has a value).
- **Restart (E3):** `pane --restart`, or the AgentLink message `restart`. It's a handover: the Dock isn't restored and re-applied. `pendingRestart` lists the `.restart` settings changed since launch.
- **Opening Settings (E9, E11).** Each of these calls the agent's `onOpenSettings(page)` hook, and the agent logs "open settings":
  - starting pane a second time, or `pane --open-settings <page>`;
  - the menu-bar icon's *pane Settings…*;
  - Win+I (`keys.settings`: ⌃⌘I in the Mac keyboard, ⌘I in the Windows keyboard);
  - the taskbar's right-click → *Taskbar settings* (page `taskbar`).
- **pane's menu-bar icon:** `MenuBarIcon` (*pane Settings…*, *Pause pane*, *Quit pane*), setting `general.showMenuBarIcon` (live).
  - It sits at the rightmost slot, right of the tray's divider, so hiding icons never hides it.
  - With the tray in the menu bar, the chevron is pane's icon: a right-click gives the same menu.
- **Shortcut recording (E8):**
  - While recording, send `recording:on` / `recording:off` (AgentLink), or call `ShortcutRecording.begin()` / `end()` in process. pane's keys stand down and macOS's ⌘Tab is off.
  - `ShortcutConflicts.check(store, macOS:)` knows the keyboard mode. The Windows keyboard frees ⌘←, ⌘1… and the like. It includes the user's own macOS shortcuts (`macOSShortcuts()`).
- **Conflicts (E6):**
  - `Conflicts.runningApps()` lists running window, menu-bar and Dock managers (Rectangle, Magnet, BetterSnapTool, Moom, Loop, Amethyst, AltTab, Bartender, Ice, DockDoor, uBar…), each with what overlaps. `Conflicts.quit(app)` is *Quit it*.
  - `Conflicts.macOSFeatures()` reports macOS edge tiling and Stage Manager when they're on.
- **What pane changes (E7):**
  - `SystemChanges.describe(store)` returns rows (title, detail, and the setting that turns the change off). It follows the settings.
  - `SystemChanges.promise` is the restore promise, word for word.
  - `SystemChanges.restoreAll(store)` is *Restore now*: it turns every change off. Live changes revert at once; restart pane for the Dock and tiling.
- **Onboarding version:** `Onboarding.isNeeded(store)` and `Onboarding.markDone(store)` use setting `general.onboardingDone`. *Show welcome again* resets it.
- **Full backup (E12):** `PaneBackup.exportData(store, tray:)` / `importData(_:store:tray:)` carry the tray layout (tray.json) under "tray". Call `taskbar.rebuildTray()` after an import.

## The settings window (Phase 2, 2026-10-23)
- **Window:** `SettingsWindowController(model: SettingsModel(store:))` in PaneShell/Settings. The agent makes it on first use, in `openSettings(page:)`.
  - Pages: `SettingsPages.all` (PaneKit), with ids general, colors, taskbar, tray, multitasking, keyboard, apps, advanced and about. `page("shortcuts")` and similar aliases work.
  - `--open-settings <page>` also accepts `search:<words>`.
- **Model hooks the agent sets:**
  - `pendingRestart` feeds the restart bar.
  - `onRestart(page)` restarts and reopens on that page.
  - `tray` and `onTrayImported` handle full backups.
  - `onShowWelcome` is for onboarding (Phase 3).
- **Accessibility identifiers:**
  - each control: its setting id;
  - window and navigation: `pane.settings`, `settings.sidebar.<page>`, `settings.search`, `settings.advancedToggle`;
  - restart bar and notices: `settings.restartBar`, `settings.restartButton`, `settings.notice`;
  - shortcuts: `keys.<action>.recorder` (AXValue: the binding text or "recording"), `.conflict`, `.clear`, `.reset`;
  - app lists: `<id>.add`, `<id>.remove.<bundle>`;
  - app exceptions: `settings.apps.table`, `settings.apps.add`, `settings.apps.row.<bundle>`, `apps.<bundle>.<settingId>`, `apps.<bundle>.remove`, `apps.<bundle>.builtIn`;
  - Advanced: `settings.export`, `settings.import`, `settings.resetAll`, `settings.restoreNow`, `settings.showWelcome`.
- **The look** is SwiftUI's grouped `Form`, like System Settings. Restyle freely; tests find controls by identifier.

## Onboarding (Phase 3, 2026-10-23)
- **Window:** `OnboardingWindowController(model: OnboardingModel(store:))` in PaneShell/Onboarding.
  - Steps: welcome, accessibility, previews, keyboard, conflicts, changes, login.
  - `model.onFinish` is the agent's hook. It writes the version, closes, and restarts when a launch-time setting changed.
- **When it shows:** at launch while `Onboarding.isNeeded` (test agents need `PANE_ONBOARDING=1`), on Settings ▸ Advanced ▸ *Show welcome again*, and on a second start before it's finished.
- **Accessibility identifiers:**
  - window and navigation: `pane.onboarding`, `onboarding.step.<step>`, `onboarding.continue` (titled Get Started, Continue, Continue Without Previews or Finish), `onboarding.back`;
  - Accessibility: `onboarding.accessibility.status` (AXValue granted/missing), `.grant`;
  - previews: `onboarding.previews.status` (granted/missing/skipped), `.allow`;
  - keyboard: `onboarding.keyboard.mac`, `onboarding.keyboard.windows`;
  - conflicts: `onboarding.conflict.<bundle>` with `.quit` and `.ignore`, or `onboarding.conflicts.none`;
  - changes: `onboarding.change.<setting>`, `onboarding.promise`;
  - login: `onboarding.login`.

## The Start menu (2026-10-23, research/plan-start-menu.md)
- **Engine (PaneKit):**
  - `AppIndex` (apps with categories, live installs, launch counts, `byCategory`, `byLetter`, `mostUsed`, `recentlyAdded`);
  - `StartStore` (`start.json`: pins and folders; `PANE_START_FILE` points elsewhere);
  - `StartSearch` (`instant`: apps, System Settings panes, pane settings; `files`: Spotlight);
  - `RecentFiles` (Spotlight last-used dates, `relativeTime`);
  - `Power` (`perform`; `PANE_FAKE_POWER` logs instead, and a test agent always refuses);
  - `Account`, `StartPlace`.
- **Agent link:** `start:toggle`, `start:hide`, `start-search:<text>`, `quick-link`.
- **Accessibility identifiers:**
  - panel and search: `pane.start`, `start.search`, `start.results`, `start.result.<n>`, `start.preview`;
  - Pinned: `start.pinned`, `start.pinned.<bundle>`, `start.folder.<n>`, `start.folder.open`, `start.showAllPins`;
  - Recent: `start.recent`, `start.recent.<n>`;
  - All: `start.all`, `start.all.view`, `start.all.<bundle>`, `start.all.index.<letter>`, `start.jumpGrid`, `start.jump.<letter>`, `start.category.<name>`;
  - bottom bar: `start.account`, `start.place.<name>`, `start.power`;
  - Quick Link: `start.quickLink.<key>`.

## Extensions (2026-10-23, research/plan-open-core.md O3–O4)
- **`PaneExtension`** (PaneApp) is how pane Pro adds features. Hooks, in the order the agent calls them (all optional
  but `start`):
  - `launch(host)`: before anything reads the settings (licensing sets the edition).
  - `prepare(host)`: the taskbar is made, before it shows (the tray attaches).
  - `start(host)`: services start; hotkeys and Start exist.
  - `windowsChanged(_:)`, `menuMnemonics()`, `openMenu(_:)`, `handle(message)`, `configureSettings(model)`.
  - `suspend()` (Accessibility revoked; default `stop()`), `stop()` (quit or restart: bring everything back).
- **`PaneHost`:** `prefs`, `inventory`, `taskbar`, `fullScreen`, `snap`, `history`, `scope`, `hotkeys`, `startMenu`,
  `desktops` (`DesktopMembership`; `isOnCurrentDesktop`), `isHidden`, `isPro`, `setEdition`, `buyPro`, `openSettings`,
  `toggleShowDesktop`, `menuBarMenu`, `menuBarChevron`, `log`.
- **Engine slots extensions fill:** `TaskbarPanel.makeTray` / `trayProvider` (the tray), `WindowThumbnails.provider`
  (previews), Start's `recentFiles` / `extraAllViews` / `overlay` / `canMakeFolders`, `SettingsModel.pageSections` /
  `backupSections`, `HotkeyService.onDesktopCommand` / `onTaskView` (bound only when set).

## Registries (2026-10-24, research/plan-open-core.md O5)
- **Settings:** `PaneSettings.register(_:dependsOn:keywords:builtInOverrides:legacyAppLists:)`; `all`, `setting(id:)`,
  `dependsOn`, `keywords` and `builtInOverrides` include what's registered. Register before a `SettingsStore` loads.
- **Shortcuts:** `Shortcut` is a struct (`rawValue`, `title`, `defaultBinding`, `isImplemented`). Use `Shortcut.register`
  and `Shortcut.allCases`; the engine's are static members, pane Pro's are in an extension.
  - `ShortcutPresets.register(name, bindings)` / `bindings(name)`; the engine ships "mac".
  - `SettingsStore.applyShortcutPreset(name)` writes a preset.
- **Settings window:**
  - `SettingsPages.add(page:after:)`, `add(_:page:group:at:groupAfter:groupFirst:)`, `addExceptionColumns`.
  - A page with nothing to show is left out.
  - `SettingsModel.customRows`, `shortcutPresets`, `lockBadge` / `lockPage`.
- **Onboarding:** `OnboardingModel.keyboardStep` (the step is left out without it), `welcomeNote`, `welcomeFeatures`;
  `SystemChanges.extra` adds "what pane changes" rows (a row may bring its own `isOn` / `set`).
- **Keys:** `HotkeyService.bind(_:_:)` for an extension's shortcut (bound only when someone answers it),
  `binds(_:)`; `options` is settable before `start`.
- **Host:** `PaneHost.setEdition(isPro:locks:lockingOverrides:summary:reopenSettings:)`, `leftAlone`, `switcherPanel`,
  `DesktopMembership.isOnCurrent(_:for:)` / `showEveryDesktop`; hook `configureOnboarding`.
- **Conflicts:** `ShortcutConflicts.appShortcutsOnCtrl` (pane Pro's Windows keyboard).
