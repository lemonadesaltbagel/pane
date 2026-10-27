# AltTab (alt-tab-macos): source study

Source: `refs/alt-tab-macos`, shallow clone at commit `240e3fff` (2026-10-18).
All paths below are relative to `src/` unless stated otherwise. Line numbers are for that commit.

Licence: **GPL-3.0** (`LICENCE.md`). Some features now sit behind a paid "Pro" tier (`src/pro/`). If you copy code
verbatim, your project inherits GPL. Re-implementing the techniques described here is fine.

---

## 1. Overview

AltTab is a Windows-style Alt+Tab switcher for macOS: one tile per **window** across all apps, with thumbnails,
and per-window actions. It has outgrown the "AX + CGWindowList" design that most macOS window tools use. The
current architecture has three planes (`windowserver/README.md:1-22`):

| Plane | Source of truth | What it owns |
|---|---|---|
| **Physical** | WindowServer through **private SkyLight** (`SLS*`/`CGS*`): a notify-proc event tap plus batched `SLSWindowQueryWindows` snapshots | existence, geometry, z-order/level, Space membership, ordered-in/out, minimized, fullscreen, fallback title |
| **Semantic** | **One `AXObserver` per process** (not per window), plus on-demand AX reads | focused/main window, titles, subrole (is it a "real" window?), native tabs, and all *actions* (raise, minimize, close, fullscreen) |
| **Attention / MRU** | A pure reducer (`AttentionModel`) fed by NSWorkspace activation, AX focus notifications and a private type-13 CGEvent "click" channel | the window order (most recently used) |

They split it this way because AX is unreliable: apps hang, Electron rebuilds its AX tree, AX filters out other
Spaces, and windows can be "phantoms". The WindowServer stays responsive even when an app is wedged. Accessibility
permission is still required, because focusing another app's window needs it either way.

Codebase style: pure "kernels" with `*Specs.md` and `*Tests.swift` triads, and impure executors around them. The
comments are unusually good: they record **measured** OS behaviour (timings, bit layouts, macOS 26/27 changes).
Many details below come straight from those comments.

App shape: `LSUIElement=true` (agent app, no Dock icon, `Info.plist`), **not sandboxed**
(`alt_tab_macos.entitlements`: `app-sandbox=false`, `disable-library-validation=true`), Hardened Runtime on,
notarized (`scripts/package_and_notarize_release.sh`), and it links `/System/Library/PrivateFrameworks/SkyLight.framework`
directly (`config/base.xcconfig:15`, pbxproj). Minimum macOS 12.0. Auto-update uses Sparkle. It is distributed
outside the App Store, which is impossible for this design anyway because of the private APIs and the lack of a
sandbox.

---

## 2. Feature → mechanism table

| Feature | Mechanism (public / **private**) | Where |
|---|---|---|
| Enumerate all window IDs on all Spaces (incl. minimized, hidden, other-Space, fullscreen) | **`CGSCopyManagedDisplaySpaces`** → all Space IDs; **`CGSCopyWindowsWithOptionsAndTags`**(spaces, options `invisible1\|screenSaverLevel1000\|invisible2`) → wid list | `switcher/state/Spaces.swift:33-50`, `macos/CGSCallScheduler.swift:93-101`, `switcher/state/Applications.swift:202-218` |
| Per-window facts in one IPC | **`SLSWindowQueryWindows`** + `SLSWindowQueryResultCopyWindows` + `SLSWindowIterator{Advance,GetWindowID,GetPID,GetAttributes,GetLevel,GetSpaceTypeMask,GetTags,GetParentID,GetAlpha,GetBounds,CopyTitle}` | `windowserver/WindowServerQuery.swift:10-35` |
| Decode minimized / hidden / fullscreen / on-screen | bit masks on iterator fields: `attributes&0x2` on-screen, `tags&(1<<60)` minimized, `tags&(1<<39)` app hidden, `spaceTypeMask&0x20` fullscreen Space, `level==0` app window | `windowserver/WsWindowStateSpecs.md` |
| Live updates (create/destroy/move/resize/order/focus/Space) | **`SLSRegisterConnectionNotifyProc`** for event ids 804/806/807/808/811/815/816/1325/1326/1329/1401, plus **`SLSRequestNotificationsForWindows`** (per-window opt-in, *replaces* the list) | `events/WindowServerEvents.swift:39-96, 327-399`, `windowserver/WsEventRouting.swift:9-46` |
| App launch/quit | KVO on `NSWorkspace.shared.runningApplications` (not did-Launch notifications, which miss non-GUI processes) | `events/RunningApplicationsEvents.swift` |
| App activate / hide / unhide | `NSWorkspace.didActivate/didHide/didUnhideApplicationNotification` | `events/WindowServerEvents.swift:56-76` |
| Focus/title/created/destroyed (semantic) | One `AXObserver` per pid on the **application element**: `kAXFocusedWindowChanged`, `kAXMainWindowChanged`, `kAXTitleChanged`, `"AXFocusedTabChanged"`, `kAXWindowCreated`, `kAXUIElementDestroyed` | `window-tracking/AxObserverRegistry.swift:4-20, 705-715` |
| Which window was clicked (cross-app) | listen-only `kCGAnnotatedSessionEventTap` for CGEvent **type 13** (AppKit-defined), raw fields 40/50/51/83 | `events/WindowAttentionEvents.swift:1-80` |
| AXUIElement → CGWindowID | **`_AXUIElementGetWindow`** | `macos/api-wrappers/ApplicationServices.HIServices.framework.swift:4-5`, `AXUIElement.swift:96-105` |
| CGWindowID → AXUIElement | No API exists. Match `kAXWindows`+`kAXFocusedWindow`+`kAXMainWindow`; otherwise brute-force with **`_AXUIElementCreateWithRemoteToken`** | `windowserver/WindowElementAcquisition.swift`, `AXUIElement.swift:238-293` |
| Focus ONE window (not all app windows) | **`_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)`** → **`SLPSPostEventRecordTo`** synthetic mouse-down (makeKeyWindow) → `kAXRaiseAction` → (cross-Space) **`SLSSpaceSetFrontPSN`** repair | `switcher/state/Window.swift:352-589`, `macos/api-wrappers/SkyLight.framework.swift:108-195` |
| Thumbnails | macOS 26+: ScreenCaptureKit `SCScreenshotManager.captureScreenshot` (`captureSampleBuffer` for fullscreen). Earlier: **`CGSHWCaptureWindowList`** (captures minimized and other-Space windows) | `events/WindowCaptureEvents.swift`, `switcher/state/WindowThumbnails.swift:154-180` |
| Global hotkey | Carbon **`RegisterEventHotKey`** + `InstallEventHandler` on `GetEventDispatcherTarget()`. Modifier release is detected by a passive `CGEventTap` (`.cgSessionEventTap`, `.listenOnly`, flagsChanged+keyDown) | `events/KeyboardEvents.swift:188-275, 216-247` |
| Overriding system ⌘⇥ | **`CGSSetSymbolicHotKeyEnabled`**(1 = ⌘⇥, 2 = ⌘⇧⇥, false). The state persists after quit, so it is restored on terminate and on crash | `SkyLight.framework.swift:95-102`, `macos/api-wrappers/CGSSymbolicHotKey.swift`, `App.swift:708-713`, `main.swift:77-86` |
| Close window | AX: press `kAXCloseButtonAttribute` (`kAXPressAction`). If fullscreen, un-fullscreen first and wait 1s | `Window.swift:265-298` |
| Minimize / restore | AX `kAXMinimizedAttribute` set | `Window.swift:307-332` |
| Fullscreen toggle | AX `"AXFullScreen"` set | `Window.swift:334-349` |
| Hide / show app | `NSRunningApplication.hide()/unhide()` | `switcher/state/Application.swift:206-212` |
| Quit app | `NSRunningApplication.terminate()`. A second press calls `forceTerminate()`. Finder is protected | `Application.swift:214-230` |
| Process type (filter XPC) | deprecated/private **`GetProcessForPID`** + **`GetProcessInformation`** (`processType != "XPC!"`) | `switcher/state/ApplicationDiscriminator.swift:52-67` |
| Mission Control detection | Dock AX notifications `AXExposeShowAllWindows/...` (dead on macOS 27), so they also look for the WindowManager overlay window via `CGWindowListCopyWindowInfo` | `macos/api-wrappers/MissionControl.swift:1-45` |
| Permission checks | **`TCCAccessPreflight`**, **`TCCAccessCheckAuditToken`** (dlsym from TCC.framework). Screen Recording detected by whether other apps' window titles are visible | `macos/SystemPermissions.swift:105-300` |

---

## 3. Deep dives

### 3.1 Window enumeration

**Step A: Space topology** (`switcher/state/Spaces.swift:33-50`)

```swift
let raw = CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as! [NSDictionary]   // displays → "Spaces" → "id64"
let current = CGSManagedDisplayGetCurrentSpace(CGS_CONNECTION, uuid)
// per-window Space map: one query per Space, inverted
for spaceId in allSpaceIds { for wid in CGSCallScheduler.windowsInSpaces([spaceId]) { map[wid].append(spaceId) } }
```
Caveat (`SkyLight.framework.swift:37-41`): if "Displays have separate Spaces" is off, every display collapses
into one entry whose identifier is the literal `"Main"` (handled at `Spaces.swift:69-72`).

**Step B: all wids across all Spaces** (`macos/CGSCallScheduler.swift:93-101`)

```swift
var options = [.screenSaverLevel1000] as CGSCopyWindowsOptions          // 1<<1: windows of "All Spaces" apps
if includeInvisible { options = [options, .invisible1, .invisible2] }   // 1<<0, 1<<2: minimized/hidden/ordered-out
CGSCopyWindowsWithOptionsAndTags(CGS_CONNECTION, 0 /*owner: all*/, spaceIds, options.rawValue, &set_tags, &clear_tags)
```
The inventory (`Applications.refreshWindowsViaWindowServer`, `Applications.swift:202-310`) calls this twice. One
call includes invisible windows (`all`) and one does not (`visible`). A wid that appears in `all` but not in
`visible` is alive but hidden, which feeds phantom detection. The full wid list is then passed to **one**
`SLSWindowQueryWindows` batch (`WindowServerQuery.swift`), which costs about 84µs idle and up to about 27ms
during a Space transition. It must run off the main thread.

**Step C: which surfaces are real windows** (`switcher/state/WindowAdmissionResolverSpecs.md`)
- WindowServer facts: level 0 (or covering the screen), parentless (`GetParentID==0`), size of at least 100×50
  as a prior.
- AX facts: `AXStandardWindow` subrole, a titled `AXDialog`, or `kAXMain`. Floating or system-dialog subroles are
  auxiliary. Custom toolkits (Steam, Wine, Emacs reports `AXTextField`) get a generic "titled substantial
  AXWindow root" rule instead of per-app exceptions.
- Apps: XPC processes are excluded (`GetProcessInformation.processType == "XPC!"`), and so are zombies and
  `com.apple.WindowManager`. Exceptions: `com.apple.Passwords`, the Android emulator (matched on `qemu-system`
  in `KERN_PROCARGS`).

**Step D: attaching an AXUIElement to each wid** (`windowserver/WindowElementAcquisition.swift`, `README.md:34-53`)
1. Read `[kAXWindows, kAXFocusedWindow, kAXMainWindow]` in **one** `AXUIElementCopyMultipleAttributeValues`.
   `kAXWindows` is filtered to the **current Space**. `kAXFocusedWindow` and `kAXMainWindow` are not, so they reach
   one other-Space window for free (`AXUIElement.swift:213-220`).
2. Match by `_AXUIElementGetWindow(element) == wid`.
3. For the remaining wids (other Spaces, inactive native tabs), **brute-force with remote tokens**
   (`AXUIElement.swift:238-293`):
   ```swift
   // 20 bytes: pid(4) | 0(4) | 0x636f636f "coco"(4) | AXUIElementID(8)
   memcpy(bytes + 12, &idField, 8)
   _AXUIElementCreateWithRemoteToken(remoteToken)   // then _AXUIElementGetWindow + role check (must be AXWindow root)
   ```
   This runs under a **250ms wall-clock budget per process**, batched for all missing wids of that pid, with a
   resumable cursor. AXUIElementIDs grow monotonically, so long-lived apps such as Finder have high ids.
   `_AXUIElementGetWindow` on a *descendant* returns its containing window's wid, so a role check is required
   (#5849).
4. Free acquisition: every AX notification carries the element it is about, even for other-Space windows, so
   that element is adopted for any wid that has none (`Applications.swift:760-793`).

**Minimized windows** appear in the "invisible" CGS list, and `tags` bit 60 marks them.
**Hidden-app windows** appear the same way with `tags` bit 39. AltTab reads hidden state from NSWorkspace notifications.
**Fullscreen windows** live on their own fullscreen Space (`spaceTypeMask & 0x20`). AX `AXFullScreen` is used only to write.
**Inactive native tabs** (Finder, Terminal, TextEdit) are in **no** CGS list. They are found by reading the
`AXTabGroup` children's titles, then brute-forcing untracked `AXStandardWindow`s with matching titles
(`Applications.swift:913-1040`, `AXUIElement.swift:295-319`, `TabGroupResolverSpecs.md`).

### 3.2 Keeping the list up to date

There is no periodic polling of the full list. Updates are event-driven, plus a throttled "correction pass".

1. **SkyLight notify procs** (`events/WindowServerEvents.swift`):
   ```swift
   for n in WsEventRouting.Notification.allCases {               // 804,806,807,808,811,815,816,1325,1326,1329,1401
       SLSRegisterConnectionNotifyProc(CGS_CONNECTION, notifyProc, n.rawValue, nil)
   }
   ...
   SLSRequestNotificationsForWindows(CGS_CONNECTION, &list, Int32(list.count))  // FULL set every time
   ```
   Event ids (reverse-engineered, `WsEventRoutingSpecs.md`): 811 created, 804 destroyed, 806 moved, 807 resized,
   815/816 ordered in/out (minimize and hide both emit 816), **808 the focused/front window changed**, 1325/1326
   added to or removed from a Space (payload `(spaceId u64, wid u32)`), 1329/1401 Space change.
   Measured gotchas:
   - Nothing arrives, not even the connection-wide 811, until at least one window is opted in (`WindowServerEvents.swift:12-16`).
   - `SLSRequestNotificationsForWindows` **replaces** the watch list. Sending only deltas silently deafens
     everything else. No unsubscribe API exists; leaving a wid out of the next call is the only way to drop it
     (`SkyLight.framework.swift:220-229`).
   - The callback fires on `_NSEventThread`. Copy the payload synchronously, then hop to main. **Never** call
     `SLSConnectionDispatchNotificationsToMainQueueIfNotMainThread` on the shared connection, because it breaks
     AppKit's own handlers and crashes (`SkyLight.framework.swift:207-210`).
   - Geometry events are coalesced per wid between "semantic edges" so a resize drag doesn't flood main (`:98-123`).
   - Create/destroy events are ignored for about 0.5s around a Space switch, which produces a storm of transient windows (`:30-35, 132-139`).
   - The 804 destroy can lag by 7s or never fire (Finder retains its CGWindow). On 816, they probe AX liveness
     (`kAXRole` → `.invalidUIElement` means dead within about 20ms of a close), then confirm with `kAXWindows`
     absence before removing anything (`Applications.swift:476-512`).
2. **AX observers**, one per process on the app element (`AxObserverRegistry.swift`). The run loop sources live
   on a dedicated `axSemanticsThread`. They switched away from per-window observers because orphaned per-window
   runloop sources caused 399 GB of VM growth (#5612). The first `AXObserverAddNotification` to a process costs
   about 25ms (the handshake); later ones cost about 0.1ms (`AXUIElement.swift:40-42`).
3. **NSWorkspace**: KVO on `runningApplications` (debounced 250ms to skip short-lived helpers), plus activate/hide/unhide notifications.
4. **Correction pass** `Applications.manuallyRefreshAllWindows()` (throttled 1s, `Applications.swift:107-114`)
   runs on launch, each switcher show, wake, unlock, and AX recovery. It does a Space sync, the WS inventory,
   a review of existing windows (titles/tabs), and discards dead phantoms.
5. **Phantom windows** (`PhantomWindowDetector.swift`): two exact WS facts. Ordered-out is the bit 0x2 clear
   (Electron `show:false`). Alpha 0 catches Outlook reminders. AX lists alpha-0 windows as normal standard windows.

Global AX messaging timeout is cut from 6s to **1s** (`AXUIElement.swift:11-16`). All AX and CGS IPC runs off
main on bounded queues (`AXCallScheduler`, `CGSCallScheduler` 4-wide, `accessibilityCommandsQueue` 4-wide,
`screenshotsQueue` 8-wide; `util/BackgroundWork.swift`).

### 3.3 Focusing ONE window (the critical part)

`Window.focus()` → `applyFocus()` (`switcher/state/Window.swift:352-444`), run on `accessibilityCommandsQueue`:

```swift
// step 0: if minimized, AX-unminimize first
if target.isMinimized, let element = target.element { try? element.setAttribute(kAXMinimizedAttribute, false) }
var psn = ProcessSerialNumber(); GetProcessForPID(target.pid, &psn)
// step 1: front the PROCESS, raising only THIS wid (mode 0x200 = userGenerated; NOT 0x100 = allWindows)
_SLPSSetFrontProcessWithOptions(&psn, target.wid, SLPSMode.userGenerated.rawValue)
// step 2: make it the KEY window via a synthetic event record
makeKeyWindow(&psn, target.wid)
// step 3: raise within the app's own window stack
element.raiseWindow()            // AXUIElementPerformAction(kAXRaiseAction); re-resolve element if .invalidUIElement
// step 4 (cross-Space only): undo step 1's clobbering of the ORIGIN Space's front app
SLSSpaceSetFrontPSN(CGS_CONNECTION, originSpaceId, originPsn)
```

Mode flags (`SkyLight.framework.swift:110-114`, from yabai's `kCPS*`): `0x100` allWindows (the behaviour of
`NSRunningApplication.activate`, which brings every window forward), `0x200` userGenerated (what AltTab passes;
passing the wid raises just that window), `0x400` noWindows.

**`makeKeyWindow`** (`SkyLight.framework.swift:138-195`) builds a 0x100-byte `CGSEventRecord`:
```
[0x04] = 0xf8          record length
[0x08] = 0x01          kCGEventLeftMouseDown   (DOWN only — no up!)
[0x20] = CGPoint(300000, 300000)   window-relative location, far off the bottom-right
[0x3a] = 0x10          unknown flag (same as yabai/Hammerspoon)
[0x3c] = wid           delivered to this window by id
SLPSPostEventRecordTo(&psn, bytes)
```
Hard-won details from the comments:
- The buffer is 0x100 bytes zeroed. Since macOS 14.7.4 the WindowServer reads past 0xf8 and SIGABRTs on heap garbage.
- They post the mouse-down only. Yabai and Hammerspoon post down+up, but measured on macOS 26.5, down alone makes
  the window key, and leaving out the up means no control can ever be "clicked".
- The click point: NaN (yabai's `memset 0xff`) gets sanitized to (0,0) by some apps and clicked real top-left
  UI (Figma Home, Telegram sidebar, #5381). A point 1-2px outside the frame hits the resize grab region on
  macOS 27 and resized windows (#5900). So it goes far off the bottom-right.
- `NSRunningApplication.activate` is merely advisory since macOS 14, so public APIs cannot move key focus across apps (`Window.swift:398-399`).

**Robustness layer:**
- **Focus intents / generations** (`FocusIntentPolicySpecs.md`): rapid re-switches run concurrently on the
  4-wide queue. Every step checks `mayProceed(generation)`, and a superseded operation that already touched
  z-order re-asserts the newest intent (`repairIfSuperseded`, `Window.swift:581-589`).
- **Verify not covered** (`Window.swift:450-513`): 150ms later, read on-screen surfaces with
  `CGWindowListCopyWindowInfo`. If another app's window still covers the target even though the target app is
  front, raise again (#6064, macOS 26.6.2).
- **Stale AX element**: `kAXRaiseAction` returning `.invalidUIElement` triggers a re-resolve by wid (brute
  force) and a retry. Steps 1 and 2 use only wid and psn, so hung or AX-less windows still get focused (`:531-554`).
- **Cross-Space bleed (#4507)**: `_SLPSSetFrontProcessWithOptions` sets the *global* front process. That makes
  the app pop to the front on other Spaces too, so the origin Space's previous front app is restored with
  `SLSSpaceSetFrontPSN` (`:564-573`). This is skipped when the target's Space is unknown, because Slack windows
  drop out of the CGS map after sleep (#5586).
- The MRU order is **not** updated optimistically. It moves only when the OS confirms focus (#6055).
- Windowless apps (placeholder tiles) use `NSWorkspace.openApplication`, falling back to `activate(options: .activateAllWindows)` (`:362-374`).
- If the cursor-follows-focus option is on, `CGWarpMouseCursorPosition` to the window centre (`App.swift:337-349`).

The switcher panel itself is an `NSPanel` with `.nonactivatingPanel` at `.popUpMenu` level
(`switcher/main-window/TilesPanel.swift:25-33`). Showing it does not steal activation from the current app.
When hiding it they block key-window changes so nothing else becomes key (`App.swift:122-127`).

### 3.5 Keyboard hook and overriding ⌘⇥

- **Trigger**: Carbon `RegisterEventHotKey(key, mods, EventHotKeyID('altt', id), GetEventDispatcherTarget(), 0, &ref)`
  plus `InstallEventHandler` for `kEventHotKeyPressed/Released` (`KeyboardEvents.swift:188-275`).
  `GetEventDispatcherTarget` is used because the other targets need Accessibility (`:7-8`).
- **Hold modifier release** (releasing ⌥ commits the selection): a passive **`CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .listenOnly, [flagsChanged, keyDown])`**
  on a dedicated input thread (`:216-235`). It never swallows typing. Key-downs are only logged to keep order
  when Carbon delivers late after a main-thread stall. `tapDisabledByTimeout/UserInput` gets re-enabled.
- **Esc absorption**: a second **active** tap at `.cghidEventTap` / `.defaultTap`, enabled **only while the
  switcher is open** and a shortcut binds Esc. It is needed to beat the macOS 26 Game Overlay's ⌘⎋. Keeping it
  always on broke third-party IMEs (#5766) (`:236-246, 152-165`).
- While the panel is key, in-panel keys go through `NSEvent.addLocalMonitorForEvents([.keyDown,.keyUp])` (`:207-214`).
- **Disabling system ⌘⇥**: `CGSSetSymbolicHotKeyEnabled(1, false)` and `(2, false)` for ⌘⇥ and ⌘⇧⇥
  (`CGSSymbolicHotKey.swift`). The Dock matches these in the WindowServer's symbolic-hotkey layer *before* any
  Carbon hotkey, so they must be disabled. ⌘\` (id 27) does not need it: Carbon hotkeys beat app delivery. The
  disable **persists after the app quits**, so it is re-enabled in `applicationWillTerminate`, in the
  uncaught-exception/signal `emergencyExit`, and per-shortcut via `NativeHotkeyResolver`
  (`ControlsTab.swift:743-751`).
- Per-app exceptions: shortcuts are unregistered when a blacklisted app (e.g., a game or VM) becomes frontmost (`App.checkIfShortcutsShouldBeDisabled`).
- SecureInput (password fields) blocks `.keyDown` in taps but not `.flagsChanged` (`KeyboardEvents.swift:217-219`).

### 3.6 Window and app actions

| Action | Implementation | Notes |
|---|---|---|
| Close window | `closeButton = element[kAXCloseButtonAttribute]; closeButton.performAction(kAXPressAction)` | If fullscreen: set `AXFullScreen=false`, wait 1s, then press. **No optimistic removal**: it waits for AX destroy, 816+liveness, or 804 (`Window.swift:265-298`) |
| Minimize/restore | `setAttribute(kAXMinimizedAttribute, !wasMinimized)` | Fullscreen windows exit fullscreen first, then wait 1s. Native tabs can't be minimized individually (`:303-332`) |
| Fullscreen | `setAttribute("AXFullScreen", !wasFullscreen)` | (`:334-349`) |
| Hide/show app | `NSRunningApplication.hide()/unhide()` | (`Application.swift:206-212`) |
| Quit app | `terminate()`, then `forceTerminate()` on the second request | Finder is opt-in only (`:214-230`) |
| Focus | see 3.3 | |

Defaults inside the switcher: W close, M minimize, F fullscreen, Q quit, H hide (`preferences/Preferences.swift:13-17`).
Hover "traffic lights" on tiles: `switcher/main-window/TileOverView.swift:4-7`. AltTab does **not** move or resize
windows: there are no `kAXPosition`/`kAXSize` writes and no zoom/maximize. Snapping is out of scope.

### 3.7 MRU / attention model

`window-tracking/AttentionOrderSpecs.md`: one reducer decides "which window is the user looking at". Inputs:
- NSWorkspace activation, which names the app only.
- AX `kAXFocusedWindowChanged` from the per-app observer, with a 60ms settle.
- **Type-13 CGEvent "click" channel** (`events/WindowAttentionEvents.swift`). A listen-only tap on
  `kCGAnnotatedSessionEventTap` masked to `NSEvent.EventType.appKitDefined` (13), subtype 9 = cross-app click.
  It reads raw fields 40 (target pid), 51 (wid), 50 (record length, expected 248), and 83 (subtype). It arrives
  about 66ms after the click, *before* the key appearance changes, and works even if the app is hung. Only the
  annotated session tap sees events addressed to other processes.
- WindowServer 808 is treated as an **order change, not focus**, and cannot move MRU (`windowserver/README.md:10-12`).

AltTab's own focus requests do not write MRU. Only the OS's confirmation does.

### 3.8 Permissions, sandbox, distribution

- **Accessibility**: required for everything (AX reads, actions, observers, `CGEvent.tapCreate` returns nil
  without it → `App.restart()`, `KeyboardEvents.swift:234`). Detection uses private `TCCAccessCheckAuditToken`,
  because `AXIsProcessTrusted` caches stale values (`SystemPermissions.swift:155-193`). If permission is revoked
  at runtime, the app restarts (`:100`).
- **Screen Recording**: optional, needed only for thumbnails and other apps' titles. It can be skipped ("Continue
  without thumbnails"). Detected by checking whether other apps' layer-0 windows have non-empty `kCGWindowName`,
  since `CGPreflightScreenCaptureAccess` is frozen per-process (`:206-266`). `TCCAccessPreflight` == 2 means "no
  entry yet". Without an entry, the system prompt is shown; otherwise the Settings pane opens.
- Not sandboxed, hardened runtime, `disable-library-validation` (for plugins/frameworks), notarized with
  `notarytool` and stapled, Developer ID signed, with Sparkle updates (a Homebrew cask exists upstream but is not in this repo). Keychain-stored licence keys tie
  them to a stable Team ID (`AGENTS.md`).

---

## 4. Private API inventory

All declared in `macos/api-wrappers/SkyLight.framework.swift` (SkyLight linked directly) unless noted.

| Symbol | Purpose in AltTab |
|---|---|
| `CGSMainConnectionID` | WindowServer connection id used by every CGS/SLS call |
| `CGSCopyManagedDisplaySpaces` | displays → Spaces (ids, current Space) |
| `CGSManagedDisplayGetCurrentSpace` | current Space on a display UUID |
| `CGSCopyWindowsWithOptionsAndTags` | all wids in given Spaces, z-ordered, incl. invisible (minimized/hidden) |
| `CGSCopySpacesForWindows` (mask 5/6/7) | Spaces of one wid (backfill when the per-Space map misses it) |
| `CGSCopyWindowProperty("kCGSWindowTitle")` | live WS title fallback (Chrome web apps / Slack give empty AX titles) |
| `CGSGetWindowLevel` | window level |
| `CGSCopyActiveMenuBarDisplayIdentifier` | which screen has the active menu bar (where to show the panel) |
| `CGSSetSymbolicHotKeyEnabled` | disable/enable system ⌘⇥ / ⌘⇧⇥ (persists after exit!) |
| `CGSHWCaptureWindowList` | window screenshot incl. minimized / other-Space (pre-macOS 26) |
| `_SLPSSetFrontProcessWithOptions` | front a process and raise **only** the given wid |
| `SLSSpaceSetFrontPSN` | set front process for one Space (repair cross-Space clobbering) |
| `SLPSPostEventRecordTo` | post raw event record → `makeKeyWindow` (key focus across apps) |
| `SLSRegisterConnectionNotifyProc` | subscribe to WS event ids (window lifecycle/geometry/Space) |
| `SLSRequestNotificationsForWindows` | per-window opt-in (replaces the list) |
| `SLSWindowQueryWindows`, `SLSWindowQueryResultCopyWindows`, `SLSWindowIteratorAdvance/GetWindowID/GetParentID/GetAlpha/GetPID/GetAttributes/GetLevel/GetSpaceTypeMask/GetTags/GetBounds/CopyTitle` | one-IPC batched window snapshot. `GetBounds` returns a CGRect **by value**, so it must be bound via `dlsym` + `@convention(c)` (x86_64 sret ABI, #5819) |
| `_AXUIElementGetWindow` (HIServices) | AXUIElement → CGWindowID |
| `_AXUIElementCreateWithRemoteToken` (HIServices) | synthesize AXUIElement from (pid, "coco", elementId) → brute-force other-Space windows / inactive tabs |
| `GetProcessForPID`, `GetProcessInformation` (deprecated HIServices) | pid → PSN (for SLPS calls); process type to reject XPC |
| `TCCAccessPreflight`, `TCCAccessCheckAuditToken` (TCC.framework via dlsym) | permission state without stale cache |
| AX constants `"AXFullScreen"`, `"AXStatusLabel"`, `"AXFocusedTabChanged"`, `"AXExposeShowAllWindows"`, etc. | undocumented attribute/notification names |
| Undocumented CGEvent fields 40/50/51/83 on type 13 | click-target wid/pid (`WindowAttentionEvents.swift:48-72`) |
| Undocumented bit layouts (`attributes`, `tags` bits 39/60, `spaceTypeMask` 0x20) | state decoding. "Re-diff on a new major macOS" |

---

## 5. Lessons and reusable techniques for a Windows-like window manager ("pane")

Mapped to the 7 target features:

**(1) Windows are first-class: activate one window without raising the rest.**
Copy AltTab's 4-step focus sequence exactly: `_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)` →
`makeKeyWindow` (0x100 zeroed buffer, mouse-down only, point far off the bottom-right) → `kAXRaiseAction` →
`SLSSpaceSetFrontPSN` repair when crossing Spaces. Add generation tokens so rapid switches don't interleave,
and a 150ms post-check that re-raises if another app's window still covers the target. This is the only known
way to get Windows semantics. It works because `_SLPS…` with a wid and no `0x100` flag doesn't bring every app
window forward. **Caveat:** this only handles *your* activations. When the user clicks a window or the Dock,
macOS still raises the app's windows its own way. To make clicks behave like Windows too, you'd need to detect
the activation (type-13 click tap / 808 / `NSWorkspace.didActivate`) and re-order windows afterwards, which is
flicker-prone. AltTab doesn't attempt this.

**(2) App lifecycle tied to windows (close last window → quit; tray).**
Building blocks: KVO on `runningApplications`, AX `kAXUIElementDestroyed` per app observer, and WS 804/816 plus
the liveness probe for "window really gone". AltTab's close detection is the hardest part to get right: AX
destroy is fast and reliable for AppKit, 804 is late or missing (Finder retains CGWindows), and Electron tears
down AX trees when hiding. Then "last window closed" = count of admitted, non-phantom windows for the pid
reaching 0 → `NSRunningApplication.terminate()`. Use `WindowAdmissionResolver`-style rules to decide what
counts as a window (don't quit because a palette closed). Apps that legitimately live without windows (menu
bar agents, `activationPolicy == .accessory`) are your "tray" set. AltTab already models windowless apps as
placeholder tiles (`addWindowlessWindowIfNeeded`).

**(3) Per-window controls.**
AX gives you close (press `kAXCloseButton`), minimize (`kAXMinimized`), fullscreen (`AXFullScreen`) and raise.
Mind the fullscreen ordering: exit, wait about 1s, then act. Native tabs can't be minimized individually. Hung
apps need AX timeouts (1s global, 0.25s for verification reads). Keep the window focusable through wid+psn
alone when AX is dead.

**(4) Maximize state, snapping, Win+Arrow.**
AltTab doesn't do this. Use `kAXPosition`/`kAXSize` writes (Rectangle/Amethyst style) and the zoom button
(`kAXZoomButtonAttribute`). Use AltTab's `SLSWindowIteratorGetBounds` + 806/807 events to *observe* geometry
cheaply and keep a "maximized" state per wid, restoring the pre-maximize frame. Display/Space topology comes
from `CGSCopyManagedDisplaySpaces`.

**(5) Central taskbar with per-window thumbnails, Win+Number, middle-click new instance.**
- Window list: the WS inventory (`CGSCopyWindowsWithOptionsAndTags` + `SLSWindowQueryWindows`) plus the
  notify-proc stream is far cheaper and more robust than polling `CGWindowListCopyWindowInfo`. The batch query
  costs about 84µs idle.
- Thumbnails: SCK `SCScreenshotManager.captureScreenshot` on macOS 26+ at thumbnail size, cached
  `SCShareableContent`, and an in-flight gate. Use `CGSHWCaptureWindowList` for minimized and other-Space
  windows on older OSes. A taskbar hover preview can follow AltTab's lazy full-res pattern.
- Taskbar window: borderless `NSPanel` with `.nonactivatingPanel` so clicks don't steal activation. Set
  `canJoinAllSpaces` / `stationary` collection behaviours (AltTab uses `.popUpMenu` level for its transient panel).
- Win+Number: Carbon `RegisterEventHotKey`. Middle-click: an `otherMouseDown` handler on your own panel, then
  `NSWorkspace.openApplication(at:configuration:)` with `createsNewApplicationInstance = true`, or send the
  app's "New Window" via AX menu press.

**(6) Multiple instances are normal.** AltTab keys everything by **pid + wid**, never bundle id. That's the
right model: `Applications.findOrCreate(pid)`, and `ApplicationDiscriminator` per pid. For launching, use
`NSWorkspace.OpenConfiguration.createsNewApplicationInstance` (public). Grouping on the taskbar should use the
bundle id, with per-pid sub-entries.

**(7) Keyboard model (Alt+F4, Ctrl shortcuts, Alt menus).**
- Global chords: Carbon hotkeys. System chords like ⌘⇥ (and others, discoverable via
  `CGSGetSymbolicHotKeyValue` ids) must be disabled with `CGSSetSymbolicHotKeyEnabled`, **always re-enabled on
  exit or crash**. Hold-modifier semantics come from a passive session tap.
- Alt+F4 → focused window (`kAXFocusedWindow` of the frontmost app) → press its close button.
- Ctrl↔Cmd remapping and Alt-activates-menu require an **active** `CGEventTap` that rewrites events. AltTab's
  history warns that an always-on active HID keyDown tap broke IMEs (#5766) and was disabled by timeouts. Keep
  the callback trivial, on its own run-loop thread, re-enable on `tapDisabledByTimeout`, and expect SecureInput
  to blank out keyDowns. Alt menus: AX `kAXMenuBar` of the focused app → `AXPress` on the first menu bar item.

**General engineering lessons from AltTab:**
- Treat the WindowServer as the physical truth and AX as an unreliable semantic overlay. Never conclude
  "window gone" from a single AX failure: distinguish `.cannotComplete` (busy, retry) from other errors.
- Never do AX or CGS IPC on main. Every AppKit call that orders, resizes or changes first responder may be a
  synchronous XPC round-trip (`main-thread-ipc.md`).
- Batch: one `AXUIElementCopyMultipleAttributeValues`, one `SLSWindowQueryWindows`, one AX observer per app.
- Private API bit layouts were measured on specific OS versions. Build a debug probe and re-verify every major
  macOS release (AltTab ships `DebugWindow` for this).

---

## 6. Known limitations and edge cases (from code comments)

- **Other-Space windows**: `kAXWindows` hides them, so AX elements need remote-token brute force under a 250ms
  budget. This may fail for long-lived apps with high element ids, so a window can be shown and focused from WS
  data alone while AX-only actions fail with a beep (`Window.swift:300-305`).
- **Native tabs**: inactive tabs are in no CGS list. `_AXUIElementGetWindow` on an `AXTabButton` returns the
  parent wid, so tabs are matched by title and the `AXTabGroup` element identity. Fullscreen tab bars live in a
  separate `NSToolbarFullScreenWindow`. Chrome tabs aren't native windows at all (`TabGroupResolverSpecs.md`,
  `AXUIElement.swift:344-390`).
- **Electron / Chromium / Qt / JVM**: rebuild or tear down AX trees, hide instead of closing (`show:false` →
  phantom), never send `kAXUIElementDestroyed`, and post `AXTitleChanged` on descendant `AXStaticText` (role
  check needed). Chrome keeps its find bar as a parentless ordered-out window (#6096). Chrome web apps give
  empty AX titles (#6089).
- **Finder** retains CGWindows after close, so 804 never fires. Closing while hidden and then unhiding orders
  the corpse back in.
- **Slack** windows drop out of the per-Space map after sleep, so an unknown Space must not be treated as cross-Space (#5586).
- **Outlook** alpha-0 reminder windows look like normal AX standard windows.
- **Locked screen**: every app publishes zero windows, so discovery is suspended while locked (#6021/#6031).
- **Space transitions** produce storms of transient windows. They mute create/destroy events for about 0.5s.
- **System Preferences cross-Space bug**: macOS switches Space and then back (`Window.swift:376-378`).
- **Mission Control**: Dock AX notifications are dead on macOS 27, so they detect the overlay window instead.
  The yabai routes (WS notification 1204, the Dock layer-18 window) are dead too (`MissionControl.swift:5-18`).
- **Stage Manager**: captures are skewed without the `fullSize` capture option.
- **SCK**: per-call streams leak WS memory on some macOS 26 machines (#5786) and can wedge `replayd` (#5861).
  It crashes on 14 and is buggy on 15.
- **`CGSCopyManagedDisplaySpaces`** is wrong when "Displays have separate Spaces" is off.
- **`SLSWindowIteratorGetBounds`** crashes Intel Macs if bound with `@_silgen_name` (by-value struct return ABI).
- **`makeKeyWindow` event layout** changed behaviour across 14.7.4 (buffer overread) and 27 (resize-grab region).
- **Symbolic hotkey disable persists** across app exit. A crash without the handler leaves ⌘⇥ broken.
- **macOS 26 Game Overlay** grabs ⌘⎋, so an active HID tap is needed only during a session.
- **Chrome PiP / floating panels**: no PiP-specific code. Floating-level surfaces are admitted only if AX marks
  them `kAXMain` or they cover the screen (placement gate, `WindowAdmissionResolverSpecs.md` rule 3).
- **Fullscreen + minimize**: macOS refuses to minimize a fullscreen window (tags unchanged), so un-fullscreen comes first.
- **Hidden-app tag vs `NSRunningApplication.isHidden`**: the latter was observed reading `false` while the app was genuinely hidden (`WsWindowStateSpecs.md`).
