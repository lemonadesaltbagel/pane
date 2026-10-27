# Snapping, Maximize/Restore and Window Placement on macOS: Source Study

How Rectangle, Loop and easy-move-resize put Windows feature (4) (true Maximize state, double-click title bar, Aero Snap, Snap Layouts, Win+Arrow) on top of macOS.

Repos studied (shallow clones in `refs/`):

| Repo | Commit | Date | Language |
|---|---|---|---|
| `refs/Rectangle` (rxhanson/Rectangle) | `5818987` | 2026-10-17 | Swift, MASShortcut |
| `refs/Loop` (MrKai77/Loop) | `573ace3` | 2026-10-13 | Swift/SwiftUI, Defaults, Scribe, Subsurface |
| `refs/easy-move-resize` (dmarcotte) | `ad1615b` | 2026-05-10 | Objective-C, about 900 LOC |

All paths below are relative to the repo root (for example `Rectangle/AccessibilityElement.swift` means `refs/Rectangle/Rectangle/AccessibilityElement.swift`). Line numbers refer to the commits listed above.

---

## 1. Overview

macOS has no public API that sets *another* app's window state. The three projects all use the same basic method:

1. Find a target window as an `AXUIElement`: the focused window of the frontmost app, or the window under the cursor.
2. Read and write the window's `kAXPositionAttribute` and `kAXSizeAttribute`. Both use **top-left-origin global coordinates** whose origin is the top-left of the primary display.
3. Compute the target frame from an `NSScreen` work area (`visibleFrame`, which excludes the menu bar and Dock, plus corrections). `NSScreen` uses **bottom-left-origin Cocoa coordinates**, so every write needs a flip.
4. Keep **per-window history** in memory, keyed by `CGWindowID` (obtained through the private `_AXUIElementGetWindow`), to emulate "restore", "cycle on repeat" and "unsnap on drag".
5. For drag snapping, watch global mouse events (`NSEvent` global monitors or `CGEventTap`), work out which window is being dragged, show a borderless overlay window as the preview, and apply the frame on mouse-up.

"Maximize" in all three is **only a frame**: `visibleFrame`, with optional gaps. The OS knows nothing about it. macOS has no "maximized" flag (`AXZoomed` exists, but it is app-defined zoom). That is why every project keeps its own history to decide whether a window is still maximized. In practice, a window counts as maximized when its current frame equals the frame recorded after the last maximize.

---

## 2. Per-repo architecture

### 2.1 Rectangle

```
ShortcutManager (MASShortcut, Carbon hotkeys) ─┐
SnappingManager (drag-to-edge)                 ├─► NotificationCenter(WindowAction.notificationName, ExecutionParameters)
TitleBarManager (double-click title bar)       │        │
GreenButtonManager (override green button)     │        ▼
Menu / URL scheme ─────────────────────────────┘   WindowManager.execute()
                                                     ├─ AccessibilityElement.getFrontWindowElement()
                                                     ├─ ScreenDetection → UsableScreens (current/adjacent screens)
                                                     ├─ WindowHistory (restoreRects / lastRectangleActions / preMaximizeRects)
                                                     ├─ WindowCalculationFactory[action].calculate()  (Cocoa coords)
                                                     ├─ GapCalculation
                                                     └─ WindowMover chain  or  WindowAnimator (experimental)
```

- Entry point for every action: `WindowManager.execute` (`Rectangle/WindowManager.swift:57-332`).
- Sources tag each request: `ExecutionSource { keyboardShortcut, dragToSnap, menuItem, url, titleBar }` (`WindowManager.swift:469-471`). For example, drag snaps pass `updateRestoreRect: false` (`WindowAction.swift:205-208`).
- There is one calculation class per action (`WindowCalculation/*.swift`, about 60 files). They work in Cocoa coordinates against `adjustedVisibleFrame`.

### 2.2 Loop

```
KeybindTrigger (ActiveEventMonitor on keyDown/keyUp/flagsChanged, "trigger key" = fn by default)
MiddleClickTrigger / MultitouchTrigger (Subsurface)          ─► LoopManager.openLoop()/changeAction()/closeLoop()
MouseInteractionObserver (mouse angle → radial-menu slice)  ─┘         │
                                                                       ▼
WindowDragManager (drag-to-edge snapping) ──────────────► WindowActionEngine.apply(ResizeContext)
                                                              └─ WindowEngine.performResize()
                                                                   ├─ WindowRecords (actor; initialFrame + action stack)
                                                                   ├─ WindowFrameResolver (target frame)
                                                                   ├─ SystemWindowManager (macOS 15 "Move & Resize" menu)
                                                                   └─ Window.setFrame / setFrameAnimated (WindowTransformAnimation)
```

- Loop is **modal**. Pressing the trigger key opens an overlay: a radial menu plus a preview of the target frame. Arrow keys, mouse direction or clicks pick an action, and releasing the trigger key applies it (`Core/LoopManager.swift:254-391`).
- A `ResizeContext` carries the window, the screen, the action and cached AX properties (`Window.ResolvedProperties`, `Window Management/Window/Window.swift:643-665`), which reduces AX IPC round trips.

### 2.3 easy-move-resize

- One file, `easy-move-resize/EMRAppDelegate.m`. It has one `CGEventTap` callback (`:35-285`) and a singleton state holder, `EMRMoveResize`.
- It has no snapping, no history and no maximize. Its only job is "modifier + drag anywhere in a window moves or resizes it".

---

## 3. Feature → mechanism table

| Feature | Rectangle | Loop | easy-move-resize |
|---|---|---|---|
| Target window (keyboard) | Frontmost app → `AXFocusedWindow`, then first `AXWindows`, then system-wide `AXFocusedUIElement`→`AXWindow`, then top of `CGWindowList` (`AccessibilityElement.swift:426-448`) | Frontmost app `AXFocusedWindow`, or the window under the cursor if that option is on (`Window/WindowUtility.swift:17-64`) | n/a |
| Window under cursor | `CGWindowList` hit test (level < 21, alpha > 0, not Dock/WindowManager), else `AXUIElementCopyElementAtPosition`; can be pinned to the event's own window id (`AccessibilityElement.swift:495-577`) | SkyLight `SLSFindWindowByGeometry` → `CGWindowList` → AX, then AX hit test, then a frame scan of `CGWindowList` (`WindowUtility.swift:69-106`) | `AXUIElementCopyElementAtPosition` → `AXWindow` (`EMRAppDelegate.m:87-105`) |
| Window ID | `_AXUIElementGetWindow` (bridging header); falls back to a frame match, then a derived hash id (`AccessibilityElement.swift:276-301`) | `_AXUIElementGetWindow` via `@_silgen_name` (`Private APIs/PrivateApis.swift:27-31`) | not used |
| Set frame | size → position → size, with Enhanced-UI toggling (`AccessibilityElement.swift:157-228`) | [size →] position → size, with Enhanced-UI toggling; one retry if the result differs (`Window.swift:515-546`, `WindowEngine.swift:182-214`) | Raw `AXUIElementSetAttributeValue`, throttled to the display refresh rate |
| Coordinate flip | `CGRect.screenFlipped` against `NSScreen.screens[0].frame.maxY` (`Utilities/CGExtension.swift:5-24`) | `flipY(screen: .screens[0])` plus `CGDisplayBounds` (`Extensions/NSScreen+Extensions.swift:49-93`) | Works purely in AX space |
| Work area | `adjustedVisibleFrame`: visibleFrame + stale-Dock correction via Dock AX + Stage Manager strip + Todo sidebar + edge gaps + notch gap (`ScreenDetection.swift:405-465`) | `cgSafeScreenFrame`: visibleFrame (− Stage strip) moved to `CGDisplayBounds` origin + padding/notch (`NSScreen+Extensions.swift:49-80`, `PaddingConfiguration.swift:39-55`) | n/a |
| Maximize | `MaximizeCalculation` returns `visibleFrameOfScreen` (`WindowCalculation/MaximizeCalculation.swift:5-17`) | `frameMultiplyValues` = full bounds; can instead press the macOS 15 Window ▸ Fill menu item | n/a |
| Restore | `restoreRects[windowId]` + `.restore` action; opt-in "repeat maximize = restore" via `preMaximizeRects` (`WindowManager.swift:75-102`, `RepeatedMaximizeRestore.swift`) | `WindowRecords` initialFrame + action stack; `.undo` re-resolves the previous action, `.initialFrame` returns the first frame (`WindowRecords.swift`, `WindowFrameResolver.swift:221-226, 429-453`) | n/a |
| Double-click title bar | `TitleBarManager`: passive monitor, clickCount 2, AX title-bar geometry, only when the system `AppleActionOnDoubleClick == "None"`; toggles to `.restore` (`TitleBarManager.swift`) | none | none |
| Green button | `GreenButtonManager`: active tap swallows clicks on `AXFullScreenButton` and runs maximize/restore instead of native full screen | none | none |
| Drag-to-edge | `SnappingManager` + `SnapEdgeDetection`; 8 directional areas, compound areas, preview `FootprintWindow` | `WindowDragManager` + `WindowDirection.getSnapDirection`; percentage zones along each edge with thirds cycling | none |
| Drag snapped window off = restore size | `unsnapRestore` (`SnappingManager.swift:460-490`) | `restoreWindowFrameOnDrag` (`WindowDragManager.swift:230-261`) | none |
| Repeat-shortcut cycling | `SubsequentExecutionMode` + `CycleSize` (½ → ⅔ → ⅓) + across-display mode | Explicit `cycle:` arrays per keybind (`WindowAction+Defaults.swift`) + `CycleActionCoordinator` | none |
| Next display | `NextPrevDisplayCalculation` (proportional transfer, keeps maximize) | `.nextScreen` etc., proportional custom action or replays the last action (`LoopManager.swift:507-583`) | none |
| Animation | Experimental: `CADisplayLink`-driven worker writing AX frames at up to 60 Hz (`WindowAnimation/`) | `NSAnimation` subclass, 0.3 s ease-out, `frameRate` = refresh rate (`WindowTransformAnimation.swift`) | none (throttled live move) |
| Snap Layouts / picker | none (closest: configurable snap areas, `tileAll`, `cascadeAll`) | Radial menu (8 slices + centre) and gestures | none |
| Modifier + drag move/resize | none | none | Yes: `CGEventTap` at `kCGHIDEventTap`, consumes events |
| Stage Manager | Reads `com.apple.WindowManager GloballyEnabled/AutoHide`; reserves the strip width (190 pt); handles drags from the strip | Same defaults; reserves `stageStripSize` (150 pt) | none |
| macOS 15 tiling | Detects `EnableTilingByEdgeDrag` / `EnableTilingOptionAccelerator` / `EnableTopTilingByEdgeDrag`; offers to **write** them to false | Warns (tooltip); optionally *delegates* to the native "Move & Resize" menu items; syncs `enterMissionControlByTopWindowDrag` | none |

---

## 4. Deep dives

### 4.1 Getting the focused window and setting its frame

#### Rectangle

Focused window, with fallbacks (`Rectangle/AccessibilityElement.swift:426-448`):

```swift
static func getFrontWindowElement() -> AccessibilityElement? {
    if let appElement = getFrontApplicationElement() {          // NSWorkspace.frontmostApplication → AXUIElementCreateApplication
        if let focusedWindowElement = appElement.focusedWindowElement { return focusedWindowElement } // kAXFocusedWindow
        if let firstWindowElement = appElement.windowElements?.first { return firstWindowElement }    // kAXWindows[0]
    }
    if let fallbackWindow = getSystemWideFocusedWindowElement() { return fallbackWindow }             // systemWide kAXFocusedUIElement → kAXWindow
    if let firstWindowInfo = WindowUtil.getWindowList().first(...), let e = getWindowElement(firstWindowInfo.id) { return e }
    ...
}
```

Setting the frame. The AX API only lets you set position and size separately, so Rectangle does **size → position → size** (`AccessibilityElement.swift:154-163`):

```swift
/// To handle moving to different displays, we have to adjust the size then the position, then the size again
/// since macOS will enforce sizes that fit on the current display.
func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
    performFrameAdjustment {
        if adjustSizeFirst { size = frame.size }
        if adjustPosition { position = frame.origin }
        size = frame.size
    }
}
```

The newer `setImmediateFrame` (`:165-210`) is smarter about order and recovery:
- `ImmediateFrameOrder.sizeFirst` (`WindowMover/StandardWindowMover.swift:36-50`) picks size-first or position-first based on which intermediate frame overflows the screen less. A move across screens, or a window that starts off-screen, always goes size-first, because "moving an off-screen window first can make the system resize it against the Dock".
- After resizing it re-reads the real frame, positions using the *accepted* size, and if the size is still off it retries with `max(target, AXMinSize)` (`:179-203`).

Mover chain (`WindowManager.swift:19-28`, `:345-352`): `StandardWindowMover` (set the frame) → `EdgeAlignmentWindowMover` (if the app refused the size, re-align the window to the edges it should share, e.g. keep a too-big "right half" flush right; `WindowMover/WindowMover.swift:66-95`) → `BestEffortWindowMover` (push it back fully on-screen; `WindowMover/BestEffortWindowMover.swift:29-45`). Fixed-size windows (`AXUIElementIsAttributeSettable(kAXSize) == false`) use `FixedSizeWindowMover` (move only).

Cross-display retries (`WindowManager.swift:269-290`): after a move to another display, if the achieved size ≠ requested, it applies again immediately. If it is still wrong, it tries once more after 25 ms.

**AXEnhancedUserInterface workaround** (`AccessibilityElement.swift:212-228`, policy enum `:627-724`, default `.automatic` in `Defaults.swift:114-118`). Before writing, it reads `AXEnhancedUserInterface` on the *application* element. If true, it sets it false, performs the writes, then restores it according to policy. Chromium-family browsers (list at `:633-651`) are left disabled unless VoiceOver or Switch Control is on, because re-enabling it turns on Chromium's expensive accessibility tree. With Enhanced UI on, apps animate AX-driven frame changes, so a size → position → size sequence turns into a visible multi-step animation. That is why this matters.

Other details:
- `AXUIElementSetMessagingTimeout` caps blocking on hung apps (`AccessibilityElement.swift:337-339`; the title-bar path uses 10–40 ms).
- `AXMinSize` / `AXMinimumSize` are read to make retries feasible (`:144-147`).
- `bringToFront` sets `kAXMain = true`, then `NSRunningApplication.activate()` (`:403-410`). `raise()` = `kAXRaiseAction` (`:399-401`).

#### Loop

`Window` wraps the AX element plus `CGWindowID` and pid. It validates on init (`Window Management/Window/Window.swift:69-107`): it rejects sheets, windows whose SkyLight window level is outside `[kCGNormalWindowLevel, kCGMainMenuWindowLevel)`, windows with invalid SkyLight tags or a parent window, and PiP/Notification Center.

Frame write (`Window.swift:515-546`):

```swift
if enhancedUI { enhancedUserInterface = false }   // AXEnhancedUserInterface on AXUIElementCreateApplication(pid)
if sizeFirst, shouldSetSize { setSize(rect.size) } // sizeFirst = willChangeScreens
setPosition(rect.origin)
if shouldSetSize { setSize(rect.size) }
if enhancedUI { enhancedUserInterface = true }
```

`WindowEngine.resizeWindow` (`WindowEngine.swift:182-214`) re-reads the frame and, if it is not `approximatelyEqual` to the target, applies it once more. `handleSizeConstrainedWindow` (`:218-280`) handles windows that kept a different size (fixed aspect ratio, minimum size, etc.). It re-anchors the accepted size to the edges the target touched (`getEdgesTouchingBounds`), so a too-big left-half window stays flush left.

Loop's own windows can't be driven through AX in-process, so `isOwnWindow` routes those to `NSWindow.setFrame` (`Window.swift:406-419`, `:462-513`).

Loop exits native full screen before a resize (`WindowEngine.swift:80-83`: `window.fullscreen = false`, attribute `AXFullScreen`).

#### easy-move-resize

It works only in AX coordinates. It reads `AXPosition` and `AXSize` once on mouse-down and then accumulates `kCGMouseEventDeltaX/Y` itself, so it never re-reads during the drag (`EMRAppDelegate.m:126-139`, `:145-166`). Writes are throttled to the minimum display refresh interval (`:7-15`, `:27-30`, `:159`, `:257`).

### 4.2 Coordinate systems, multi-monitor, menu bar, Dock, notch

| Space | Origin | Y | Used by |
|---|---|---|---|
| AX / CG global (`kAXPosition`, `CGWindowList` bounds, `CGEvent.location`, `CGDisplayBounds`) | top-left of **primary** display | down | all window writes |
| Cocoa (`NSScreen.frame/visibleFrame`, `NSEvent.mouseLocation`, `NSWindow.frame`) | bottom-left of **primary** display | up | screen geometry, overlay windows |

The flip always uses the primary screen (`NSScreen.screens[0]`), never `NSScreen.main`:

- Rectangle (`Utilities/CGExtension.swift:11-24`): `y' = screens[0].frame.maxY − rect.maxY`. Calculations run in Cocoa space. `WindowManager.execute` flips the AX frame in (`:156`, `currentWindowRect.screenFlipped`) and the mover flips the result back out (`StandardWindowMover.swift:10`).
- Loop (`Extensions/CGGeometry+Extensions.swift:80-91`): `flipY(maxY:)`, same formula. Loop does the opposite and works in AX space. `cgSafeScreenFrame` (`NSScreen+Extensions.swift:49-64`) takes the flipped `visibleFrame` size and anchors it at `CGDisplayBounds(displayID).origin`, then adds `menubarHeight` (`frame.maxY − visibleFrame.maxY`, `:91-93`). Per the comment, this avoids multi-display errors.

**Choosing the screen:**
- Rectangle `screenContaining` (`ScreenDetection.swift:69-86`): the screen that fully contains the window, else the one with the largest intersection area. During an animation it uses the *destination* frame, so repeated presses route correctly (`:28-30`). Screens are ordered for next/prev by position (`order(screens:)`, `:125+`). Optional cursor-screen mode: `useCursorScreenDetection`.
- Loop `screenWithMouse` (`NSScreen+Extensions.swift:28-47`): asks SkyLight `SLSCopyBestManagedDisplayForPoint` first, "so we match WindowServer's tie-breaking at display boundaries". It falls back to an inclusive-edge contains check (`CGRect.contains` excludes maxX/maxY). Rectangle's `SnapEdgeDetection` makes the same inclusive-edge point (`Snapping/SnapEdgeDetection.swift:7-9`).

**Menu bar, Dock, notch:**
- Both start from `NSScreen.visibleFrame`, which already excludes the menu bar and the non-hidden Dock.
- Rectangle `DockUtil` (`ScreenDetection.swift:180-400`): "macOS can leave `NSScreen.visibleFrame` stale after Dock changes (#467)". It reads the live Dock frame from the Dock's AX tree (`AXUIElementCreateApplication(com.apple.dock)` → child `AXList` frame, 100 ms timeout, `:309-318`) and `autohide` via `CFPreferencesCopyAppValue` (`:302-307`), then rebuilds the inset on the correct edge (`correctedVisibleFrame`, `:248-300`). The top edge is never reclaimed ("The Dock cannot reserve the top edge. Preserve AppKit's menu bar/notch boundary", `:391`).
- Notch: Rectangle has a separate top gap when `safeAreaInsets.top != 0` (`ScreenDetection.swift:455-462`). Loop's `ignoreNotch` subtracts `menubarHeight` from the top padding (`PaddingConfiguration.swift:43-48`).
- Gaps: Rectangle `GapCalculation.applyGaps` with shared-edge awareness (`WindowManager.swift:170-174`). Loop `PaddingConfiguration` can mirror macOS 15's `EnableTiledWindowMargins` / `TiledWindowSpacing` (`SystemWindowManager.swift:140-147`, `PaddingConfiguration.swift:133-137`).

### 4.3 Remembering the restore frame (emulating a real Maximize state)

#### Rectangle: three maps keyed by CGWindowID (`Rectangle/WindowHistory.swift:5-13`)

```swift
var restoreRects       = [CGWindowID: CGRect]()          // the last window frame that the user positioned
var lastRectangleActions = [CGWindowID: RectangleAction]() // action + resulting AX rect + repeat count
var preMaximizeRects   = [CGWindowID: CGRect]()          // frame right before last Maximize / Almost Maximize
```

Algorithm (`WindowManager.swift:124-143`):

```swift
let currentWindowRect = pendingDestination ?? frontmostWindowElement.frame
var lastRectangleAction = AppDelegate.windowHistory.lastRectangleActions[windowId]
let windowMovedExternally = currentWindowRect != lastRectangleAction?.rect   // user moved/resized it since
if windowMovedExternally { lastRectangleAction = nil; lastRectangleActions.removeValue(forKey: windowId) }
if parameters.updateRestoreRect {
    if restoreRects[windowId] == nil || windowMovedExternally {
        restoreRects[windowId] = currentWindowRect        // snapshot the "normal" frame before Rectangle touches it
    }
}
```

Effects:
- The restore frame is captured **once**, before the first Rectangle action, and refreshed only when the user moved the window by hand in between. A chain such as left-half → maximize → right-half still restores to the original free-floating frame. This matches Windows' "restore bounds" semantics.
- "Is it still maximized?" is answered by `lastRectangleActions[id].action == .maximize && lastAction.rect == window.frame`. This exact test appears in the green button (`GreenButtonManager.swift:69-77`), the title bar (`TitleBarManager.swift:104-113`) and the repeat-maximize logic (`RepeatedMaximizeRestore.swift:47-59`).
- `.restore` (default shortcut ⌃⌥⌫, `WindowAction.swift:724, 746`) applies `restoreRects[id]` and clears the last action (`WindowManager.swift:75-102`).
- Opt-in `repeatedMaximizeRestoresPrevious` (`RepeatedMaximizeRestore.swift:15-67`): pressing Maximize on a window Rectangle just maximized returns `preMaximizeRects[id]`, reported as `.restore`, so the next press maximizes again. This gives a **Maximize/Restore toggle** on one key.
- The history is in memory only and keyed by `CGWindowID`, so it is lost on relaunch. Window ids are stable for the lifetime of a window.

Drag-time restore ("unsnap"). When the user drags a window that Rectangle placed (`lastAction.rect == initialWindowRect`), Rectangle immediately resizes it to `restoreRects[id].size` and keeps the grab point under the cursor (`SnappingManager.swift:460-490`, `DragRestorePlacement.frame`, `:68-86`). This mirrors Windows dragging a maximized window off the top edge. If the window was not placed by Rectangle, the drag start frame becomes its restore rect (`:487-489`). There is a retry path for when the Dock clamps the restored width mid-drag (`retryNativeSizeRestore`, `:498-525`; `finishNativeSizeRestore`, `:527-555`).

#### Loop: `WindowRecords` actor (`Window Management/Window Manipulation/WindowRecords.swift`)

```swift
struct Record { let initialFrame: CGRect; var actions: [WindowAction] }  // actions[0] = current, actions[1] = last
```

- `recordFirstIfNeeded` stores `initialFrame` the first time Loop touches a window (`:56-60`, called from `WindowEngine.swift:40-43`).
- Each action is pushed onto the front. Context-dependent actions (screen changes, grow/shrink) are stored as a synthetic **proportional custom action** computed from the resulting frame, so undo can replay them (`:65-70`, `:86-117`).
- `.undo` resolves `actions[1]` recursively through `WindowFrameResolver` (`WindowFrameResolver.swift:429-439`) and then pops (`WindowEngine.swift:110-111`). `.initialFrame` ("Initial Frame", the "restore" equivalent) returns `initialFrame` (`:446-453`).
- Any manual move or resize during a drag erases the records (`Core/WindowDragManager.swift:124-150`). The next Loop action then captures a fresh initial frame, giving Rectangle-like "restore bounds = last user-positioned frame".
- Loop has no built-in "maximize again toggles back" behaviour. You bind a cycle `[maximize, macOSCenter]` (the default radial centre action, `RadialMenuAction.swift:116-124`) or bind Undo / Initial Frame.

### 4.4 Drag-to-edge snapping (Aero Snap)

#### Rectangle `SnappingManager` (`Rectangle/Snapping/SnappingManager.swift`)

1. **Event source** (`:243-247`). It monitors `[.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]`. By default this is a `PassiveEventMonitor` (`NSEvent.addGlobalMonitorForEvents` + local monitor; `Utilities/EventMonitor.swift:12-47`). If "prevent Mission Control on drag" is enabled it uses an `ActiveEventMonitor` (a `CGEventTap` at `.cgSessionEventTap`, head insert, on its own run-loop thread; `EventMonitor.swift:49-138`). The active filter rewrites `cgEvent.location.y = minY + 1` when the cursor pins at the top edge, so the Dock never sees a top-edge window drag and doesn't open Mission Control (`SnappingManager.swift:256-277`; 25 px allowance and 250 ms timeout from `Defaults.swift:121-122`).
2. **Which window** (`:301-317`). On mouse-down it captures the cursor and `mouseEventWindowUnderMousePointerThatCanHandleThisEvent` from the CGEvent, the WindowServer's own answer for the clicked window. It resolves this to an AX element with `getWindowElementUnderCursor(at:eventWindowID:)` (`AccessibilityElement.swift:507-577`) and stores both the AX frame and the WindowServer frame (`CGWindowListCopyWindowInfo(.optionIncludingWindow)`, `Utilities/WindowUtil.swift:9-16`). If resolution fails, it retries during the drag up to 20 times at 100 ms intervals (`:367-381`).
3. **Is it a move?** `WindowDragGeometry` (`:23-66`) compares frames from the *same* source ("AX and WindowServer can disagree during a drag"). It counts as a resize if the size changed and ≥ 2 edges are shared. It counts as a move if only the origin changed. Only moves snap. A resize clears the window's last action (`:392-394`).
4. **Snap area detection** (`snapAreaContainingCursor`, `:682-710` → `SnapEdgeDetection.direction`, `Snapping/SnapEdgeDetection.swift:4-55`). For each screen frame (the full frame, including the menu bar area), it returns one of 8 `Directional`s:
   - Corners: within `margin + cornerSize` of both edges. Margins default to **5 pt** per edge (`Defaults.swift:27-30`). `cornerSnapAreaSize` defaults to **20 pt** (`:104`).
   - Edges: within the margin.
   - Optional `snapBeforeReachingEdges` widens the band, except on edges shared with a neighbouring display, so dragging across monitors still works (`SnapEdgeDetection.swift:22-48`).
   - Portrait and landscape screens have separate maps. Defaults (`Snapping/SnapAreaModel.swift:10-30`): corners → quarters, top → **maximize**, left/right → compound "half, or top/bottom half near corners" (short-edge band 145 pt, `Defaults.swift:105`; `CompoundSnapArea/HalvesCompoundCalculation.swift:5-55`), bottom → thirds with *drag back toward centre for two-thirds* (uses `priorSnapArea`, `ThirdsCompoundCalculation.swift:5-33`).
   - Optional required modifier (`canSnap`, `:279-291`). Windows in the Stage Manager strip are never snapped.
   - Esc during the drag cancels (`:295-300`).
5. **Preview overlay** (`showSnapPreview`, `:606-616`; `Snapping/FootprintWindow.swift`). A borderless, non-opaque `NSWindow` with `ignoresMouseEvents = true`, `collectionBehavior = [.transient, .ignoresCycle]`, level `.modalPanel` (`FootprintWindow.swift:153-166`), and an optional `NSVisualEffectView` blur. When blur is on, it is ordered **directly below the dragged window**: it adopts that window's level and calls `order(.below, relativeTo: windowID)` (`:367-385`). The preview rect is computed by the same calculation class as the action (`getBoxRect`, `:646-664`). It animates out from the edge or corner (`getFootprintAnimationOrigin`, `:623-644`). Optional haptics: `NSHapticFeedbackManager .alignment` (`:413-415`).
6. **Mouse-up** (`:318-362`). It recomputes the area from the release event's location (fast drags coalesce) and posts `action.postSnap(...)` with `source: .dragToSnap, updateRestoreRect: false`. If no preview was shown but the window did move and the cursor is in an area, it still snaps (`:334-351`).
7. **Disable conditions**: when the frontmost window is full screen (`checkFullScreen` on Space change, `:193-201`), for certain apps (`fullIgnoreIds`, `:90-95`), or when shortcuts are disabled for the front app.

#### Loop `WindowDragManager` (`Loop/Core/WindowDragManager.swift`)

- Uses listen-only `CGEventTap`s (`PassiveEventMonitor`, `.listenOnly`; `Utilities/Event Monitoring/PassiveEventMonitor.swift:54-57`) on `leftMouseDragged` and `leftMouseUp` (`:83-103`). It does **not** watch mouse-down. The window is resolved lazily on the first drag event with `WindowUtility.windowAtPosition(cursor)` (`:178-206`).
- Move detection (`:216-228`): "moved" requires **all four corners** to change by ≥ 10 pt (`approximatelyEqual` default tolerance). "Resized" requires any corner to change.
- Zones (`processSnapAction`, `:263-316`). An inner "ignored" rect is inset by `snapThreshold` (**2 pt**, `Extensions/Defaults+Extensions.swift:142`), or by `max(menubarHeight/2, inset)` at the top. Outside it, `WindowDirection.getSnapDirection` (`Window Action/WindowDirection+Snapping.swift:82-269`) maps the position along the edge to an action:
  - Left/right edge, by vertical position: < 1/95 → corner quarter; 1/95–6/95 → top half; 6/95–1/3 → top third; centre third → **left/right half**; mirrored for the bottom (`:136-178`).
  - Moving inside the centre zone after coming from a corner or third gives **two-thirds**, and moving past the midpoint ±5 % gives the centre third (`:180-235`). This is drag-time cycling, similar to Rectangle's thirds compound.
  - Top edge (`:238-269`): corners → quarters, outer 20 % → top half, centre 60 % → **maximize**.
  - Thirds are offered only along a screen's long axis unless the aspect ratio is near square (`:88-94`).
- Preview: `PreviewController` with an `NSPanel` of style `[.borderless, .nonactivatingPanel]`, `ignoresMouseEvents`, `.canJoinAllSpaces`, level `screenSaver − 1`, full-screen sized, with SwiftUI content (`Window Action Indicators/Preview Window/PreviewController.swift:44-60`).
- Mouse-up applies the context via `WindowActionEngine.apply` (`:154-176`).
- Mission Control: before macOS 15 it warps the cursor to `minY + 1` when it hits the top (`:133-142`). On 15+ it writes the Dock default `enterMissionControlByTopWindowDrag` (`:59-70`; `SystemWindowManager.swift:33-45`).
- Snapping is **off by default** in Loop (`windowSnapping` default false, `Defaults+Extensions.swift:47`).

### 4.5 Repeated-shortcut cycling, Win+Arrow equivalents, move to next display

**Rectangle**
- Behaviour on repeat is set by `SubsequentExecutionMode` (`SubsequentExecutionMode.swift:5-11`): `resize` (Spectacle-style; default), `acrossMonitor`, `acrossAndResize`, `cycleMonitor`, `resizeAndCycleQuadrants`, `none`.
- The counter lives in `RectangleAction.count`. It increments only when the same action repeats on an unmoved window (`WindowManager.swift:35-55`).
- `RepeatedExecutionsCalculation.calculateRepeatedRect` (`WindowCalculation/RepeatedExecutionsCalculation.swift:19-43`) indexes into `CycleSize.sortedSelectedSizes()`. Default sizes are {½, ⅔, ⅓}, ordered "start with ½, go upward, wrap to smaller" (`CycleSize.swift:20-48`). So Left Half pressed repeatedly gives ½ → ⅔ → ⅓ → ½.
- Across-monitor mode (`LeftRightHalfCalculation.swift:66-99`): pressing Left Half again when already left-halved moves the window to the previous screen's *right* half, which matches Windows Win+← behaviour across monitors.
- Default shortcuts: Spectacle set ⌘⌥←/→/↑/↓ halves, ⌘⌥F maximize; alternate set ⌃⌥←/→/↑/↓, ⌃⌥↩ maximize, ⌃⌥⌘→ next display, ⌃⌥⌫ restore (`WindowAction.swift:707-746`). Hotkeys are registered through MASShortcut (Carbon `RegisterEventHotKey`; `ShortcutManager.swift:5-31`). This needs no event tap, so Win-style shortcuts work without Input Monitoring.
- There is no built-in "Win+↓ = restore, then minimize" chain. `restore` exists, but minimize is not a Rectangle action.
- Next/prev display (`WindowCalculation/NextPrevDisplayCalculation.swift:7-74`): `DisplayTransfer.transferredRect` maps the frame proportionally. If the window shared all four edges (maximized), it re-maximizes on the target. With `attemptMatchOnNextPrevDisplay` it replays the last action (e.g. left half) on the new screen. Cross-display moves get `bringToFront(force: true)` and an optional cursor warp (`WindowManager.swift:354-362`).

**Loop**
- Cycling is explicit data: a `WindowAction` with `cycle: [...]`. Defaults (`Window Action/WindowAction+Defaults.swift:14-41`): with the trigger key held, ↑/↓/←/→ = "Top/Bottom/Left/Right Cycle" (half → third → two-thirds), Space = maximize, Return = centre, two arrows together = quarters.
- `CycleActionCoordinator` + `CycleProgressStore` track progress **per window** (`CycleActionCoordinator.swift:28-83`). Entering a cycle resumes from the window's recorded action unless `cycleModeRestartEnabled` is set. Shift steps backwards (`LoopManager.swift:650-679`). A left click while Loop is open advances the cycle (`MouseInteractionObserver.swift:224-251`).
- Screen moves (`LoopManager.swift:507-583`): `.nextScreen / .previousScreen / .leftScreen / .rightScreen / .topScreen / .bottomScreen` using `ScreenUtility` ordering. If the current action is a no-op or a grow/shrink, the window keeps its proportional frame (a synthetic custom action). Otherwise its last recorded action (e.g. left half) is replayed on the new screen.

### 4.6 Loop's trigger key, radial menu and animation (the closest thing to Snap Layouts)

- **Trigger key** (`Core/Observers/KeybindTrigger.swift:71-200`). An `ActiveEventMonitor` (a `CGEventTap`, `.cgSessionEventTap`, tail-append, `.defaultTap`; `ActiveEventMonitor.swift:27-31, 85-117`) on `keyDown/keyUp/flagsChanged`. `KeybindResolver` decides open, update or close, and whether to **swallow** the event. The default trigger is **fn/Globe** (`Defaults+Extensions.swift:63`). Options include side-dependent modifiers, double-press-to-trigger (`DoubleClickTimer`), trigger delay and a timeout. If the pressed set matches a system shortcut (e.g. screenshot), Loop force-closes and passes the event through (`:136-141`).
- **Radial menu** (`Core/Observers/MouseInteractionObserver.swift`). On open it records the cursor position. Then it computes the `angle` and `distance` of the cursor from that point on `mouseMoved`/`otherMouseDragged` (`:118-175`):
  - distance < 10 pt → no selection
  - 10–(50 − thickness) → the last action (centre: maximize/macOS-centre cycle)
  - beyond that → `index = (angleDeg + span/2) / span % N` over the 8 slices (`:141-151`)
  
  Near screen edges, where the cursor gets pinned, it integrates the raw `mouseEventDeltaX/Y` to keep selecting (`computeLatestMousePosition`, `:185-222`). Default slices (`Window Action/RadialMenuAction.swift:87-125`): quarters on the diagonals, side cycles on N/E/S/W, and the centre = `[maximize, macOSCenter]`. The panel is a `.screenSaver`-level non-activating `NSPanel` (`Radial Menu/RadialMenuController.swift:39-51`).
- **Preview vs live**. With `previewVisibility` on (the default), the preview panel shows the target and the window moves only when Loop closes (`LoopManager.swift:372-378`). With the preview off, every action change applies live (`:592-644`).
- **Animation** (`Window Manipulation/WindowTransformAnimation.swift`). An `NSAnimation` subclass, 0.3 s, `frameRate` = the main display's refresh rate, non-blocking (`:65-67`). It cancels any running animation on the same window (`:70-74`). Each tick interpolates with cubic ease-out and writes AX position/size (`:118-197`). It detects at runtime whether the app enforces fixed axes or a fixed aspect ratio, then switches to "anchored" frames so the window doesn't jitter (`:248-308`). When growing, it moves first so the window doesn't hit the screen edge (`:146-158`). Animation is skipped when Enhanced UI is on, in Low Power Mode, or when disabled (`WindowEngine.swift:166-178`; `animateWindowResizes` defaults to **false**).
- **Rectangle animation** (opt-in `experimentalWindowAnimations`, `Defaults.swift:17`). `WindowAnimator` runs a per-screen `CADisplayLink` (`NSScreen.displayLink`, macOS 14+) on main, with AX writes on a serial `.userInteractive` worker queue that drops stale frames (`WindowAnimation/WindowAnimator.swift:1-14`, `:295-313`). Duration is 0.24 s (`WindowAnimationCurve.swift:6`). Any user mouse-down cancels it. It is disabled with Reduce Motion, VoiceOver and Switch Control.
- **Snap Layouts / Snap Assist**: neither project has a Windows 11 hover flyout on the maximize button or a "pick the other half" assistant. The closest analogues are Loop's radial menu (a layout picker driven by a key) and Rectangle's configurable snap areas, plus `tileAll`/`cascadeAll`/`MultiWindow/GridTiling.swift`.

### 4.7 Double-click title bar and the green button

macOS already handles title-bar double-clicks itself, per the global default `AppleActionOnDoubleClick` (`Maximize` = Zoom, `Fill` on newer systems, `Minimize`, or `None`). Only Rectangle intercepts it.

**Rectangle `TitleBarManager`** (`Rectangle/TitleBarManager.swift`):
- Listens passively on `leftMouseDown/Up/Dragged, rightMouseDown, keyDown` (`:11`).
- **Acts only if the system action is disabled** (`:43`, `:116-120`), so it never fights the native Zoom/Fill:
  ```swift
  UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleActionOnDoubleClick") == "None"
  ```
- Trigger: `leftMouseUp` with `clickCount == 2`, deduplicated by `eventNumber` (`:40-42`).
- Hit test: `AXUIElementCopyElementAtPosition`, then descends to the smallest child containing the point (`getSelfOrChildElementRecursively`, `AccessibilityElement.swift:256-270`). **Title-bar frame = window frame origin, height = `2 × (closeButton.minY − window.minY) + closeButton.height`** (`AccessibilityElement.swift:346-362`). It unions the `AXToolbar` frame for unified toolbars (except apps on an ignore list), then accepts only clicks on roles `window/toolbar/group/tabGroup/staticText` or an empty toolbar `AXSplitter` "spacer" (`TitleBarManager.swift:59-73`; `AccessibilityElement.swift:77-97`).
- Tab-close veto: an `AXObserver` on `kAXValueChangedNotification` for the frontmost app, plus off-thread AX reads with 10–40 ms timeouts, detects that the first click hit a tab's close button. This stops "close two tabs fast" from counting as a title-bar double-click (`:122-374`).
- Toggle: `resolveAction` returns `.restore` if the configured action (e.g. maximize) was the last Rectangle action **and** the frame still matches, using the pending animation destination if one is running (`:104-113`). The action runs on the *clicked* screen (`:85-86`).

**Rectangle `GreenButtonManager`** (`Rectangle/GreenButtonManager.swift`): an `ActiveEventMonitor` (consuming event tap) on left down/up (`:11`). On an unmodified mouse-down over an element whose subrole is `AXFullScreenButton`, it **swallows** the down and the matching up so the app never enters native full screen. On release inside the button it runs maximize, or restore if it is currently Rectangle-maximized (`:33-79`). Option-click still reaches the app (`:37`).

Loop and easy-move-resize have neither. Loop's `DoubleClickTimer` is for double-pressing the trigger key.

### 4.8 easy-move-resize: modifier + drag anywhere

Event tap (`EMRAppDelegate.m:314-335`):

```objc
CGEventMask eventMask = CGEventMaskBit(kCGEventLeftMouseDown) | ... RightMouse* | OtherMouse* ... ;
CFMachPortRef eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                          eventMask, myCGEventCallback, (__bridge void *)self);
```

Callback flow (`:35-285`):

1. It ignores events while the login session is inactive (`NSWorkspaceSessionDidResign/BecomeActive`, `:46-48`, `:347-357`), and re-enables itself on `kCGEventTapDisabledByTimeout/UserInput` (`:63-67`).
2. Modifier match: all configured flags must be present, and **no extra** modifiers (`:69-80`). The default is ⌘⌃ (`EMRPreferences.m:3`).
3. **Mouse-down** (left = move, right or middle = resize; `:82-143`). It hit-tests with `AXUIElementCopyElementAtPosition(systemWide, x, y)`, takes the element itself if its role is `AXWindow`, else its `AXWindow` attribute (`:92-105`). It checks the per-app disable list by bundle id (`:108-117`). It optionally activates the app (`NSApplicationActivateIgnoringOtherApps`) and calls `kAXRaiseAction` (`:119-124`). It reads `AXPosition` once (`:126-139`).
4. **Resize mouse-down**: it splits the window into a 3 × 3 grid relative to the click. The left/right third chooses which X edge moves, top/bottom third which Y edge, and the middle means that axis stays fixed (`:168-211`). Naming quirk: `bottom` here means the AX-top edge, because the math is in AX top-left space.
5. **Drag**: `pos += kCGMouseEventDeltaX/Y` (`:145-166`). For resize it adjusts size, plus position when the left or top edge moves (`:213-271`). AX writes are rate-limited by `CACurrentMediaTime()` deltas against the refresh interval (`:159`, `:257`).
6. **Handled events return `NULL`** (`:279-284`). The target app never sees the modifier-click or drag. That is why this works "anywhere in the window", including over content that would otherwise take the drag.

The tap is placed at the HID level (`kCGHIDEventTap`), so it runs before session-level taps. It needs Accessibility trust (`AXIsProcessTrustedWithOptions` prompt, exits if missing; `:289-305`).

### 4.9 Stage Manager and macOS 15 native tiling

**Stage Manager** (both read private defaults domains, read-only):
- Rectangle `StageUtil` (`Utilities/StageUtil.swift`):
  - `com.apple.WindowManager GloballyEnabled` = on; `AutoHide` = strip hidden; the strip side comes from the Dock `orientation` (and RTL) (`:16-40`).
  - Strip visibility comes from counting ≥ 2 `CGWindowList` windows owned by process `WindowManager` on that screen (`:42-62`).
  - `adjustedVisibleFrame` subtracts `stageSize` (default **190 pt**, or a fraction if < 1) from the strip side (`ScreenDetection.swift:426-438`).
  - Strip groups are read from the WindowManager app's AX tree, via the private attribute **`AXWindowsIDs`** on strip buttons (`StageUtil.swift:64-82`; `AXExtension.swift:7`). This lets a drag that starts on a strip thumbnail act on the real window (`StageWindowAccessibilityElement`, `AccessibilityElement.swift:523-531, 607-625`). Windows still in the strip are excluded from snapping (`SnappingManager.swift:285-289`).
- Loop `SystemWindowManager.StageManager` (`SystemWindowManager.swift:17-29`) reads the same keys. `safeScreenFrame` subtracts `stageStripSize` (default **150 pt**) when `respectStageManager` is on (`NSScreen+Extensions.swift:66-80`).

**macOS 15 Sequoia tiling** (`com.apple.WindowManager` keys `EnableTilingByEdgeDrag`, `EnableTilingOptionAccelerator`, `EnableTopTilingByEdgeDrag`, `EnableTiledWindowMargins`, `TiledWindowSpacing`, `DisableTilingAnimations`):
- Rectangle `MacTilingDefaults` (`Utilities/MacTilingDefaults.swift`), checked at launch (`AppDelegate.swift:156`):
  - Missing keys mean enabled (`:19-21`).
  - If both drag tilings are on, it shows a three-button alert: "Disable in macOS" **writes `false` into `com.apple.WindowManager`** (`:25-33`, `:111-115`), "Disable in Rectangle", or "Dismiss".
  - If only top-edge tiling conflicts with a configured top snap area (macOS 15.1+), it silently disables `EnableTopTilingByEdgeDrag` (`:55-75`).
  - It deep-links to System Settings with `x-apple.systempreferences:com.apple.preference.Desktop-Settings.extension` (`:35-37`).
- Loop:
  - Shows a settings tooltip warning when `EnableTilingByEdgeDrag` is on (`Settings Window/Settings/Behavior/BehaviorConfiguration.swift:111-120`).
  - Opt-in `useSystemWindowManagerWhenAvailable` **delegates to native tiling** by pressing the app's own *Window ▸ Move & Resize* menu items through AX. It walks the menu bar and matches menu items by `AXIdentifier` selector names such as `_zoomLeft:`, `_zoomFill:` or `_zoomUntile:` (= "Return to Previous Size"), then calls `AXPress` (`SystemWindowManager.swift:50-134`, mapping `:155-187`, call site `WindowEngine.swift:138-162`). This only works for the frontmost app, on the same screen, with the item enabled; otherwise it falls back to AX frames. Native tiling then tracks the tiled state and restore frame itself.
  - It mirrors the native margins and animation settings (`:136-151`).

### 4.10 Permissions, private APIs, sandboxing

| | Rectangle | Loop | easy-move-resize |
|---|---|---|---|
| Accessibility (TCC) | Required (`AXIsProcessTrusted`, `AccessibilityAuthorization.swift:13`) | Required (`AXIsProcessTrustedWithOptions` + polling stream, `Utilities/AccessibilityManager.swift:134-143`) | Required (prompt; quits if missing) |
| Event taps | Session-level active taps (snapping when Mission-Control prevention is on, green button) + passive `NSEvent` monitors. Hotkeys via Carbon (no tap) | Session-level active taps (keybinds, left-click while open), listen-only taps (drag, mouse move) | HID-level active tap |
| Screen Recording | not needed (window titles not used) | `SLSHWCaptureWindowList` exists for previews (`SkyLightToolBelt.swift:265`) | no |
| App Sandbox | **No** (`Rectangle.entitlements` is an empty dict; hardened runtime) | **No** (`Loop.entitlements` empty; hardened runtime) | **No** (no entitlements file) |
| Distribution | Direct download / Homebrew (not MAS) | Direct download (own privileged updater helper) | Direct download |

An App Sandbox app cannot control other apps' windows via AX in a way the Mac App Store accepts (and cannot create active event taps), so none of the three is sandboxed.

**Private APIs used:**

| API | Repo | Purpose | File |
|---|---|---|---|
| `_AXUIElementGetWindow` | Rectangle, Loop | AXUIElement → CGWindowID | `Rectangle/Rectangle-Bridging-Header.h:7`, `AXExtension.swift:93-98`; `Loop/Private APIs/PrivateApis.swift:27-31` |
| AX attribute `AXEnhancedUserInterface` (undocumented) | Rectangle, Loop | Disable app-side animation while resizing | `AXExtension.swift:6`; `Window.swift:247-266` |
| AX attribute `AXWindowsIDs` on the WindowManager (Stage strip) | Rectangle | Window ids in a stage group | `StageUtil.swift:64-82` |
| AX `AXFullScreen` attribute | Loop | Read/exit full screen | `AXUIElement+Extensions.swift:170` |
| Defaults domains `com.apple.WindowManager`, `com.apple.dock`, `.GlobalPreferences` | Rectangle, Loop | Stage Manager, tiling, Dock orientation/autohide, `AppleActionOnDoubleClick`, `enterMissionControlByTopWindowDrag` (Rectangle and Loop **write** some of these) | `StageUtil.swift`, `MacTilingDefaults.swift`, `TitleBarManager.swift:117-119`, `SystemWindowManager.swift` |
| `GetProcessForPID` (deprecated Carbon) | Loop | PSN for SkyLight calls | `PrivateApis.swift:21-25` |
| SkyLight `SLSMainConnectionID`, `SLSFindWindowByGeometry`, `SLSCopyBestManagedDisplayForPoint`, `SLSGetWindowLevel`, `SLSWindowQueryWindows` + iterator (`…GetTags`, `…GetParentID`, `…GetResolvedCornerRadii`), `SLSSetWindowBackgroundBlurRadius`, `SLSHWCaptureWindowList`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`; ObjC `SLSBridged*Operation` (move window to Space, copy spaces) | Loop | Hit testing, display at point, window filtering, **focusing a single window**, throwing windows between Spaces, preview capture | `Private APIs/SkyLightSymbolLoader.swift:17-124` (loaded with `dlopen`/`dlsym`, so they fail gracefully), `SkyLightToolBelt.swift`, `SkyLightBridgedSPI.swift` |
| Menu selector identifiers `_zoomLeft:` etc. | Loop | Drive native macOS 15 tiling | `SystemWindowManager.swift:51-77` |
| `Subsurface` package (trackpad gestures) | Loop | Multitouch triggers | `Core/Multitouch/*` |

---

## 5. Comparison

| Aspect | Rectangle | Loop | easy-move-resize |
|---|---|---|---|
| Interaction model | Direct hotkeys + drag-to-edge + title bar + green button | Modal trigger key + radial menu/preview; drag snapping optional | Modifier + drag |
| Closest to Windows | **Most complete**: maximize/restore toggles, unsnap-on-drag, title-bar double-click, green-button override, Win+Arrow-like across-monitor halves | Arrow cycles + radial picker (Snap Layouts-ish); undo/initial frame | Alt+drag (Linux/X11 style), not Windows |
| Restore semantics | `restoreRects` = frame before the first managed action, refreshed when the user moves the window | `initialFrame` + undo stack; erased on manual move | none |
| Robustness against stubborn apps | Very high: order heuristics, AX min-size retries, edge re-alignment, Dock-clamp retries, cross-display retries, Enhanced-UI policy per app family | High: retry, runtime constraint detection during animation, edge anchoring | Low (raw writes) |
| Drag snap zones | 8 areas, 5 pt margins, 20 pt corners, compound areas, per-orientation config | Percentage zones per edge, 2 pt threshold, drag-time thirds cycling | n/a |
| Animation | Display-link worker (experimental) | NSAnimation (opt-in) | none |
| Private API footprint | Minimal (`_AXUIElementGetWindow` + defaults) | Large (SkyLight) | None |
| Focus/raise | `kAXMain` + `NSRunningApplication.activate` (raises **all** app windows) | SkyLight `_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)` + synthetic key-window event + `kAXRaise`: **raises only that window** | `activateWithOptions` + `kAXRaise` |

---

## 6. Reusable techniques for "pane"

1. **Set frames in the right order, then verify.** Use Rectangle's `ImmediateFrameOrder.sizeFirst` heuristic (pick the order whose intermediate frame overflows least, and always go size-first across displays). Re-read and retry with `max(target, AXMinSize)`. Re-anchor accepted sizes to the intended edges (Rectangle `EdgeAlignmentWindowMover`, Loop `anchoredFrame`).
2. **Toggle `AXEnhancedUserInterface` off around writes.** Default to *not* re-enabling it for Chromium-family apps unless VoiceOver or Switch Control is on (Rectangle `EnhancedUI.automatic`).
3. **Model Maximize as `(lastAction == .maximize && frame == recordedFrame)` plus a restore-bounds map keyed by `CGWindowID`.** Capture restore bounds only when the window was not just placed by you, as Rectangle does at `WindowManager.swift:129-143`. This makes maximize/restore, double-click toggle, the green-button toggle and drag-to-unmaximize all consistent. Persisting across relaunches would need a different key (pid + AX identity + title heuristics), because `CGWindowID` does not survive relaunch.
4. **Title-bar double-click:** copy Rectangle's approach (geometry from `AXCloseButton`, toolbar union, role allow-list, tab-close veto). Require `AppleActionOnDoubleClick == None`, or have the installer set it, so the system Zoom/Fill doesn't run as well. Pane could also *offer* to set it, the same way Rectangle writes `com.apple.WindowManager`.
5. **Green button → Maximize instead of native full screen:** a consuming session tap on `AXFullScreenButton`, swallowing down and up, with Option as a pass-through (`GreenButtonManager`).
6. **Drag detection:** read `mouseEventWindowUnderMousePointerThatCanHandleThisEvent` from the mouse-down CGEvent so you get the exact window, then compare WindowServer frames with WindowServer frames and AX with AX. Use same-source geometry to tell move from resize, and the release event's own location for the final area.
7. **Mission Control on top-edge drag:** on macOS 15+ set `com.apple.dock enterMissionControlByTopWindowDrag = false` (Loop). On older systems, clamp the cursor y in an active tap (Rectangle) or warp the cursor (Loop).
8. **Preview overlay:** a borderless, click-through, `.transient/.ignoresCycle` window. Ordering it directly below the dragged window (`order(.below, relativeTo:)` at the window's own level) looks native.
9. **Work area:** use `visibleFrame`, correct for a stale Dock using the Dock's AX `AXList` frame, subtract the Stage Manager strip when it is visible, and flip with `screens[0].frame.maxY`. Use inclusive max edges for hit tests, and SkyLight `SLSCopyBestManagedDisplayForPoint` if you accept private APIs.
10. **Single-window activation (feature 1):** Loop's `Window.focus()` (`Window.swift:268-286`) shows how to bring one window forward without raising its siblings: `_SLPSSetFrontProcessWithOptions(psn, windowID, kCPSUserGenerated)` → `SLPSPostEventRecordTo` with a synthetic left-mouse-down record carrying the window id (byte layout and macOS 27 caveats in `SkyLightToolBelt.swift:92-170`) → `kAXRaiseAction`.
11. **Native tiling as a backend:** on macOS 15+, pressing `Window ▸ Move & Resize` items through AX (`_zoomFill:`, `_zoomLeft:`, `_zoomUntile:`) gets you the system's own tiled state, restore memory and animation for free, but only for the frontmost app on the current screen (Loop `SystemWindowManager`).
12. **Event tap hygiene:** re-enable on `tapDisabledByTimeout/UserInput` with a restart limit (Loop: at most 5 in 2 s, `BaseEventTapMonitor.swift:95-118`). `CFMachPortInvalidate` on stop to avoid leaking WindowServer registrations (Rectangle `EventMonitor.swift:94-110`). Keep tap callbacks short and do the AX work on main or a worker thread.

---

## 7. Limitations and gotchas observed

- **No real OS-level maximize state.** Every approach is frame-equality bookkeeping. Any app-side resize, such as a toolbar toggle or a font change, silently drops the window out of "maximized". The Dock appearing or a display change does the same. History is in memory only, so a relaunch forgets all restore bounds.
- **AX latency and blocking.** AX calls are synchronous IPC into the target app. A hung app blocks the caller (hence messaging timeouts). Electron and Chromium apps can be slow, and Java/Qt apps can misreport frames (Rectangle's `fullIgnoreIds`: install4j, MATLAB, Illustrator, After Effects, …, `SnappingManager.swift:90-95`).
- **Apps that refuse sizes** (minimum sizes, fixed aspect ratios, terminal cell grids) end up smaller or larger than the zone. Both projects re-anchor instead of overlapping, and Rectangle can show a "size constraint" warning (`WindowManager.swift:367-369`).
- **Separate Spaces per display / full-screen Spaces.** Full-screen windows are skipped (Rectangle disables snapping, Loop has an `ignoreFullscreen` option or exits full screen first). Moving a window into a native full-screen Space isn't possible through AX.
- **Conflicts with macOS 15 tiling and Stage Manager.** Both edge-drag systems can fire at once, so you must disable one side. The Stage strip width is a hard-coded guess (190 or 150 pt), not measured.
- **Mouse-up timing.** Fast drags coalesce events. Rectangle re-evaluates at release, and also snaps on mouse-up even if no preview was shown. The window can lag the cursor during the drag because the app moves it, not the WM.
- **Title-bar detection is heuristic.** Unified toolbars, custom title bars (Electron, browsers' tab strips) and tab-close double-clicks need allow-lists and ignore-lists. It only works if the user sets the system double-click action to "None".
- **Private-API risk (Loop).** SkyLight symbols and record layouts change between macOS versions (see the comments about the event-record padding on 14.7.4 and resize-region hits on macOS 27). Loop resolves them dynamically so missing symbols don't crash it, but behaviour can still break. Rectangle stays almost entirely on public API.
- **easy-move-resize** is minimal. It has no edge snapping and no multi-display constraints, and its HID-level tap swallows modifier-clicks system-wide (with a per-app disable list).
- **No Snap Layouts flyout or Snap Assist** in any repo. Building one would need an overlay triggered on hover over the green button (an AX hit test on `AXFullScreenButton`/`AXZoomButton` from a mouse-moved monitor) plus a post-snap window picker. Neither exists to borrow.
