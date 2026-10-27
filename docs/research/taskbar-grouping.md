# Taskbar grouping ("combine taskbar buttons") — Windows spec, macOS survey, pane design

Goal: give pane's taskbar the Windows behavior for **several windows of one app**: button combining (the "stack"), the group flyout, and the click, keyboard and menu semantics around it.

Engine today:
- `TaskbarLayout.items(windows:pinned:)` (`Sources/PaneKit/Taskbar.swift:95-116`) emits one `TaskbarItem` per window. Windows of one app are contiguous, in seat order.
- `TaskbarActions.click` (`Taskbar.swift:131-140`) focuses a window, or minimizes it if it is already active.
- `FocusHistory` (`Sources/PaneKit/Switcher.swift:6-38`) holds the per-window MRU order.
- `activateTaskbarItem` (`Sources/PaneApp/PaneAgent.swift`) indexes **items (windows)** for ⌘1…9.

Confidence tags used below:
- **[MS]** Microsoft documentation or the Windows Insider blog.
- **[3P]** a reputable third-party write-up.
- **[obs]** long-standing observed behavior that I could not find documented. Check these on a 24H2/25H2 machine before treating them as spec.

Windows 11 25H2 is an enablement package on the 24H2 codebase, so the taskbar shell is the same in both.

---

## 1. Windows behavior spec

### 1.1 The setting: "Combine taskbar buttons and hide labels"

- **Where:** Settings > Personalization > Taskbar > Taskbar behaviors.
- **Values:** **Always** (the default), **When taskbar is full**, **Never** [3P pureinfotech, elevenforum].
- **Registry:** `HKCU\…\Explorer\Advanced\TaskbarGlomLevel` = 0 Always / 1 When full / 2 Never [3P pureinfotech].
- **Multi-monitor:** a second setting, **"Combine taskbar buttons and hide labels on other taskbars"**, takes the same three values (`MMTaskbarGlomLevel`) [3P pureinfotech, BleepingComputer]. Together with "When using multiple displays, show my taskbar apps on: All taskbars / Main taskbar and taskbar where window is open / Taskbar where window is open", this means that **each bar decides combining by itself**, over the windows it shows.

**History:**
- Windows 7, 8 and 10 had all three modes. In Windows 10 the setting was called "Combine taskbar buttons" (Always, hide labels / When taskbar is full / Never), with "Combine buttons on other taskbars" for other displays.
- Windows 11 21H2 and 22H2 shipped **Always only**.
- **Never** came back in Insider build 23466: "In never combined mode, you'll be able to see each window of your applications on the taskbar individually, as well as their corresponding labels" [MS Insider blog 23466]. It shipped in 23H2 (and in 22H2 "Moment 4").

**Semantics:**

| Mode | Buttons | Labels |
|---|---|---|
| **Always** | One button per app (per AppUserModelID), whether pinned or running. Windows 7 rationale: "combine buttons by default for a predictable experience, to use grouped thumbnails and to have these thumbnails appear on hover as well as on click" [MS E7 blog]. | Hidden. The icon only. |
| **When taskbar is full** | One button per window with its label, until there is no room. Then apps with several windows **collapse into one button**. They un-collapse when room returns [3P pureinfotech; XP description: "Grouping occurs when there is insufficient space on the taskbar to display an acceptable amount of text for each button… Items will be ungrouped when more room becomes available" — Sony KB]. | Shown on uncombined buttons. |
| **Never** | One button per window, always. Windows of the same app stay **next to each other** [obs]. When even that does not fit, buttons shrink and then spill into overflow (§1.9). | Shown. Truncated with an ellipsis as buttons shrink [obs]. |

**Which apps collapse first in "When full":**
- XP: "The program that was opened first is grouped first" [Sony KB].
- Windows 7 to 10 had a registry knob, `TaskbarGroupSize`: 0 = oldest group first, 1 = largest group first [3P ghacks/itprotoday].
- Windows 11's policy is **undocumented** (see open questions).

**Grouping key:** Windows groups by **AppUserModelID**, not by process. Several processes of one app share a button, and apps can split themselves by setting distinct IDs. Programs are also expected to group their secondary, MDI and tab windows under the primary button: "Each program … should have a single taskbar button" [MS UX guide, winenv-taskbar]. On macOS the nearest equivalent is the **bundle ID**, merging every pid of that bundle.

### 1.2 What a group looks like

| | Windows 11 | Windows 10 |
|---|---|---|
| Running indicator | A small "pill" (a short horizontal line) under the icon. Short and grey when running but inactive. Longer and in the accent color for the active app, with a lighter backplate [3P pureinfotech, flashing article] | A colored line across the bottom of the button. The active button gets a lighter background |
| Several windows | **No stacked-tile look in Always mode.** Users note "Windows doesn't clearly show how many windows are open for each application" [3P MS Tech Community thread]. Treat this as [obs] and verify | **Stacked tiles**: extra button edges drawn to the right of the button. "We show a visual cue of stacked tiles that provides feedback on whether there are multiple windows running for a program" [MS E7 blog] |
| Count badge | None for window count. Overlay icons and badges are app-defined status, such as unread mail [MS UX guide] | Same |
| Attention | The app "flashes on the Taskbar". The flashing "eventually stops, and you will see a slightly red backplate and red pill under the app icon". Setting: "Show flashing on taskbar apps" [3P pureinfotech]. Triggered by `FlashWindowEx`, or by a refused `SetForegroundWindow` | Orange flash (about 7 times), then stays orange |
| Progress | A progress fill on the button (`ITaskbarList3`) | Same |

In a combined group, attention or progress from any window shows on the group button. The UX guide says to "flash only one taskbar button for one window at a time" [MS UX guide].

### 1.3 Clicking a combined button

| State | Default action |
|---|---|
| Pinned, no windows | Launch the app |
| 1 window, not active (including minimized) | Activate or restore it |
| 1 window, active | Minimize it [obs; the same rule pane already implements per window] |
| **≥2 windows** (active app or not) | **Toggle the thumbnail flyout.** No window is activated: "You must click once on the grouped button to show thumbnails, then click again on the desired thumbnail" [3P Winaero]. Clicking again closes it |
| ≥2 windows with `LastActiveClick=1` (registry, `…\Explorer\Advanced`) | "A single click switches to the last active program window in the group" [3P Winaero, MS Q&A]. Repeated clicks behave like Ctrl+click (they cycle) |
| **Ctrl+click** a group | "Shift focus through windows in the group" [MS keyboard-shortcuts page]. "When you hold down CTRL, window thumbnails do not get shown, instead the last active window will become focused" [3P Winaero]. Repeated Ctrl+clicks cycle |
| **Shift+click**, or **middle-click** | Open another instance (new window) [MS for Shift; 3P anoopcnair for middle-click] |
| Ctrl+Shift+click | Open as administrator [MS] (no macOS equivalent) |
| **Shift+right-click a group** | The group window menu: **Cascade, Show windows stacked, Show windows side by side, Restore all windows, Minimize all windows, Close all windows** [MS Old New Thing 2009-12-29: hold Shift for "Cascade" and "Minimize all windows"; the MS shortcut page calls it "Show the window menu"]. On a single-window button it is that window's system menu |

**In uncombined modes (Never, or When full before collapse):** every button is one window. Click focuses it, or minimizes it if active. Hover shows that one window's thumbnail.

### 1.4 Hover: the thumbnail flyout and Peek

- Hovering a group shows **one thumbnail per window**. Each thumbnail is "a more accurate representation of a window complete with an icon in the top left corner, window text and even the ubiquitous close button in the top right" [MS E7 blog].
  - Delay: about 400 ms, set by `ExtendedUIHoverTime`. Reports say the registry override broke in 24H2 [3P elevenforum].
- **Peek:** hovering a thumbnail shows that window in place and turns all others into glass [MS E7 blog].
- On a thumbnail:
  - click activates that window;
  - **middle-click closes it** [3P elevenforum];
  - right-click opens the window's system menu [MS Old New Thing];
  - clicking the thumbnail of the already-active window minimizes it [obs].
  - Thumbnail toolbars (up to 7 app buttons) appear under a thumbnail [MS UX guide].
- **Thumbnails turn into a title list** past a threshold that depends on resolution: "for 1024x768 … up to 10 windows but turns it into a list when the 11th window is opened. For 1920x1080, the threshold is 16" [3P Winaero].
  - `Taskband\NumThumbnails` overrode this. 0 meant always a list. Reports say this stopped working in recent Windows 11 builds [3P MS Q&A].
  - **So Windows itself already has a title-list flyout as the overflow form of the thumbnail flyout.**
- **Order:** thumbnails appear in the group's button order, which is creation order and stable. They are not in MRU order [obs].

### 1.5 Keyboard

From the MS keyboard-shortcuts page (Windows 10 and 11):

| Keys | Action |
|---|---|
| Win+1…9, 0 | "Open the app pinned to the taskbar" (start or switch). **On a group with several windows:** it shows the previews and switches to a window. **Holding Win and tapping the number again cycles through the group's windows** [Wikipedia, Windows key: "Press multiple times to cycle through the application's open windows"; 3P]. On an active single window it minimizes [obs] |
| Win+Shift+N | Start a new instance |
| **Win+Ctrl+N** | "Switch to the last active window" of that app. No cycling, no flyout |
| Win+Ctrl+Shift+N | Open as administrator |
| **Win+Alt+N** | Open the jump list |
| **Win+T** | "Cycle through apps in the taskbar". Win+Shift+T goes backward. On a focused group, arrow keys move through its thumbnails and Enter activates [3P] |
| Win+B | Focus the notification area (out of scope here) |

**What N counts:** N is the position among **app buttons (groups), not windows**, in every combine mode [obs, consistent with the "pinned app" wording]. This matters for pane: today ⌘N indexes windows (`main.swift:217-225`).

### 1.6 Right-click: the jump list

From top to bottom [MS UX guide plus obs]:
1. App destinations: **Pinned** items, then **Recent** or **Frequent**, then app **Tasks**. Apps must not add their own open or close commands: "These commands are built into all Jump Lists" [MS UX guide].
2. The **app name**, which launches a new instance or window.
3. **Pin to taskbar** or **Unpin from taskbar**.
4. **End task**, only when the Developer setting is on (Windows 11 23H2 and later) [3P windowslatest].
5. **Close window** when the group has one window, **Close all windows** when it has several [obs; Old New Thing: the normal menu offers mainly "Close all windows"].

### 1.7 Ordering

- Pinned buttons hold their pinned order. A running unpinned app is appended at the right when it first appears [obs].
- A **new window of an app that already has a button**:
  - combined: joins that button;
  - uncombined: is inserted **right after that app's existing window buttons**. Apps never interleave [obs].
- **Drag to reorder** moves whole app groups: "combining this mechanism with the taskband naturally extended rearrange functionality to running windows" [MS E7 blog]. Windows 11 21H2 removed taskbar drag and drop. Drag and drop came back in 22H2.
- Order inside a group (thumbnails, uncombined buttons) is creation order [obs].

### 1.8 Windows on other virtual desktops

- "On the taskbar, show all open windows: Only on the desktop I'm using / On all desktops." Group membership is filtered by this setting.
- Activating a window on another desktop switches to that desktop.

### 1.9 Overflow (taskbar full)

- **Windows 11 (22H2 and later, build 25163):** "Your taskbar will automatically transition into this new overflow state when it has hit its maximum capacity." It offers "an entry point to an overflow menu that allows you to view all your overflowed apps in one space".
  - The entry point is a "…" button at the end of the app area. The menu supports "pinned apps, jump list, and extended UI".
  - "The menu will quietly dismiss once you click outside of it or navigate to an application" [MS Insider blog 25163].
- **Windows 10:** no overflow menu. The button area paged, with small up and down arrows [obs].
- **Order of fallback in "When full" and "Never":** shrink labeled buttons, then (When full only) combine groups, then overflow.

---

## 2. How macOS projects handle several windows of one app

### 2.1 Tungsten Edge (`refs/tungsten-edge`, 89ab9c1)

It is a per-window bar with **no combine option**. The only merging is of native macOS tab groups.

- **Model:** `StripItem` (`UI/ReadModel/StripItem.swift:38`). Its fields include `memberWindowIDs`, `actionWindowID`, `sameAppCardCount` (:44) and `showsTitle`.
  - Tab groups (same app and identical frame) fold into one chip: `items(from:)` at :112-135, `tabGroupKey` at :145.
  - App-level information is used only to count siblings (`countByApp` :129). **Titles appear only when the app has ≥2 windows**: `showsTitle = sameAppCardCount >= 2` (:96). A lone window is shown as an icon (`App/Scenes/ChipView.swift:111,155`). This is a neat middle ground between combined and labeled.
- **Insertion:** `StripOrdering.reconcileWithTrace` (`StripItem.swift:160`, :202-243), via `App/Composition/StripOrderStore.swift:119`. A new window goes, in priority order:
  1. **right after the last chip of the same app** (`.sameAppSibling`);
  2. at the head, for messaging apps;
  3. at its remembered rank, for kept apps;
  4. at the tail (:240).

  Drag order is persisted. Zones are built in `App/Scenes/DockStripView+Projection.swift:22-132`.
- **Clicks** (`Core/Lifecycle/ActionPlanning/LifecycleActionPlanner.swift:70-100`):
  - the active window of the frontmost app minimizes, anything else activates;
  - an app-level chip hides the app if it is frontmost.
  - Right-click (`ChipView.swift:455-512`) gives the app's window list (app-level chips only), recents, New Window, Minimize/Restore, Hide, **Close Window**, Quit and Force Quit. There is **no "Close all"**.
- **Overflow:** a horizontal `ScrollView` with no scroll bars (`DockStripView.swift:225`); the wheel is mapped to horizontal scrolling (`StripWheelScrollInterceptor.swift:47,92`). Chips never shrink. Labels are capped at 140 pt (`WindowTitleTooltip.swift:18`).
- **Label hygiene worth copying:**
  - remove a trailing " — App name" (`StripItem.swift:20`);
  - remove a prefix or suffix shared by the same app's chips (`DockStripView+Projection.swift:312-327`, `StripSharedAffixTrim`).
- **Hover:** a title bubble only. No thumbnails.

### 2.2 DockDoor (`refs/DockDoor/DockDoor`, 77e4771)

It is the best reference for **the group flyout**: a per-app window list with thumbnails and a compact title-list fallback.

- **Model:** `WindowInfo` (`Utilities/Window Management/WindowInfo.swift:12-31`). It carries `lastAccessedTime`, `creationTime`, `isMinimized`, `isHidden`, `spaceID` and `image`.
  - Windows are cached per pid: `SpaceWindowCacheManager.windowCache: [pid_t: Set<WindowInfo>]` (`SpaceWindowCacheManager.swift:7`).
  - `groupAppInstancesInDock` merges sibling processes of one app (`Utilities/DockObserver.swift:419-428`). This is the macOS analogue of AppUserModelID grouping.
- **Order inside the flyout:** `enum WindowPreviewSortOrder` (`consts.swift:985`) has `recentlyUsed`, `creationOrder` ("Creation order (fixed)"), `alphabeticalByTitle` and `alphabeticalByAppName`.
  - It is set per context: `windowPreviewSortOrder`, `windowSwitcherSortOrder` and `cmdTabSortOrder` (`consts.swift:119/122/125`). The default is MRU.
  - `sortMinimizedToEnd` (`consts.swift:126`). The sort itself is `sortWindowsWithOptions` (`WindowUtil.swift:1779-1819`).
- **MRU:** `updateWindowDateTime` (`WindowUtil.swift:376-407`) stamps the focused window, skipping repeats within 1.5 s.
  - It is driven by app activation (`WindowManipulationObservers.swift:224`), by AX focus and main-window notifications (:447), and optimistically after DockDoor raises a window itself (`WindowInfo.swift:478`).
  - The order survives relaunch via `WindowOrderPersistence` (keyed `bundleId|title`; `WindowOrderPersistence.swift:5-49`).
- **Dock-icon click** (`DockObserver.swift:1015-1100`): it **never cycles**.
  - Optionally, if the app is frontmost, a click hides the app or minimizes all its windows (`dockClickAction`, `consts.swift:41`, `:759`).
  - `restoreAllMinimizedWindowsOnDockClick` (`consts.swift:42`) restores *all* minimized windows (`DockObserver.swift:1125-1138`).
  - Shift+click opens a new window (`DockObserver.swift:919-924`).
  - The preview can open on hover, middle-click or modifier-click (`dockPreviewActivationMode`, `consts.swift:115/775`).
- **Flyout items:**
  - click → un-minimize or unhide, then `bringToFront()` (`Views/Hover Window/WindowPreviewInteractionModifier.swift:102-128`); Shift+click → new window;
  - **middle-click → close** (`middleClickAction`, default `.close`, `consts.swift:331`);
  - traffic-light buttons on every entry (`consts.swift:214`).
  - Keyboard: Tab and arrows (with vim keys as an option), Return selects, Esc closes, and ⌘W/⌘M/⌘Q are configurable (`Utilities/KeybindHelper.swift:1096-1160`).
- **No Screen Recording, or "compact mode":**
  - `shouldUseCompactMode = disableImagePreview || !hasScreenRecordingPermission` (`Views/Hover Window/WindowPreviewHoverContainer.swift:178-195`).
  - Compact mode shows **rows of icon + title + state label + traffic lights** (`Views/Hover Window/WindowPreviewCompact.swift`). A single window that has no image also falls back to a row (`WindowPreviewHoverContainer.swift:1154`).
  - **Count threshold to switch to the list:** `dockPreviewCompactThreshold` (`consts.swift:145-147`). This is Windows' `NumThumbnails` idea.
  - Title format: `compactModeTitleFormat` = `appNameAndTitle` / `titleOnly` / `appNameOnly` (`consts.swift:139`, `:1152`).
  - "Minimized" and "Hidden" labels (`showMinimizedHiddenLabels`, `consts.swift:217`), and an optional Space number (`showSpaceNumber`, `consts.swift:218`).
- **Per-app cycling:** a second switcher shortcut with `SwitcherInvocationMode.activeAppOnly` (`consts.swift:353-355`, `:1017`). Cmd-Tab add-on keys cycle the selected app's windows (`KeybindHelper.swift:692-722`).

### 2.3 AltTab (`refs/alt-tab-macos`, 240e3ff)

AltTab is a switcher, but its preferences are a ready-made vocabulary for groups. All of them are in `src/preferences/MacroPreferences.swift` and are set per shortcut.

- **`GroupAppsPreference`** (:243, key `showAppsOrWindows`): `.mainWindow` ("Show one window per app") or `.allWindows`.
  - Applied in `src/switcher/state/Windows.swift:128-150`.
  - **The representative window** is picked by `ApplicationRepresentativeResolver.pick` (`src/switcher/state/WindowOrderResolver.swift:33-49`). Its preference order: the window currently needing attention, then the session-stable choice, then the last-attended window, then the main window, then the lowest `lastFocusOrder`. This is the best model for "which window does a group click or ⌘N activate".
- `WindowOrderPreference` (:155): `.recentlyFocused`, `.recentlyCreated`, `.alphabetical`, `.space`.
- `AppsToShowPreference` (:171): `.all`, `.active`, `.nonActive`, …. Shortcut 2 defaults to `.active`, a ⌘`-style mode for "windows of the active app".
- `ShowHowPreference` for minimized, hidden and fullscreen windows: `.show`, `.hide`, `.showAtTheEnd`.
- `AppearanceStylePreference`: `.thumbnails`, `.appIcons`, `.titles`.
- **MRU:** `TrackedWindowState.focusedAt` → `lastFocusOrder` (`src/switcher/state/TrackedWindowState.swift:121-125`, :640-656).
- **Without Screen Recording:** the thumbnail slot shows the app icon (`TileView.swift:316-327`).

### 2.4 Other open-source macOS taskbars (GitHub MCP search; the `gh` CLI is not installed)

| Repo | ★ | Several windows of one app |
|---|---|---|
| ejbills/DockDoor | 6378 | Per-app flyout (above) |
| moonbai-studio/tungsten-edge | 552 | Per-window only (above) |
| adityaonx/AeroBar | 33 | Per-window "live window tabs". A "Tasks" dropdown lists windows grouped by app |
| nagisa77/OpenBoringBar | 24 | **One button per app** (`RunningAppItem` in `Core/Domain/Models/BarModels.swift`). Hover shows per-app previews (`Core/DisplayBar/DisplayPanelController.swift`). Click restores the first minimized window (`Core/Bar/BarManager.swift`). Its badge is a notification count, not a window count |
| glenreesor/HammerBar | 24 | Hammerspoon/TypeScript, Windows-like (not inspected) |
| bnjdpn/TaskLane | 1 | `enum GroupingMode { always, never, automatic }` in `TaskLane/Models/Settings.swift` mirrors Windows, but appears **unimplemented**: it is referenced only in settings, the settings UI and tests. Its real model is one item per app with a "N windows" popover (`TaskLane/Taskbar/WindowListPopover.swift`) |

**Takeaway:** nobody ships a per-window bar with a real Windows-style combine mode, especially not "when full". pane's design has to be original. Borrow DockDoor's flyout and fallback, AltTab's representative-window picker, and Tungsten Edge's insertion rules and title trimming.

---

## 3. Proposed engine design for pane

Constraint (from the user): **thumbnails are the primary flyout presentation.** They come from a separate small **capture-helper app** that holds the Screen Recording grant. The **title list** (app icon + AX title + state) is the fallback when the helper is missing or not permitted, and also the Windows-style overflow form when there are too many windows. The engine never depends on images. It produces an ordered entry model, and the UI decides how to render it.

### 3.1 Data model

```swift
/// Windows' AppUserModelID analogue: bundle ID, merging every pid of that bundle (DockDoor groupAppInstancesInDock).
public struct AppKey: Hashable { public let raw: String }   // bundleID ?? "pid:\(pid)"

public enum CombineMode: String, Codable { case always, whenFull, never }

public struct TaskbarGroup: Identifiable, Equatable {
    public var id: String { "app:\(key.raw)" }
    public let key: AppKey
    public let bundleID: String?
    public let appName: String
    public let pids: [pid_t]
    public let isPinned: Bool
    /// Display order: seat (creation) order. Stable, like Windows' button and thumbnail order.
    public let windows: [ManagedWindow]
    /// The same windows, most-recent first (from FocusHistory). Picks the activation target.
    public let mru: [CGWindowID]
    public var activeWindow: CGWindowID? { windows.first(where: \.isFocused)?.id }
    public var isActive: Bool { activeWindow != nil }
    public let needsAttention: Bool      // see 3.7
    /// AltTab-style representative: attention window, else MRU head, else the first non-minimized, else the first.
    public let representative: CGWindowID?
}

public struct TaskbarItem {             // extends today's struct (Taskbar.swift:75-90)
    public enum Kind: Equatable {
        case window(CGWindowID)            // an uncombined window button
        case group(AppKey, [CGWindowID])   // a combined button (≥1 window); seat-ordered ids
        case pinnedApp                     // pinned, no windows
    }
    // existing fields … plus:
    public let groupKey: AppKey
    public let windowCount: Int        // drives the stacked-tile look (≥2) and an optional badge
    public let showsLabel: Bool
    public let label: String           // window title (uncombined) or app name (combined in whenFull)
    public let groupIndex: Int         // 0-based app position: the ⌘N target
}

public struct TaskbarPresentation {
    public let items: [TaskbarItem]      // visible, in order
    public let overflow: [TaskbarItem]   // shown behind the "…" button (Windows 11 overflow)
    public let combined: Set<AppKey>
    public let itemWidths: [CGFloat]     // the widths the solver chose, so UI and solver agree
}
```

**Pipeline:** two pure functions, both unit-testable like today's `TaskbarLayout`:

1. `TaskbarLayout.groups(windows:pinned:appOrder:history:) -> [TaskbarGroup]`
   - **App order:** pinned apps in pinned order, then running apps in the persisted drag order `appOrder: [AppKey]`, and then any new app appended. This matches Windows and Tungsten Edge's `.sameAppSibling` rule, applied at app level.
   - **Windows inside a group** stay in seat order, so a new window lands **at the end of its app's run** and never between other apps. Today's function already guarantees that apps stay contiguous (`Taskbar.swift:99-115`).
   - Native tab groups count as one window (the inventory already folds them).
   - The virtual-desktop filter ("Only the Space I'm using / All Spaces") is applied **before** grouping, as in Windows.
2. `TaskbarLayout.present(groups:mode:metrics:availableWidth:previous:) -> TaskbarPresentation`
   - It turns groups into buttons according to the combine mode (3.2).
   - `previous` provides hysteresis.
   - Each display's bar calls it with its own mode (`primaryMode` / `otherBarsMode`) and with only the windows it shows ("all taskbars / main + where open / where open").

### 3.2 The combine modes and the "when full" solver

```swift
public struct TaskbarMetrics {
    var iconButton: CGFloat = 44        // icon-only button (Windows 11 is about 44 px at 100%)
    var labeledMin: CGFloat = 96        // icon + about 6 characters; below this a label is useless
    var labeledMax: CGFloat = 200       // Windows 10/11-like cap
    var spacing: CGFloat = 2
    var overflowButton: CGFloat = 32
    var measure: (String) -> CGFloat    // the UI's text width; the engine stays AppKit-free
    var hysteresis: CGFloat = 24        // extra room needed before un-combining
}
```

**Algorithm.** `W` is the width available to buttons, after Start, the tray and the clock.

1. **always:** every group becomes one icon-only button. If `count × iconButton > W`, move buttons to `overflow` from the right, but **never move the active group, or a group needing attention**: swap it into the last visible slot (Windows' choice here is unknown; see open questions).
2. **never:** every window becomes one labeled button.
   - Width per button = `clamp(measure(label) + chrome, labeledMin, labeledMax)`. If the sum exceeds `W`, shrink everything evenly down to `labeledMin`.
   - If it still does not fit, move whole **app runs** to overflow from the right, keeping the active app's run visible.
3. **whenFull:**
   - a. Try `never` widths. If ≤ W → done.
   - b. Shrink to `labeledMin`. If it fits → done.
   - c. **Collapse groups one at a time** until it fits. The candidates are apps with ≥2 windows. Order them by `GroupCollapsePolicy`: `.oldestFirst` (by min seat; the XP and Windows 7 default) or `.largestFirst` (TaskbarGroupSize=1).
     - A collapsed group becomes **one labeled button showing the app name** (it keeps the label, unlike Always) and carries the stacked-tile look. Its width = `clamp(measure(appName) + chrome, labeledMin, labeledMax)`.
     - After each collapse, re-run the even shrink.
   - d. If every multi-window group is collapsed and it still does not fit → drop labels (icon-only) on the collapsed groups, then on singles. If it still does not fit → overflow as in Always.
   - e. **Hysteresis:** a group collapsed in `previous` is expanded again only when the expanded layout fits within `W - hysteresis`. This stops opening one window from flapping the whole bar.
   - f. Prefer collapsing groups that **do not** contain the active window, so the window you are working in keeps its own labeled button. This is a pane refinement and is off when `strictWindows` is set.
4. The output records `itemWidths`, so the UI renders exactly what the solver assumed.

### 3.3 Order inside a group: MRU vs seat

| Use | Order | Why |
|---|---|---|
| Uncombined buttons, flyout entries, Restore all | **Seat** (creation) | Matches Windows. Positions don't jump, so muscle memory works |
| Group click target, ⌘N first press, ⌘⌃N, LastActiveClick | **MRU head** (`FocusHistory.sorted(group.windows).first`) | "Last active window" [MS] |
| ⌃-click and ⌘N repeats (cycling) | **Start at the MRU head, then step through seat order** (wrapping) | Stepping through MRU would ping-pong between the two most recent windows, because each focus re-sorts the list. Seat order visits every window once. `GroupCycle` keeps `(key, anchorSeatIndex)` and resets when the modifier is released or after 1.5 s idle |
| Optional flyout sort setting | `seat` (default) or `mru` | DockDoor offers both |

`FocusHistory` (`Switcher.swift:6`) is already the MRU source. Add `history.note(wid)` wherever the taskbar focuses a window, as the switcher does. Optionally persist the order like DockDoor's `WindowOrderPersistence`, keyed `bundleID|title`.

### 3.4 Flyout model (UI-agnostic)

```swift
public struct GroupFlyout {
    public enum Presentation { case thumbnails, list }
    public struct Entry { let wid: CGWindowID; let title: String; let isActive, isMinimized, isHidden, isOnOtherSpace: Bool; let spaceLabel: String? }
    public let group: AppKey
    public let entries: [Entry]            // seat order (or MRU per setting)
    public let presentation: Presentation
}
```

`presentation` is `.thumbnails` when all of these hold; otherwise it is `.list`:
- the capture helper is reachable and reports that it has permission;
- the number of entries is ≤ `thumbnailThreshold`, computed like Windows from the screen width ÷ (thumbnail width + gap), with an optional user cap like `NumThumbnails` / DockDoor's `dockPreviewCompactThreshold`;
- the flyout fits on the display.

Every list row shows: app icon, AX title (with the app-name suffix and shared affixes trimmed, as Tungsten Edge does), and a state tag ("Minimized", "Hidden", "Desktop 2").

**Thumbnails come from the helper.** The helper uses ScreenCaptureKit (or `CGSHWCaptureWindowList` for minimized and other-Space windows) and serves cached images keyed by `CGWindowID` over XPC or a Mach port. The engine API stays `Capture.thumbnail(wid)` (`Sources/PaneKit/Capture.swift:10`), re-pointed at the helper.
- If a thumbnail is missing, that entry shows an app-icon placeholder (AltTab `TileView.swift:316-327`). It does not drop the whole flyout to the list.
- The flyout opens **instantly with placeholders** and fills in images as they arrive, so hover latency does not depend on capture.

**Peek** (hovering an entry for about 500 ms):
- With the helper: an overlay window at the target's frame shows a larger capture, with the rest of the screen dimmed. This is the closest match to Aero Peek's "other windows turn to glass", and it activates nothing.
- Without the helper: draw a highlight rectangle and the title at the window's frame (AX frame from inventory).
- Never actually raise the window. Raising would change the z-order and the MRU order.

### 3.5 Click, keyboard and menu semantics (⌘ = Win, ⌥ = Alt, ⌃ = Ctrl, ⇧ = Shift)

"Thumbs?" says whether thumbnails are involved: **Pri** = a thumbnail flyout is the primary UI and the title list is the fallback; **—** = no images involved.

| # | Windows input | pane input | Target | Engine action | Thumbs? |
|---|---|---|---|---|---|
| 1 | Click, pinned, no windows | Click | Group | `launch(bundleID)` | — |
| 2 | Click, 1 window | Click | Group/window | Today's `TaskbarActions.click`: focus, or minimize if active (restore if minimized; unhide if hidden) | — |
| 3 | Click, ≥2 windows (default) | Click | Combined group | **Toggle the flyout**, pinned open with keyboard focus. Activates nothing | Pri |
| 4 | Click, ≥2, `LastActiveClick` | Click (setting `groupClick = .lastActive`) | Combined group | If the MRU head is not active → focus it; else cycle as in row 5 | — |
| 5 | Ctrl+click group | **⌃-click** | Combined group | `GroupCycle.next`: the MRU head first, then seat order. No flyout | — |
| 6 | Shift+click / middle-click | ⇧-click / middle-click | Any | Today's `TaskbarActions.middleClick`: AX "New Window", else a new instance | — |
| 7 | Shift+right-click a group | **⇧-right-click** | Combined group | Group window menu: **Cascade / Show windows stacked / Show windows side by side** (pane `Placement` tiles the group's visible windows on the bar's display), **Restore all windows** (un-minimize + unhide all, seat order, MRU head on top), **Minimize all windows**, **Close all windows** (AX close each window; save sheets may stay open) | — |
| 8 | Shift+right-click a window button | ⇧-right-click | Window | Window menu: Restore / Move / Size / Minimize / Maximize / Close, mapped to pane's window ops | — |
| 9 | Right-click | Right-click | Any | Jump list (3.6) | — |
| 10 | Hover a group | Hover (delay about 400 ms, configurable) | Combined group | Show the flyout (transient: closes when the pointer leaves the button and flyout region) | Pri |
| 11 | Hover a window button | Hover | Window | A single-entry flyout (one thumbnail; without the helper, a title tooltip) | Pri |
| 12 | Hover a flyout entry | Hover | Entry | Peek (3.4) | Pri (frame-highlight fallback) |
| 13 | Click a flyout entry | Click | Entry | Focus that window (cross-Space switch if needed); if it is already active → minimize [obs]; close the flyout; `history.note` | — |
| 14 | Middle-click an entry | Middle-click | Entry | Close that window (Windows and DockDoor default) | — |
| 15 | × on an entry | Click × | Entry | Close that window; the flyout stays open and re-lays out | — |
| 16 | Right-click an entry | Right-click | Entry | Window menu (as row 8) | — |
| 17 | Win+N | ⌘N (`winNumbers`) | Group N (**app position**, not window) | 0 windows → launch. 1 window → as row 2. ≥2 → focus the MRU head and **show the flyout while ⌘ is held**; each further tap of N while ⌘ is held = `GroupCycle.next`; releasing ⌘ commits and closes the flyout | Pri (flyout is a hint; works without it) |
| 18 | Win+Shift+N | ⌘⇧N | Group N | New window / instance (row 6) | — |
| 19 | Win+Ctrl+N | ⌘⌃N | Group N | Focus the MRU head ("last active window"). No cycling, no flyout | — |
| 20 | Win+Alt+N | ⌘⌥N | Group N | Open group N's jump list, keyboard-focused | — |
| 21 | Win+T / Win+Shift+T | Proposed **⌃⌘T / ⌃⇧⌘T** (⌘T is "new tab" everywhere) | Bar | Keyboard focus on the bar's buttons: ←/→ move; on a group, ↑ or hover-equivalent opens its flyout and ←/→ move through entries; Return activates; ⇧F10 or the context-menu key opens the jump list; Esc leaves | Pri |
| 22 | Flyout keyboard | ←/→ (↑/↓ in list mode), Return, Esc, ⌘W closes the entry | Flyout | Same actions as rows 13-15 | — |
| 23 | Drag a button | Drag | Group | Reorder whole app groups; persist `appOrder`; dropping between pinned apps changes the pinned order only for pinned apps | — |

**⌃-click caveat:** on macOS, ⌃-click conventionally means right-click.
- pane's own `NSView` gets `mouseDown` with `.control`, so ⌃-click as "cycle" is implementable.
- Some users will expect a context menu. Offer `ctrlClick = .cycle (Windows) | .contextMenu (macOS)`, defaulting to `.cycle` to match the Windows model.
- ⌥-click is free and can serve as an alias for cycling.

### 3.6 Jump list on macOS

Menu order:
1. **Recent documents.** Read them from the app's shared file list (`~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/<bundleID>.sfl*`), as Tungsten Edge's recents do.
   - Alternatively, use the real Dock item's AX menu: pane keeps a small real Dock under the bar, so `AXShowMenu` on the Dock tile, or reading its menu items, can expose the app's own Dock menu.
2. **The app's name** → new window (row 6).
3. **Pin to taskbar / Unpin from taskbar.**
4. **Quit** and Force Quit.
   - Quit is a macOS addition with no Windows equivalent, because Windows has no separate app lifetime. Keep it below a separator, since pane's lifecycle quits on the last window anyway.
5. **Close window** if the group has 1 window, **Close all windows** if it has ≥2.

### 3.7 Visuals and attention, mapped

- **Indicator:** the Windows 11 pill. Short and grey when running, long and accent-colored with a lighter backplate when active.
- **Stacked-tile edge** when `windowCount ≥ 2` on a combined button. This is a Windows 10 cue that Windows 11 users ask for.
- **Optional window-count badge.** Off by default, because Windows has none.
- **Attention:**
  - macOS has no `FlashWindowEx` that other processes can see.
  - Signals pane can read:
    1. the Dock tile's AX `AXStatusLabel` badge (Tungsten Edge `Platform/Accessibility/DockBadgeReader.swift`); this works because pane keeps a real Dock;
    2. a window that becomes key without pane activating it while it sits behind another window. This one is weak.
  - Attention is **per app** on macOS (`requestUserAttention`), so it maps naturally to the group button. On uncombined buttons, mark the app's MRU head.
  - Badges are app status (like Windows overlay icons), not attention. Show them as an overlay, not a flash.

### 3.8 Edge cases

- **Hidden apps (⌘H):** treat them as minimized. Clicking unhides the app and focuses the target.
- **Windows on other Spaces:** follow the "show windows from: this Space / all Spaces" setting. Activating one switches Space, as the existing `Focus.focus(wid:pid:)` path does. The flyout tags them "Desktop N".
- **Several pids under one bundle** (Chrome profiles are one pid; some Electron apps or `open -n` instances are several): one group. Shift+click a group with several pids → new window in the MRU head's pid.
- **Combine-state transitions** must keep button identity stable. Use `win:<id>` for windows and `app:<key>` for groups, so the UI can animate the merge instead of rebuilding.
- **⌘N targets apps.** `activateTaskbarItem` must index `groupIndex`, not `items`. This is a behavior change from today's code.

---

## 4. Open questions

1. **Windows 11 collapse order in "When full"**: oldest-first or largest-first? Does it collapse apps one at a time or all at once? Does a collapsed group keep the app-name label (as in Windows 10)? Verify on 24H2/25H2.
2. **Windows 11 overflow**: does the active or most recently opened app get swapped into the visible area, or does it stay in the "…" menu? (Proposed: keep the active app visible.)
3. **Stacked-tile look in Windows 11**: confirm that it is absent. Decide whether pane copies Windows 11 (no cue) or Windows 10 (tiles). Recommendation: tiles.
4. **Clicking the active window's thumbnail minimizes it** [obs]: confirm on Windows 11.
5. **In Never mode, does ⌃-click on a single window button cycle through the app's windows?** Does Win+N count apps or buttons? I believe it counts apps. Verify.
6. **⌘T conflict for Win+T**: pick ⌃⌘T or another chord. Also, ⌘1…9 is still a deferred, off-by-default decision (`HotkeyService.swift:14-15`).
7. **⌃-click default**: Windows cycle or macOS context menu.
8. **Capture-helper contract**: transport (XPC with a shared Mach service, or a launch agent), cache size and refresh policy, how pane learns the helper's permission state, and how minimized and other-Space windows are captured.
9. **Peek realism**: is an overlay capture enough, or should pane really dim other windows? Dimming needs a full-screen overlay per display, which is cheap but must sit above every other window.
10. **Attention signal quality**: Dock bounce is not exposed via AX as far as I know. Investigate the Dock tile's AX attributes during `requestUserAttention`.

---

## Sources

- Microsoft, Keyboard shortcuts in Windows (taskbar section): https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec
- Windows Insider blog, Build 23466 (never combined mode): https://blogs.windows.com/windows-insider/2023/05/24/announcing-windows-11-insider-preview-build-23466/
- Windows Insider blog, Build 25163 (taskbar overflow): https://blogs.windows.com/windows-insider/2022/07/20/announcing-windows-11-insider-preview-build-25163/
- Engineering Windows 7, "The Windows 7 Taskbar" (grouping, stacked tiles, thumbnails, Peek, rearrange): https://learn.microsoft.com/en-us/archive/blogs/e7/the-windows-7-taskbar
- Microsoft UX guide, Taskbar (grouping guidance, flashing, jump lists, overlays): https://learn.microsoft.com/en-us/windows/win32/uxguide/winenv-taskbar
- The Old New Thing, "How do I minimize a group of windows…" (Shift+right-click group menu): https://devblogs.microsoft.com/oldnewthing/20091229-00/?p=15493
- Pureinfotech, labels and never combine on Windows 11 (setting names, TaskbarGlomLevel): https://pureinfotech.com/taskbar-never-combine-apps-show-labels-windows-11
- BleepingComputer, hands-on with never combine: https://www.bleepingcomputer.com/news/microsoft/hands-on-with-windows-11s-never-combine-taskbar-feature
- Pureinfotech, flashing apps on Windows 11 (red pill and backplate): https://pureinfotech.com/disable-flashing-apps-taskbar-windows-11/
- Winaero, switch app windows without thumbnails (LastActiveClick, Ctrl+click): https://winaero.com/make-the-windows-10-taskbar-switch-app-windows-without-clicking-on-thumbnails
- Winaero, taskbar thumbnail threshold (thumbnails → list): https://winaero.com/taskbar-thumbnail-threshold-list-windows-10
- Microsoft Q&A, list instead of thumbnail in Windows 11 (NumThumbnails no longer works): https://learn.microsoft.com/en-us/answers/questions/2279527/make-taskbar-show-list-instead-of-thumbnail-in-win
- Microsoft Q&A, one-click switch to the app with several windows: https://learn.microsoft.com/en-us/answers/questions/1660732/switch-to-app-with-multiple-open-windows-after-one
- Elevenforum, ExtendedUIHoverTime (24H2 note): https://www.elevenforum.com/t/registry-key-extendeduihovertime-to-modify-hover-time-for-showing-taskbar-thumbnail-previews.24693/
- Elevenforum, close window in Windows 11 (middle-click a thumbnail): https://www.elevenforum.com/t/close-window-in-windows-11.39530/
- Anoop C Nair, middle button with taskbar app icons: https://www.anoopcnair.com/?p=81707
- Wikipedia, Windows key (Win+N repeated presses cycle; Win+T): https://en.wikipedia.org/wiki/Windows_key
- Sony KB, Group Similar Taskbar Buttons (XP "when full" semantics): https://www.sony-asia.com/electronics/support/articles/S500010777
- ghacks, Customize group similar windows (TaskbarGroupSize): https://www.ghacks.net/?p=1743
- MS Tech Community, window count on the Windows 11 taskbar: https://techcommunity.microsoft.com/t5/windows-11/could-win11-show-how-many-windows-are-open-on-the-taskbar/m-p/4546282
- Windows Latest, End task in the taskbar menu: https://windowslatest.com/2023/04/08/microsoft-is-bringing-task-managers-end-process-feature-to-taskbar-menu
