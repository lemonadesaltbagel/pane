# App lifecycle, menus, Alt navigation and multiple instances on macOS


Repos studied (all under `refs/`, read-only):

| Repo | Stars (Oct 2026) | Why |
|---|---|---|
| `swiftquit` (onebadidea/swiftquit) | ~570 | Quits an app when its last window closes |
| `Swindler` (tmandry/Swindler), `AXSwift` | ~700 | The window-tracking library swiftquit depends on; this is where the detection actually happens |
| `MiddleClick` (artginzburg/MiddleClick) | ~2.9k | Three-finger middle click |
| `SlowQuitApps` (dteoh/SlowQuitApps) | ~1.2k | Intercepts Cmd+Q with an event tap (Cmd+Q protection) |
| `Menu-Bar-Search` (BenziAhamed/Menu-Bar-Search) | ~570 | Walks any app's menu tree via AX and runs items with `AXPress` |
| `KeyBindings` (ttscoff/KeyBindings) | ~800 | Cocoa `DefaultKeyBinding.dict` text-system remapping |
| Also cited: `hammerspoon`, `alt-tab-macos` (already in refs); `zaru/menuffy` (86 stars, cloned only to scratchpad) | | |

---

## 1. Overview

On macOS, a **process (app)** is the primary object and windows belong to it. On Windows, the **window** is primary. To move toward Windows semantics without patching other apps, you have to do it from outside, as a privileged agent. In practice that means three kinds of API:

1. **Accessibility (AX)**: `AXUIElement` and `AXObserver`. You can watch other apps' windows get created and destroyed, read and press their menu items (`kAXMenuBarAttribute`, `kAXPressAction`), and press window buttons (`kAXCloseButtonAttribute`). Requires the **Accessibility** permission.
2. **Quartz Event Services**: `CGEventTap` and `CGEvent.post`. You can intercept and rewrite keyboard and mouse events (Cmd+Q, Alt alone, mouse button numbers) or synthesize them. Active taps need Accessibility; listen-only keyboard taps need **Input Monitoring**.
3. **Launch Services / NSWorkspace / NSRunningApplication**: launch with `createsNewApplicationInstance` or `open -n`; quit with `terminate()`; read activation policy.

What you **cannot** do from outside: change another app's activation policy or Dock presence, make its `applicationShouldTerminateAfterLastWindowClosed` return YES, or draw underlined mnemonics inside its menus. Section 8 covers these limits.

---

## 2. swiftquit: quit the app when its last window closes

### 2.1 Architecture
swiftquit is about 150 lines of logic (`Swift Quit/SwiftQuit.swift`). The window tracking is delegated to **Swindler**, an AX-based window model, so the real mechanism lives in `refs/Swindler/Sources`.

Startup (`Swift Quit/AppDelegate.swift`):
- `:28` `AXSwift.checkIsProcessTrusted(prompt: true)`. Requires Accessibility; quits if it isn't granted.
- `:34-37` `Swindler.initialize()`, then `SwiftQuit.activateAutomaticAppClosing()`.

### 2.2 Detecting that a window closed: AXObserver push events, no polling
swiftquit subscribes to Swindler's `WindowDestroyedEvent` (`SwiftQuit.swift:78-88`):

```swift
swindler.on { (event: WindowDestroyedEvent) in
    if !event.window.application.knownWindows.isEmpty { return }   // still has windows
    let pid = event.window.application.processIdentifier
    closeApplication(pid: pid, eventApp: event.window.application)
}
```

How Swindler produces that event:
- **App discovery**: `AXSwift.Application.all()` = `NSWorkspace.shared.runningApplications` filtered by `activationPolicy != .prohibited` (`AXSwift/Sources/Application.swift:38-40`), plus `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` (`Swindler/Sources/State.swift:146-178`).
- **Per-app AXObserver** on the app element, subscribed to `kAXWindowCreatedNotification`, main/focused-window-changed, and app hidden/shown (`Swindler/Sources/Application.swift:145-151`).
- **Initial window list**: one read of `kAXWindowsAttribute` *after* the subscription is in place, so no window is missed in between (`Application.swift:240-244`: `self.axElement.arrayAttribute(.windows)`).
- **Per-window subscription** to `kAXUIElementDestroyedNotification`, plus moved, resized, title changed, and miniaturized/deminiaturized (`Swindler/Sources/Window.swift:203-217`).
- **On destroy**: the window is removed from the app's `windows` array and `WindowDestroyedEvent` is emitted (`Application.swift:445-456`):

```swift
if .uiElementDestroyed == notification {
    windows = windows.filter({ !$0.equalTo(windowDelegate) })
    notifier?.notify(WindowDestroyedEvent(external: true, window: window))
}
```

`knownWindows` is that array (`Application.swift:120-122`). So "no windows remain" means **Swindler's AX-tracked window set for that pid is empty**. swiftquit does not consult CGWindowList.

### 2.3 Telling real windows from panels and sheets: barely
- Swindler's only filter drops windows whose `kAXSubroleAttribute == "AXUnknown"`, which covers tooltips and fullscreen-transition windows (`Window.swift:229-241`).
- **Sheets** don't appear in `kAXWindows` (they are children of their parent window), so they never count.
- **Floating panels, dialogs, and palettes** (`AXFloatingWindow`, `AXDialog`, `AXSystemDialog`) *do* count. An app whose last remaining window is an Inspector or Find panel stays alive.
- There is no `kAXStandardWindowSubrole` check. alt-tab-macos has a much richer admission policy (`alt-tab-macos/src/switcher/state/WindowAdmissionResolver.swift:125-126`: standard window → conventional window; `AXDialog` → special-cased), which is a better model to copy.

### 2.4 Exclusions
- Its own pid is always skipped (`SwiftQuit.swift:91,111`).
- Hard-coded system apps by bundle path: Spotlight, Finder, NotificationCenter (`SwiftQuit.swift:113-115`).
- A user list stored by **bundle path**, with two modes: `excludeApps` (quit everything except the list) and `includeApps` (quit only the list) (`SwiftQuit.swift:134-136`; UI in `ViewController.swift:123-160`).
- The app is acted on only if `isFinishedLaunching` (`:106`), which avoids killing apps that briefly have no windows while they launch.

### 2.5 Termination
After a configurable **delay (default 2 s)** it re-checks, then calls `terminate()` (`SwiftQuit.swift:120-141`):

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(closeDelay)) {
    if eventApp.knownWindows.isEmpty { terminateApplication(app: app) }  // app.terminate()
}
```

`NSRunningApplication.terminate()` sends a polite `kAEQuitApplication` Apple Event. The app can still show "Save changes?" or cancel through `applicationShouldTerminate`. `forceTerminate()` would SIGKILL; swiftquit never uses it.

### 2.6 Edge cases (from the code)
| Case | Behaviour | Why |
|---|---|---|
| Window minimized | **Not** quit | Minimized windows stay in `kAXWindows` and `knownWindows`; `isMinimized` is only a property (`Window.swift:183-187`) |
| App hidden (Cmd+H) | Not quit | Hidden windows remain in the AX list |
| **Windows on other Spaces** at the time Swindler starts | **Risk of a wrong quit** | `kAXWindows` omits other-Space windows (confirmed in `alt-tab-macos/src/macos/api-wrappers/AXUIElement.swift:226-229`, which has to brute-force `_AXUIElementCreateWithRemoteToken` to reach them). Swindler never learns about them, so closing the visible window empties `knownWindows` while the app still has windows elsewhere. Windows created *after* startup arrive through `kAXWindowCreated` and are tracked. |
| Background native tabs | Same risk | Inactive tab windows are also missing from `kAXWindows` (same alt-tab comment) |
| App replaces its window (close document → welcome window), fullscreen transitions, tab drag-out | Mostly OK | The 2 s delay and re-check, plus the AXUnknown filter |
| Windows not exposed through AX (some games, Java/SDL apps) | Never auto-quit | No `WindowDestroyedEvent` for windows Swindler never tracked |

**Takeaway for the project:** keep the AX event-driven design (window destroyed → debounce → verify), but make the *verification* step stronger:
- Cross-check with `CGWindowListCopyWindowInfo([.optionAll], 0)` filtered by `kCGWindowOwnerPID == pid`, `kCGWindowLayer == 0`, alpha > 0, and reasonable bounds. `.optionAll` includes windows on other Spaces and minimized windows.

---

## 3. MiddleClick: synthesizing middle clicks

There are two cooperating mechanisms.

**A. Finger counting: MultitouchSupport.framework (private)**
- A Clang module map over a hand-written header (`MoreTouch/Sources/MultitouchSupport/MultitouchSupport.h:55-69`, `module.modulemap`), linked with `-F/System/Library/PrivateFrameworks -framework MultitouchSupport` (`MoreTouch/Package.swift` `linkerSettings`).
- `MTDeviceCreateList()` (bound with `@_silgen_name`), then `MTRegisterContactFrameCallback` and `MTDeviceStart(dev, 0)` (`MoreTouch/Sources/MoreTouchCore/Core.swift:3-20`).
- The callback `(device, MTTouch[], nFingers, timestamp, frame)` sets `state.threeDown = nFingers == fingersQua` (`MiddleClick/TouchHandler.swift:30-73`).
- Hot-plug: `IOServiceAddMatchingNotification(…, IOServiceMatching("AppleMultitouchDevice"))` (`Helpers/IOMultitouchManager.swift:19-30`). Listeners restart after wake (`Controller.swift:88`).

**B. Turning a click into a middle click: an active CGEventTap that rewrites in place**
- Tap at `.cghidEventTap`, `.headInsertEventTap`, `.defaultTap` (modifying) for left/right down/up (`Helpers/CGEventController.swift:24-33`).
- When `threeDown`, the event is mutated rather than replaced (`Controller+Mouse.swift:15-29`):

```swift
event.type = .otherMouseDown
event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
```

- **Tap-to-click mode**: on touch end, if the fingers moved less than `maxDistanceDelta` within `maxTimeDelta`, it posts a brand-new `otherMouseDown`/`otherMouseUp` at the current cursor location to `.cghidEventTap` (`TouchHandler.swift:105-148`).
- Per-app ignore list keyed on the frontmost app's bundle ID (`AppUtils.swift:10-13`; note the caveat there that the cursor may be over a different app's window). Permission: Accessibility (`SystemPermissions.swift:9-10`).

**Relevance to the taskbar.** In *your own* taskbar view you don't need any of this. Handle `otherMouseDown(with:)`/`otherMouseUp` with `event.buttonNumber == 2`, which a real mouse sends and which MiddleClick also produces system-wide. Windows also opens a new instance on **Shift+click**, a modifier you get for free. If you want three-finger detection *only inside your own view*, the public `NSView.allowedTouchTypes = [.indirect]` plus `touchesBegan/Ended(with:)` can count trackpad touches without the private framework (unverified here; prototype it). Use MultitouchSupport only if you need system-wide gestures.

---

## 4. Other tools: menus, Alt navigation, text keys, quit protection, instances

### 4.1 Reading and invoking any app's menus through AX (basis for in-window menus and "menu at cursor")
**Menu-Bar-Search** (`Menu-Bar-Search/menu/Sources/menu/`):
- `MenuBar.swift:16-20`: `AXUIElementCreateApplication(pid)`, then `AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, &menuBar)`.
- `AX.swift:104-180`: recursive walk over `kAXChildrenAttribute`. Top-level `AXMenuBarItem` → one `AXMenu` child → `AXMenuItem`s. A sub-menu is detected by "exactly one child" (`:133`). For each item it reads `kAXTitleAttribute`, `kAXEnabledAttribute`, and the shortcut via `kAXMenuItemCmdCharAttribute`, `kAXMenuItemCmdModifiersAttribute`, `kAXMenuItemCmdVirtualKeyAttribute` (`:159-167`). Modifier decoding: `0x04` ⌃, `0x02` ⌥, `0x01` ⇧, and ⌘ is present unless `0x08` is set (`:56-64`).
- `AX.swift:91-102`: invoking an item = walk the stored index path, then `AXUIElementPerformAction(child, kAXPressAction)`.

**Hammerspoon** `extensions/application/libapplication.m:569, 661` (read `kAXMenuBarAttribute`), `:905` (`AXPress`), `:820-827` (enabled and check-mark state, `kAXMenuItemMarkCharAttribute`).

**menuffy** (zaru/menuffy, 86 stars, open-source "Menuwhere"): `MainMenu/MenuView.swift:80-82` reads the frontmost app's `kAXMenuBarAttribute`, rebuilds it as a local `NSMenu` (`:103-170`), and pops it up at the cursor (`:76` `appMenu.popUp(positioning:at:in:)`). Each `NSMenuItem` action does `AXUIElementPerformAction(element, kAXPressAction)` (`AppDelegate.swift:100`). **This is the exact pattern for an in-window menu bar.**

### 4.2 Alt-key menu navigation
There's no open-source tool that replicates Windows mnemonics, and macOS menus have no mnemonic concept. Building blocks that exist:
- Native **Ctrl+F2** ("Move focus to the menu bar"), then type a title prefix (type-select), arrows, Return. **Cmd+Shift+/** opens the Help-menu search, which is native menu search.
- So "tap Alt" can be implemented with an event tap watching `flagsChanged`: Option down then up with no key in between, and no mouse click. Then either:
  - (a) synthesize Ctrl+F2, or
- Within an open menu, show hint badges positioned from each `AXMenuItem`'s `kAXPositionAttribute` (Homerow and vimac do this for UI elements).
- Use the sequential model (tap Alt, release, then press F), *not* Option+F as a chord. Option+letter types characters on macOS (ƒ, ∂…), and Option also reveals alternate menu items.

### 4.3 Home/End without Karabiner: the Cocoa text system
`~/Library/KeyBindings/DefaultKeyBinding.dict` (`KeyBindings/DefaultKeyBinding.dict` shows the syntax and the selector vocabulary, e.g. `moveToBeginningOfParagraph:`). Windows Home/End:

```
"\UF729"  = moveToBeginningOfLine:;                    /* Home */
"\UF72B"  = moveToEndOfLine:;                          /* End  */
"$\UF729" = moveToBeginningOfLineAndModifySelection:;  /* Shift+Home */
"$\UF72B" = moveToEndOfLineAndModifySelection:;
"^\UF729" = moveToBeginningOfDocument:;                /* Ctrl+Home */
"^\UF72B" = moveToEndOfDocument:;
```


### 4.4 Cmd+Q protection: SlowQuitApps
`SlowQuitApps/SlowQuitApps/SQAAppDelegate.m`:
- `:71-89`: `CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, flagsChanged|keyDown|keyUp, …)`.
- `:200-250` handler: it detects Cmd+Q by the *character* produced (`CGEventKeyboardGetUnicodeString`), so it is layout-independent; `SQAQResolver.m:20-75` finds which keycode produces "q" with ⌘ via `UCKeyTranslate`. It ignores Ctrl+Cmd+Q (lock screen) and tracks Cmd+Tab.
- **It swallows the Q** by rewriting the event into a bare Command key event (`:237-240`):

```objc
CGEventSetFlags(event, 0);
CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, kVK_Command);
```

  It then runs a hold-to-quit state machine with an overlay, and finally calls `[[frontmost app] terminate]` (`:114-118`). A per-bundle-ID whitelist passes the keystroke through (`:165-185`, `SQAPreferences.m:41-46`).
- The same tap pattern lets you remap Cmd+Q to "close window" for a Windows feel, or implement Alt+F4 yourself.

### 4.5 "Close window = quit" utilities
Besides swiftquit there are Quitty (chentao1006, ~80 stars), Close2Quit, and AutoQuitMac. All are small and use the same AX observer approach; none has more than 300 stars.

### 4.6 "Open new instance" tools
No popular dedicated open-source tool exists. Users wrap `open -n -a App` in Automator or Shortcuts apps. Mechanisms are in Section 6.

---

## 5. Native APIs reference

### 5.1 AXMenuBar traversal
```swift
let app = AXUIElementCreateApplication(pid)
var mb: CFTypeRef?; AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &mb)
// AXMenuBar → [AXMenuBarItem] (kAXChildren) → AXMenu (single child) → [AXMenuItem] → (AXMenu …)
// per item: kAXTitle, kAXEnabled, kAXMenuItemMarkChar, kAXMenuItemCmdChar,
//           kAXMenuItemCmdModifiers, kAXMenuItemCmdVirtualKey, kAXMenuItemCmdGlyph
AXUIElementPerformAction(item, kAXPressAction as CFString)        // invoke
AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) // that app's status items
```
Caveats:
- Menus are **validated lazily**. `enabled` and dynamic items (Recent Items, Window list, items populated in `menuNeedsUpdate:`) may be stale until the menu actually opens.
- Electron, Qt, and Java menus are exposed with varying fidelity.
- Menu actions target the **key window of the active app**. For a per-window menu you must first raise and focus *that* window (`kAXRaiseAction`, set `kAXMainAttribute`, then `NSRunningApplication.activate`) before pressing.
- Use `AXUIElementCopyMultipleAttributeValues` and `AXUIElementSetMessagingTimeout` to keep it fast and safe against hung apps.

### 5.2 Launching new instances
- **`open -n -a "App"`** / `open -n /path/App.app --args …`: "Open a new instance of the application even if one is already running." `-F` skips state restoration.
- **`NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true`** (macOS 10.15+), passed to `NSWorkspace.shared.openApplication(at:configuration:)`. This is the programmatic equivalent; also set `.activates`, `.arguments`, and `.environment`.
- Each instance is a separate process and usually gets **its own Dock icon**.
- Apps can forbid it with `LSMultipleInstancesProhibited`. Many apps break anyway: single-instance locks (Chromium profile lock, Electron `requestSingleInstanceLock`) forward to the first instance; shared preferences and caches; iCloud/Core Data stores.
- **Recommended mapping for "launch again = new window"**: if the app is running, prefer **a new window in the existing process**. Options, in order:
  1. AX-press the menu item whose shortcut is ⌘N (or titled "New Window"), found by the 6.1 traversal.
  2. Send the reopen Apple Event (`kAEReopenApplication`, what a Dock click sends; `applicationShouldHandleReopen`), which opens a window only when none is visible.
  3. Synthesize ⌘N after activating.

  Fall back to `createsNewApplicationInstance` only for apps known to support multiple processes (terminals, editors, the user's allow-list).

### 5.3 `applicationShouldTerminateAfterLastWindowClosed(_:)`
An `NSApplicationDelegate` method: return `true` and AppKit terminates *your* app when its last window closes. Only the app itself can implement it, so it can't be injected into third-party apps without code injection, which SIP and the hardened runtime block. Use it in your own taskbar or launcher apps; for everyone else you need the external swiftquit-style agent.

### 5.4 `NSApplication.ActivationPolicy`
| Policy | Info.plist equivalent | Dock icon | Menu bar / Cmd+Tab | Windows / status items |
|---|---|---|---|---|
| `.regular` | default | yes | yes | yes |
| `.prohibited` | `LSBackgroundOnly = 1` | no | no | no UI |

- `NSRunningApplication.activationPolicy` is read-only for other processes.
- For a third-party app, the only way to change it is to edit its `Info.plist`. That breaks the code signature and notarization, macOS 13+ "App Management" protection blocks it, and updates revert it. A custom taskbar should **ignore** the Dock rather than try to change other apps' policies.

---

## 6. Feature → mechanism table

| Feature | Mechanism (public / private) | Reference implementation | Permission |
|---|---|---|---|
| (2) Detect a window closed | `AXObserver`: `kAXWindowCreated` on the app, `kAXUIElementDestroyed` on each window (public) | `Swindler/Sources/Application.swift:145-151, 445-456`; `Window.swift:212-217` | Accessibility |
| (2) Real window vs panel/sheet | `kAXSubrole` = `AXStandardWindow` vs `AXDialog`/`AXFloatingWindow`/`AXUnknown`; sheets aren't in `kAXWindows` | `Window.swift:229-241`; `alt-tab-macos/.../WindowAdmissionResolver.swift:125` | Accessibility |
| (2) Quit the app | `NSRunningApplication.terminate()` (polite AE quit), `forceTerminate()` | `SwiftQuit.swift:138-141`; SlowQuitApps `SQAAppDelegate.m:117` | none |
| (3) In-window menu bar / menu at cursor | AX `kAXMenuBarAttribute` walk → local `NSMenu`/strip → `AXPress`; overlay window tracking `kAXMoved`/`kAXResized` | Menu-Bar-Search `AX.swift:91-180`; menuffy `MenuView.swift:76-170`; Hammerspoon `libapplication.m:569-905` | Accessibility |
| (3) Hide the global menu bar | "Automatically hide and show the menu bar" (`_HIHideMenuBar` global default) | system setting | none |
| (3) Min/Max/Close per window | already native (traffic lights); AX `kAXCloseButton`, `kAXMinimizeButton`, `kAXZoomButton` + `AXPress`; `kAXMinimized` | AX API | Accessibility |
| (5) Taskbar middle-click | `otherMouseDown` with `buttonNumber == 2` in your own view; trackpad: MiddleClick (MultitouchSupport + tap rewrite) | `MiddleClick/Controller+Mouse.swift:15-29`, `TouchHandler.swift:30-148`, `MoreTouchCore/Core.swift` | Accessibility (MiddleClick only) |
| (6) New instance | `open -n`, `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` | Launch Services | none |
| (6) Relaunch = new window | AX-press "New Window" / ⌘N item; `kAEReopenApplication` Apple Event | Menu-Bar-Search traversal | Accessibility / Automation |
| (7) Alt tap → menu navigation | `CGEventTap` on `flagsChanged` (Option alone) → Ctrl+F2 or own AX-driven overlay with generated accelerators | SlowQuitApps tap pattern `SQAAppDelegate.m:71-89, 200-250` | Accessibility (active tap) |
| (7) Cmd+Q guard | active HID tap; rewrite the Q event into a bare `kVK_Command` to swallow it | SlowQuitApps `SQAAppDelegate.m:237-240` | Accessibility |

---

## 7. Reusable techniques (what to lift into the project)

1. **Event-driven window model, done right**: Swindler's "subscribe first, then enumerate" ordering (`Application.swift:152-156`), a per-window `kAXUIElementDestroyed` observer, and promise-based initialization. Add Space-aware verification (CGWindowList `.optionAll` + `CGSCopySpacesForWindows`) and alt-tab's admission rules for standard windows vs dialogs and panels.
2. **Debounce, then verify, then terminate politely**: swiftquit's delayed re-check (`SwiftQuit.swift:121-125`) handles window swaps, tabs, and fullscreen transitions.
6. **AX menu mirror**: walk `kAXMenuBarAttribute`, build a local `NSMenu` (menuffy), `AXPress` on selection. This works for an in-window menu strip, a menu-at-cursor popup, Alt-key navigation with generated mnemonics, and finding the "New Window" item to implement "launch again = new window".
8. **Layout-independent shortcut matching**: `UCKeyTranslate` + `TISCopyCurrentKeyboardInputSource` (SlowQuitApps `SQAQResolver.m`). Use it for Alt+letter accelerators on non-QWERTY layouts.

---

## 8. What's fundamentally impossible or hard on macOS, and why

| Goal | Status | Reason |
|---|---|---|
| Make third-party apps quit on last-window-close *natively* | **Impossible** (externally emulated only) | `applicationShouldTerminateAfterLastWindowClosed` is the app's own delegate decision. Injection is blocked by SIP, the hardened runtime, and library validation. External emulation races with app logic and can't see windows the app hides from AX. |
| Reliable "no windows remain" | **Hard** | `kAXWindows` omits other-Space windows and inactive native tabs. Reaching them needs the private `_AXUIElementCreateWithRemoteToken` brute force (alt-tab). Panels vs documents is a heuristic. Some apps (games, Java) aren't AX-visible. |
| Real per-window menu bars | **Hard** (mirror only) | The menu bar is owned by the active app and drawn by the system menu server. Menus act on the key window, so you must focus it first. Lazy validation and dynamic menus make the AX snapshot stale until a menu opens, and there's no AX event for menu content changes. Electron, Qt, and Java fidelity varies. Your overlay must track window moves, resizes, Spaces, and fullscreen. |
| Underlined Alt mnemonics inside menus | **Impossible** in-place | Other apps' `NSMenu`s are rendered out of process. You can't add underlines, only draw overlays or show your own mirrored menu. Option+letter is a text-input chord on macOS, so it has to be "tap Alt then letter". |
| True multi-instance as the norm | **Hard / app-dependent** | AppKit apps are designed as one process with many windows. `open -n` works but many apps take a single-instance lock, share state, or set `LSMultipleInstancesProhibited`. "New window in the existing process" is the faithful equivalent. |
| Middle click on a trackpad | **Private API** | No public system-wide multitouch API. MiddleClick relies on `MultitouchSupport.framework`, which is unstable and not App Store-safe. Inside your own view, public `NSTouch` is enough. |

---

### Sources (web)
- SlowQuitApps: https://github.com/dteoh/SlowQuitApps
- menuffy (open-source Menuwhere alternative): https://github.com/zaru/menuffy ; Menuwhere discussion: https://mjtsai.com/blog/2021/04/22/menuwhere-1-0
- `NSWorkspace.OpenConfiguration`: https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration
- `open -n` usage: https://www.totalphase.com/support/articles/200349376-Multiple-Application-Instances-on-Mac-OS-X
- No mnemonics on Mac / Ctrl+F2: https://discussions.apple.com/thread/2444260
