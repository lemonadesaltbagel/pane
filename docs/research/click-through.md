# Click-through and scroll-under-pointer: Windows semantics on macOS

**Question.** On Windows (a) the wheel scrolls the window under the pointer without activating it, and (b) one click on a button in an inactive window both activates the window *and* presses the button. On macOS the first click into an inactive window is often used up just activating it. Can pane give macOS Windows-style click-through? What are the hard limits?

**Short answer.**

* **Scroll (a) already works on macOS.** WindowServer sends scroll-wheel events to the window under the pointer whatever the activation state, and scrolling does not activate. pane needs to add nothing. It only needs to avoid breaking this.
* **Click-through (b) can be emulated from outside, with no injection.** Install an active event tap on left mouse-down. Detect a click on a window that is not the key window of the frontmost app. **Hold the original event in the tap callback** while pane activates exactly that window (SkyLight single-window front + make-key, plus AX main/raise as backup). Wait on an AX barrier (the app reports that window focused) with a hard budget of about 150–200 ms. Then **return the same, unmodified event**. The app now gets a normal click in an active key window, so AppKit passes it to the view. Three independent open-source tools converged on this "activate first, then release the real event" design and report it working (13–40 ms of added latency on the activating click only).
* **What cannot be done:**
  * You cannot change `acceptsFirstMouse` (or any per-view policy) in another process.
  * You cannot ask whether a view *would* have accepted the first click.
  * There is no atomic "activate, then deliver" transaction, so slow or hung apps fall back to native behavior.
  * Hover, tooltip and cursor feedback in inactive windows stays app-defined.
  * The emulation overrides app authors' deliberate refusals (destructive controls, macOS's "drag from a background window without raising it").

All `refs/...` paths are under `refs/` (shallow clones; commits in §6). SDK paths are relative to `/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk/System/Library/Frameworks/`. Nothing was run against the live system for this report. Every behavioral number is from the cited project's own measurements, not from pane.

---

## 1. Windows semantics

### 1.1 `WM_MOUSEACTIVATE`

[Microsoft docs](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mouseactivate): the message is "sent when the cursor is in an inactive window and the user presses a mouse button". `lParam` carries the hit-test code (`HTCLIENT`, `HTCAPTION`, …) and the mouse message ID. The return value decides two independent things:

| Return | Activate the window? | Deliver the mouse message? |
|---|---|---|
| `MA_ACTIVATE` (1) | yes | **yes**. This is "click-through". |
| `MA_ACTIVATEANDEAT` (2) | yes | no. This is the macOS default behavior. |
| `MA_NOACTIVATE` (3) | no | yes |
| `MA_NOACTIVATEANDEAT` (4) | no | no |

Child windows forward the message to their parent first. The parent decides, and returns a `NOACTIVATE*` value if it activated the child itself (same doc, Remarks). Raymond Chen covers the `NOACTIVATE` variants in [*How can I have a window that rejects activation but still receives pointer input?*](https://devblogs.microsoft.com/oldnewthing/20160912-00/?p=94295). Clicks reach the inactive window by default.

### 1.2 Default behavior (what `DefWindowProc` returns)

Microsoft does not document the default return value. Wine's reimplementation (`wine-mirror/wine` `dlls/win32u/defwnd.c:2572-2582`, commit `d36039e588`, 2026-09-17) matches observed Windows behavior:

```c
case WM_MOUSEACTIVATE:
    if (get_window_long( hwnd, GWL_STYLE ) & WS_CHILD) { result = send_message( get_parent(hwnd), ... ); if (result) break; }
    /* Caption clicks are handled by handle_nc_lbutton_down() */
    result = HIWORD(lparam) == WM_LBUTTONDOWN && LOWORD(lparam) == HTCAPTION ? MA_NOACTIVATE : MA_ACTIVATE;
```

* **Client area:** `MA_ACTIVATE`. The window activates (and comes to the front) and **also** gets `WM_LBUTTONDOWN`. Every button, link, text field and list works on the first click unless the app opts out with `…ANDEAT`. Few apps do.
* **Title bar (`HTCAPTION`):** `MA_NOACTIVATE`, because the non-client handler does it. `handle_nc_lbutton_down` (`defwnd.c:2194-2214`) calls `set_foreground_window(top)` and then immediately `WM_SYSCOMMAND SC_MOVE+HTCAPTION`. **Press on an inactive title bar → activate + start the move loop in one gesture.**
* **Drag start in an inactive window:** the mouse-down activates and raises the window, and the same press continues into the drag (text selection, Explorer file drag, slider). The window comes to the front *before* the drag. This differs from macOS Finder, which can drag from a background window without raising it (§2.2).
* **Hover:** inactive windows get `WM_MOUSEMOVE`, so hot-tracking and tooltips work without activation.
* **Focus-follows-mouse** is a separate, off-by-default Ease of Access option ("Activate a window by hovering over it", `SPI_SETACTIVEWINDOWTRACKING`). Chen notes that it also asks `WM_MOUSEACTIVATE` ([2024-09-19](https://devblogs.microsoft.com/oldnewthing/20240919-00/?p=110283)). It is not part of the default model.

### 1.3 Wheel: "Scroll inactive windows when I hover over them"

* Classic Win32: `WM_MOUSEWHEEL` is "sent to the **focus** window" and bubbles up the parent chain ([docs](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel)). Before Windows 10, scrolling a background window needed tools like KatMouse/WizMouse.
* Windows 10+ adds Settings → Devices → Mouse → **"Scroll inactive windows when I hover over them"**, **on by default**. Registry: `HKCU\Control Panel\Desktop\MouseWheelRouting` (DWORD): `2` = route to the window under the pointer (default), `0` = focus window ([Winaero](https://winaero.com/disable-scrolling-inactive-windows), [NinjaOne](https://www.ninjaone.com/blog/turn-on-or-off-scroll-inactive-windows/)). Scrolling does **not** activate the window.

So the Windows model is: **wheel → window under pointer, no activation. Left/right press → activate + deliver. Title-bar press → activate + move.**

---

## 2. macOS semantics

### 2.1 The first-mouse rule is in-process AppKit policy

* Apple's [*Cocoa Event Handling Guide: Handling Mouse Events*](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingMouseEvents/HandlingMouseEvents.html): "By default, a mouse-down event in a window that isn't the key window simply brings the window forward and makes it key; the event isn't sent to the `NSView` object over which the mouse click occurs. The `NSView` can claim an initial mouse-down event, however, by overriding `acceptsFirstMouse:` to return `YES`." The [*Event Architecture*](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/EventArchitecture/EventArchitecture.html) chapter says the same: the window "becomes the key window and discards the mouse-down event."
* [`-[NSView acceptsFirstMouse:]`](https://developer.apple.com/documentation/appkit/nsview/acceptsfirstmouse(for:)) (declared in `AppKit.framework/Headers/NSView.h:225`): "The default implementation ignores `event` and returns `false`… Most view objects refuse a click-through attempt, so the event simply activates the window. Many control objects, however, such as instances of `NSButton` and `NSSlider`, do accept them."
  * `NSSlider.h:27` and `NSMatrix.h:109` override it. [NSSlider docs](https://developer.apple.com/documentation/appkit/nsslider/acceptsfirstmouse(for:)): "Returns `true` by default."
  * The title-bar buttons are the canonical click-through controls (Event Handling Guide).
  * In practice, then: **traffic lights, most toolbar items, standard `NSButton`s and sliders click through. Text views, table/outline views, collection views, web views and custom views do not.** That is exactly the set of things people try to click.
* Apple's HIG (quoted by [ignorethecode, 2008](https://ignorethecode.net/blog/2008/12/04/the-dreaded-click-through/)): "Click-through is not a property of a class of controls… the same control could disable it when its use could be destructive." So the inconsistency is by design, and some authors refuse click-through on purpose.
* **Ordering and activation are done by the app's AppKit while it handles the mouse-down.** [`shouldDelayWindowOrderingForEvent:`](https://developer.apple.com/documentation/appkit/nsview/shoulddelaywindowordering(for:)) (`NSView.h:226`) lets a view delay "the normal window-ordering and activation mechanism… until the next mouse-up". [`-[NSApplication preventWindowOrdering]`](https://developer.apple.com/documentation/appkit/nsapplication/preventwindowordering()) (`NSApplication.h:281`) cancels it, "completely prevent[ing] the window from ordering forward and the application from becoming active." An app can only veto its own activation if the decision runs in-process. This is how Finder lets you drag a file out of a background window without raising it.
* Chromium spells out the WindowServer side (`content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm:858-874`, `main` fetched 2026-10-19): "A click that another process posts straight to this process does not activate the app, unlike one the window server routes here". A pid-targeted post (`CGEventPostToPid`) skips the activation path. A WindowServer-routed click starts it.
* **The consequence for pane:** whether the view gets the first click is decided **inside the target process, when it dequeues the event**, from its own state (`NSApp.isActive`, `window.isKeyWindow`, `view.acceptsFirstMouse:`). If the window is *already* key in an *already* active app when the real mouse-down is dequeued, the click is normal. That is the lever every working tool in §3 uses.

### 2.2 Native one-gesture cases (pane must not duplicate them)

| Gesture | Native macOS |
|---|---|
| Press on an inactive window's title bar and drag | Moves the window and brings it forward in one gesture, like Windows |
| Traffic lights in an inactive window | Click through (they also highlight on hover) |
| ⌘-click / ⌘-drag on a background window | Acts **without** activating or raising. Background-interaction idiom; PirouzSR also treats ⌘-click as "interact without activating" (README "Deliberate non-interference") |
| Right/⌃-click on a background window | Shows that app's context menu without first activating the window. Windows activates first. |
| File drag out of a background Finder window | Drags without raising, via `shouldDelayWindowOrderingForEvent` |
| Scroll wheel / trackpad scroll | Goes to the view under the pointer; no activation |

### 2.3 Scroll: verified behavior and exceptions

* WindowServer stamps each event with "the associated window and process port" and dispatches it to that process (*Event Architecture*). `NSWindow` hit-tests scroll-wheel events to the view under the pointer, with no key-window requirement. This is why scrolling background windows "just works" on macOS and always has. Even synthetic scroll events go under the pointer: Mac Mouse Fix re-posts its smoothed scroll events at `kCGSessionEventTap` (`refs/mac-mouse-fix/Helper/Core/Scroll/Scroll.m:1071,1125,1265-1270`), and they land in the window under the cursor.
* **Exceptions and quirks** (all inside the app; pane cannot change them):
  * **Modal sessions:** while an app runs an app-modal dialog, scroll in its other windows is blocked.
  * **Menu tracking:** an open menu captures the wheel.
  * **Scroll phases:** a background window gets `ScrollStarted` and the scroll events but **no `ScrollFinished`**, so the next gesture is merged with the previous one ([JDK-8126339](https://bugs.openjdk.org/browse/JDK-8126339), JavaFX). Frameworks that rely on phase/momentum can misbehave in inactive windows.
  * **Hover is not scroll:** many apps ignore mouse-moved in inactive windows. Chromium's default is `kWhenInActiveWindow`: `shouldIgnoreMouseEvent:` drops `NSEventTypeMouseMoved` when the window is neither main nor key (`render_widget_host_view_cocoa.mm:1020-1036`). So hover highlights do not track in background Chrome or Electron windows even though scrolling works.
  * **Games, VMs and remote-desktop clients** that capture the mouse or use relative mode handle input themselves. The [KiCad forum](https://forum.kicad.info/t/focus-follows-mouse-on-macos/62049) has similar "scroll works, other interactions need focus" reports.
* **Verdict:** (a) is already at parity. pane must only make sure no tap of its own activates on scroll. `MouseTap` does not tap scroll at all (`Sources/PaneKit/MouseTap.swift:65-67`).

### 2.4 Settings and defaults that change click behavior

**None changes click-through globally**, and there is no public or private system-wide "accept first mouse" switch. Apple documents it only as a per-view override. realDGD's API audit reached the same conclusion: "未发现由第三方进程全局强制所有控件接受首次点击的公开开关" ("found no public switch for a third-party process to force every control to accept the first click", `refs/realDGD_macOS-ClickThrough/docs/research/PHASE_0_RESEARCH.md:7`). The nearby knobs:

* `defaults write com.apple.Terminal FocusFollowsMouse -bool true`: focus-follows-mouse **between Terminal's own windows only** (implemented in Terminal itself).
* XQuartz: `defaults write org.xquartz.X11 wm_click_through -bool true` lets "a window-activating mouse click on an X window also be processed", and `wm_ffm` gives focus-follows-mouse ([Xquartz(1)](https://leancrew.com/all-this/man/man1/Xquartz.html)). Again in-process: XQuartz is the window manager for its X11 clients. It is the clearest example of click-through being an app-side policy.
* `NSWindowShouldDragOnGesture` (⌃⌘-drag anywhere moves a window) changes dragging, not first-mouse.
* [Klicko](https://www.iclarified.com/2976/rainer-brockerhoff-releases-klicko-11) (Rainer Brockerhoff) does the **opposite**. It blocks the native click-through on controls, so the first click only activates. It needs no injection either.

### 2.5 Toolkits

| Toolkit | First-mouse default | Notes |
|---|---|---|
| AppKit | Mostly NO (`NSButton`/`NSSlider`/title-bar buttons YES) | per view |
| SwiftUI | `.bordered` buttons click through. Before macOS 15, `.plain`/custom styles did **not**. **Fixed in macOS 15 beta 2**: all button styles click through | [Tietze 2024](https://christiantietze.de/posts/2024/04/enable-swiftui-button-click-through-inactive-windows) (an `NSHostingView` subclass overriding `acceptsFirstMouse` was the workaround) |
| Chromium / Chrome | NO unless the embedder sets accept-mouse-events-in-inactive-window. **YES for clicks posted directly to the process by another pid** | `render_widget_host_view_cocoa.mm:858-874` |
| Electron | `BrowserWindow` option `acceptFirstMouse`, **default `false`** on macOS | `electron/electron` `shell/browser/native_window_mac.mm` (`options.ValueOrDefault(options::kAcceptFirstMouse, false)` → `[window_ setAcceptsFirstMouse:]`); [docs](https://electronjs.org/docs/latest/tutorial/custom-window-interactions) |
| Ghostty | Watches `leftMouseDown` to focus a split on the first click **instead of** `acceptsFirstMouse`, "because that forces us to also handle the event and encode the event to the pty" (issue 2595) | `ghostty-org/ghostty` `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` |
| Emacs (NS port) | Recently gained an `ns-click-through` option | [commit](https://git.andros.dev/andros/emacs-gpu/commit/3a8ce5ac9c4652eb87bf0bce835d82083061a28b) |
| Hammerspoon's own canvas/webview | YES | `refs/hammerspoon/extensions/canvas/libcanvas.m:1038`, `webview/libwebview.m:297` |

The Ghostty note matters: even the app author found that accepting first mouse has side effects (the click is *processed*). Forcing every click through has the same consequence: a click meant only to focus also acts.

---

## 3. Prior art

Two families: **(A) focus-follows-mouse / raise-on-hover** (AutoRaise, yabai, Amethyst). These sidestep the problem, because by the time you click, the window is already key. **(B) click-time click-through** (four small 2026 utilities plus a Hammerspoon recipe).

### 3.1 AutoRaise (`sbmpost/AutoRaise`, `refs/AutoRaise`, `cfed944`)

* **Mechanism.**
  * Polls the pointer every `pollMillis` (default 50 ms) on a timer (`AutoRaise.mm:1029-1160`). Its only event tap is listen-only for keys (`:1534-1539`); there is no mouse tap.
  * Raise path: `AXRaise` then `NSRunningApplication activateWithOptions:0` (`:230-248`). Built with `OLD_ACTIVATION_METHOD`, it uses Carbon `SetFrontProcessWithOptions(kSetFrontProcessFrontWindowOnly)` instead.
  * `EXPERIMENTAL_FOCUS_FIRST` copies yabai's focus-without-raise (`:169-227`):
    * `_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)`.
    * `SLPSPostEventRecordTo` mouse-down and mouse-up records (type `0x01`/`0x02`, wid at `0x3c`, point bytes `0x20-0x2f` = `0xFF`).
    * For a same-process switch, two `0x0d` (AppKit-defined) records with subtype byte `0x8a` = 2 (deactivate old) and 1 (activate new), 10 ms apart.
* **Known problems it guards against.**
  * Aborts while a mouse button is held, so it never raises mid-drag or mid-resize (`:1138-1142`).
  * Aborts while the Dock or Mission Control is active.
  * `stayFocusedBundleIds` (for example `com.apple.screencaptureui`, `com.apple.SecurityAgent`) keeps screenshots and auth prompts from losing focus.
  * `ignoreApps`/`ignoreTitles` for apps that misbehave (the README calls out IntelliJ and Teams).
  * `requireMouseStop` and `mouseDelta` stop windows raising while the pointer just passes over them.
  * README: panes inside one window (tmux, iTerm splits) are not windows; GTK/SDL/wine apps need the old Carbon method.

### 3.2 yabai `focus_follows_mouse` (`refs/yabai`, `dd84572`)

* **Tap:** `CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, …)` (`src/mouse_handler.c:278`). The FFM mask adds `kCGEventMouseMoved` to the down/up/drag events (`src/mouse_handler.h:4-11`).
* **Hit test:** `SLSFindWindowAndOwner(g_connection, 0, 1, 0, &point, …)`. It skips yabai's own connection and JankyBorders overlays and re-queries below them (`src/window_manager.c:961-975`). This is a WindowServer-side hit test with no AX IPC.
* **`autofocus`** (`src/event_loop.c:1361-1397`):
  * Redirects to an attached `AXSheet`/`AXDrawer` child (via `SLSCopyAssociatedWindows`), because "we are not allowed to focus the main window in these cases".
  * Then calls `window_manager_focus_window_without_raise` (`window_manager.c:1293-1322`). For a same-app switch it posts the 0x0d records with a **40 ms** `usleep` "because some applications appear to be confused if both of the events appear instantaneously", then `_SLPSSetFrontProcessWithOptions` and a make-key record.
* **`autoraise`** (`:1398-1434`) skips the raise if it would fully cover a floating window the user is probably reaching for.
* **Suppression:**
  * Ignores moves within 1.25 s of a trackpad gesture.
  * Ignores moves while Mission Control is active.
  * Latches `ffm_window_id` so one hover focuses once.
  * Turns FFM off while a mouse-driven move or resize is in progress (`:1561-1581`).

### 3.3 Amethyst `focus-follows-mouse` (`refs/Amethyst`, `d1c4eef1`)

* `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (passive) → find the top window at the point → `topWindow.focus()` (`Amethyst/Managers/FocusFollowsMouseManager.swift:42-84`).
* Amethyst's separate "mouse-follows-focus" warps the cursor instead. It is muted for 0.5 s after an FFM focus to avoid a feedback loop (`:86-88`, `WindowManager.swift:766-768`).

**Family A verdict for pane.** FFM does solve the "wasted first click", but it is *not* Windows behavior. Keyboard focus would wander with the pointer, which Windows users do not expect (it is an off-by-default Ease of Access option on Windows). At most, offer it as an option. It is not the click-through design.

### 3.4 Click-time click-through tools

| Tool | Mechanism | Activation | Never double-fires? |
|---|---|---|---|
| **dainank/apple-click-through** (Hammerspoon, `refs/dainank_apple-click-through`, `ee0be75`) | `hs.eventtap` on `leftMouseDown` (`clickthrough/event.lua:157-160`). **Synchronous** `win:focus()` inside the callback, then **returns false = pass the original event** (`:36-150`) | `hs.window:focus()`, plus a hack that sets `AXFocused=true` on the hit element (`:140-143`) | Yes (no synthetic events), but no barrier: it just hopes focus has landed |
| **PirouzSR/ClickThrough** (`refs/PirouzSR_ClickThrough`, `c71a125`) | Session tap; **holds the callback** while activating, then returns the **original event unmodified** (`EventTap.swift:111-124`, `ClickThroughController.swift:89-124`). **Only for clicks that cross displays** | `raiseAndFocus` (AXRaise + `AXMain` + `AXFocused`) before **and** after `activate(options:[])`. `AXFrontmost` fallback if refused. Poll every 2 ms until the app's `kAXFocusedWindow` is the clicked window, re-asserting every 30 ms. Budget **200 ms** (`WindowActivator.swift:17-26, 60-109, 125-129, 210-233`). Re-raises windows that activation pushed back on other displays at 40/130/310 ms | Yes: "No synthetic clicks are ever generated, and no event is ever suppressed" |
| **laiglk/ClickThrough** (`refs/laiglk_ClickThrough`, `8091663`) | Session tap on main run loop. **Swallows** the down (`return nil`), buffers every later mouse event, resolves and activates on a queue, then **re-posts** the buffer at `.cgSessionEventTap` tagged via `eventSourceUserData` (`ClickEngine.swift:76-142, 206-220`) | `activate(options:[.activateIgnoringOtherApps])` (a no-op flag since macOS 14), then `AXRaise`, `kAXFocusedWindow`, `AXMain` (`WindowResolver.swift:53-60`). Confirms focus + "still under pointer", then waits a **12 ms** settle (`ClickEngine.swift:163-194`). 250 ms watchdog: before activation starts → flush normally; after → **discard the click** (`:121-130, 222-238`) | Yes if it replays only once. It explicitly avoids "un clic supplémentaire ajouté à un clic déjà transmis" ("an extra click added to one already sent") |
| **realDGD/macOS-ClickThrough** (`refs/realDGD_macOS-ClickThrough`, `65df8d6`) | Session tap, synchronous; writes `AXMain` on the hit window, then `AXFrontmost=true` on the app, then returns the same event (`docs/architecture.md`; "A4" in `poc/activation-preserve/README.md`) | AX only | Yes |

**Observations from their logs and notes** (their measurements, with their caveats):

* **`activate()` from a background agent is unreliable on macOS 14+.** `ignoringOtherApps` "is deprecated in macOS 14 and will have no effect" (`AppKit.framework/Headers/NSRunningApplication.h:27`). Activation is now *cooperative*: the active app should `yieldActivation(to:)` first (`NSApplication.h:224-249`), and `activate(from:options:)` says so explicitly (`NSRunningApplication.h:135-144`).
  * realDGD: plain `activate()` (their "A1") made a refuse-first-mouse target accept the click only when the probe itself was the frontmost source. Writing `AXFrontmost` (their "A3") worked with Chrome or Codex frontmost.
  * pane's own tests saw `NSWorkspace.openApplication(activates:)` refused.
* **Raising is not focusing.** For an AppKit app with several windows, `AXRaise` alone got 0/3 clicks delivered. Adding `AXMain`/`AXFocused` and re-asserting every 30 ms got 12/12 (PirouzSR `WindowActivator.swift:110-124` and README).
* **`activate()` raises all the app's windows**, including ones on other displays. PirouzSR has to put back the displaced windows at 40/130/310 ms. pane's SkyLight path (`_SLPSSetFrontProcessWithOptions(…, 0x200)`) fronts only one window and avoids this (`research/README.md` feature 1).
* **Cost.** "13-40 ms" per activating click. Tap limits: "the window server left the tap alone at 1000 ms and disabled it at 1500 ms". A tap that has been disabled only hears about it on the next event, so PirouzSR runs a 1 s re-arm watchdog.
* **Do not trust the readback.** realDGD: "即刻 AXFrontmost 读回仍为 false" ("an immediate `AXFrontmost` readback is still false") right after setting it, even though the click then landed. A single readback is not a barrier; poll the *focused window*.
* **Same-app second window was the gap.** With A3, a click into a second Chrome window of the already-frontmost app still needed two clicks, because A3 passed it through when the pid was already frontmost. The window-level check matters (`poc/activation-preserve/README.md`).
* **Chromium double-click quirk (native, no tool running).** A *swallowed* activating click followed quickly by a second press (`clickState=2`) produced two DOM clicks: a synthesized `detail=1` click and a `detail=2` down (`docs/research/DUPLICATE_CLICK_DIAGNOSTIC.md`). Deterministic click-through should make this *less* likely, because no click is swallowed any more.
* **Targeting traps** (PirouzSR README "Four window-server details", observed on "macOS 27"):
  * The Dock and Notification Center each keep a **full-display window above normal windows**.
  * **The cursor is itself a window** under the pointer.
  * Menus are windows at level **101** (`WindowFinder.swift:46-47, 201`).
  * `NSScreen.visibleFrame` always reserves the menu-bar and Dock strips, even when they are hidden.
  * Clicks on notifications, Dock stacks, the menu bar and Mission Control must be left alone.
* **Other tools.** Swish (closed source, trackpad window gestures) and Mac Mouse Fix (`refs/mac-mouse-fix`, `3199e73`: button remapping and smooth scroll) have no click-through. Amethyst's "mouse-follows-focus" is the reverse direction.

Caveat: three of these repos are weeks old with zero to 20 stars, and two claim testing on "macOS 27/28". Treat them as **mechanism evidence, not proof of compatibility**. None has been tested by pane on this machine (macOS 26, Darwin 25.6).

---

## 4. Design recommendation for pane: `ClickThrough`

### 4.1 Choice: hold-and-release, not swallow-and-replay

| | **Hold in tap, return the original event** (PirouzSR, realDGD, dainank) | **Swallow, then re-post copies** (laiglk) |
|---|---|---|
| Double action on views that already accept first mouse | Impossible: one physical click, delivered once | Avoided only if the original is always dropped |
| Event fidelity (timestamp, `clickState`, source pid, `isTrusted`) | Preserved exactly | Re-posted events carry pane as the source. Chromium treats directly posted clicks differently (`rwhvc.mm:858-869`). Other taps see them twice |
| Ordering of the following drag and up events | Automatic: they queue behind the held down | Must buffer and replay everything, with overflow handling |
| Failure mode (slow or hung app) | Release on budget → **native behavior** (the click only activates) | Must choose between "deliver to a possibly wrong window" and "drop the click" |
| Cost | Mouse input stalls up to the budget. **Need to measure** whether keyboard events wait behind a held mouse tap | No stall, but more code and more risk |

**Choose hold-and-release.** Keep swallow-and-replay as a documented fallback only if measurement shows hold-and-release stalls other input unacceptably.

### 4.2 Algorithm

Put this in `MouseTap` as a stage on `.leftMouseDown`, *after* the existing green-button and title-bar-double-click handling (`MouseTap.swift:102-122`), so their swallow semantics win. `MouseTap` already runs on its own thread (`MouseTap.swift:61-86`), so blocking it does not freeze pane's UI.

```
on leftMouseDown(event):
  0. Pass through (return event) if:
     - the feature is off, or pane posted this event (sourcePid == getpid() or our eventSourceUserData marker)
     - any modifier is held: ⌘ = native background click, ⌃ = context menu; ⌥ ⇧ also pass
     - event.clickState != 1 (a 2nd or 3rd click means the first one already landed)
  1. Hit-test WITHOUT IPC to the target:
     wid = event field kCGMouseEventWindowUnderMousePointer (91) if nonzero
           [verify it is populated at the session tap; Rectangle uses 92 there]
        ?? SLSFindWindowAndOwner(cid, 0, 1, 0, &pt, …) skipping own connection (yabai window_manager.c:961-975)
        ?? first CGWindowList(.optionOnScreenOnly) entry containing pt, skipping:
             level != 0 windows that span a whole display (Dock/NC backdrops), the cursor window, pane's own windows
     → (wid, ownerPID, layer, bounds)
  2. Pass through if:
     - layer != 0 (menus, status items, Dock, NC, Control Center, popovers, HUDs, pane's taskbar/panels,
       SecurityAgent, screenshot UI)
     - any on-screen window has layer 101 (a menu is open: this click dismisses it)
     - ownerPID == getpid(), or the app's activationPolicy != .regular, or the bundle is in the exclusion list
       (defaults: com.apple.loginwindow, com.apple.SecurityAgent, com.apple.screencaptureui, plus user-added
       games, VMs, remote desktop)
     - Mission Control / App Exposé / Stage Manager strip is showing (Dock- or WindowManager-owned full-screen windows)
     - the point is in the title-bar band (bounds.minY ..< minY+28, or toolbar height if known): the native
       title-bar press already activates and drags in one gesture, and MouseTap's drag-snap relies on it
  3. Already-active fast path (no IPC): pass through if ownerPID == frontmost pid AND wid == that app's
     focused window. Read this from WindowInventory's cached isFocused, kept current by AX focus notifications
     and WindowServerEvents. Only if the cache is unsure: AX.focusedWindow(of:) with a 30 ms messaging timeout.
  4. Sheet check: if wid has an attached AXSheet (SLSCopyAssociatedWindows → role), pass through. The click
     is blocked by the sheet anyway.
  5. Activate exactly that window, without raising the app's other windows:
       PrivateAPI.setFrontProcess(pid, wid, .userGenerated)          // _SLPSSetFrontProcessWithOptions 0x200
       PrivateAPI.makeKeyWindow(pid, wid)                            // existing make-key record (PrivateAPI.swift:120-142)
       AX: window.kAXMain = true; app.kAXFocusedWindow = window; AXRaise(window)  // belt and braces
     Fallback if the SLPS symbols are missing: app.kAXFrontmost = true (realDGD A3), then activate().
     Do NOT lead with NSRunningApplication.activate(): cooperative activation can refuse it, and it raises
     every window of the app.
  6. Barrier: poll every 2 ms, up to BUDGET = 150 ms (hard cap 200; the tap is killed around 1 s):
       done when AX.frontmostPID() == pid AND AX.focusedWindow(pid) == window
       every 30 ms re-assert step 5's make-key + kAXMain (the app may focus its own last window after activating)
     then an optional settle of ~1 run-loop turn (laiglk uses 12 ms; measure whether pane needs it).
  7. return event (unmodified), whether or not the barrier was met.
     Never post a synthetic click. Never drop the user's click.
```

**Concurrency and safety.**

* Generation token: if a second mouse-down arrives (it cannot while we hold, but the tap may be re-enabled after a timeout), abandon the old wait.
* Re-enable on `tapDisabledByTimeout`, as `MouseTap.handle` already does. Add PirouzSR's 1 s watchdog, because the disable notice only arrives with the next event.
* Pause on `NSWorkspace.sessionDidResignActive` and around sleep and wake, as Rectangle does (`docs/research/snapping-maximize.md:337`).

### 4.3 What this changes, what breaks, and mitigations

| Area | Effect | Mitigation |
|---|---|---|
| Buttons, links, list rows, text fields in inactive windows | **Work on the first click** (the goal). Text-field click places the caret | — |
| Views that already click through (`NSButton`, SwiftUI buttons on macOS 15+, sliders) | Still exactly one action, because the original click is delivered once. Adds 13–40 ms of latency | Optional: skip when the AX element under the point is an `AXButton` of a known AppKit app. Costs an IPC, so probably not worth it |
| Text selection / slider drag started in an inactive window | Works in one gesture: the down and drags queue behind the held down | — |
| **Dragging files out of a background Finder window** | **Changes**: the window now activates and raises first, like Windows, and can cover the drop target. macOS's `shouldDelayWindowOrdering` nicety is lost | ⌘-drag still gives native behavior (step 0). Optional per-app exclusion for Finder |
| Double-click into an inactive window | `clickState` is assigned before the session tap, so counting is unaffected. The first down is delayed by about 40 ms or less, still well inside the double-click interval | Pass `clickState ≥ 2` untouched (step 0) |
| Right/⌃-click (context menu) | Unchanged: macOS opens context menus in background windows without activating | Possible "Windows strict" option: activate on right-down with the same algorithm |
| Menus open / menu bar / status items / Dock / Notification Center / Control Center | Untouched (layer gates, layer-101 rule) | — |
| pane's own taskbar, previews, flyouts | Untouched (own pid). They already accept first mouse | — |
| Destructive controls whose authors refused click-through (HIG) | **Now fire on the first click.** This is the Windows trade-off and the point of the feature, but users should know | Default exclusion list; per-app toggle; ⌘ bypass |
| Slow or hung target app | Waits up to the budget, then delivers → native result (the click only activates). Input pauses up to 150–200 ms in that case | Short AX timeouts (30 ms per call); fast path avoids IPC for most clicks |
| Electron / Chrome | Gains click-through (default `acceptFirstMouse=false`). Hover state may be stale on the first click because inactive Chromium windows ignore mouse-moved | Measure; optionally post nothing (a synthetic mouse-moved would be a synthetic event) |
| Qt, Java, X11 (XQuartz), SDL/GTK/wine, games | AX focused-window reporting may be missing → barrier times out → native | Exclusion list; XQuartz has its own `wm_click_through` |
| Same app, different window | Handled (window-level check in step 3) | — |
| Secure Event Input | Keyboard only; mouse taps keep working. SecurityAgent/auth windows are not regular apps → pass | — |
| Fullscreen Spaces / Split View | Clicking the other half of a split → normal cross-app path. Fullscreen games are frontmost already → fast path | — |
| Make-key record before a real click | pane's record is a lone mouse-down at (300000,300000) (`PrivateAPI.swift:130-141`). yabai posts down+up. **Unverified**: whether a lone synthetic down leaves AppKit thinking a button is pressed when the real down arrives | Test both variants with a fixture app (below). Fall back to AX-only activation if either misbehaves |

### 4.4 Measuring before shipping (follow-up; not run here)

1. Build a fixture app in the style of realDGD's "FirstClickTarget": one view refuses first mouse, one accepts. Each counts completed down/up pairs.
2. For each source/target combination (cross-app, same-app second window, cross-display), check:
   * exactly one action per physical click, and zero duplicates on the accepting view;
   * latency histogram;
   * text selection and drag work;
   * double-click counts are right.
3. Repeat with Chrome, an Electron app, a SwiftUI app and Finder.
4. Tap behavior:
   * Does holding the mouse tap delay keyboard events? Does a mouse-up overtake the held down? (Expect no.)
   * Behavior near the ~1 s tap timeout.
5. Compare activation recipes: SkyLight versus `AXFrontmost` versus `activate()` while pane is a background agent.

### 4.5 Architectural limits

1. **There is no way to flip `acceptsFirstMouse` (or `shouldDelayWindowOrdering`, or Chromium's accept-mouse option) in another app from outside.**
   * It is an Objective-C method that the target's own `-[NSWindow sendEvent:]` calls on its own view objects while dispatching (§2.1).
   * WindowServer never asks for it.
   * There is no AX attribute, defaults key, Apple Event or IPC that exposes it.
   * Electron's and Chromium's equivalents are compile- or run-time options inside the app (`native_window_mac.mm`, `rwhvc.mm:840-874`).
   * Changing it needs code running in the target, and modern macOS blocks that:
     * **Hardened runtime** strips `DYLD_INSERT_LIBRARIES` unless the app has `com.apple.security.cs.allow-dyld-environment-variables`.
     * **Library validation** rejects dylibs not signed by the same team.
     * `task_for_pid` / `mach_inject` into hardened or platform processes is denied without `get-task-allow` or with SIP on.
     * **SIP** protects all Apple apps.
   * yabai's scripting addition shows the cost: it injects only into Dock.app and needs SIP partly disabled.
   * Even with SIP off, it would mean swizzling AppKit, Chromium and every other toolkit separately. That is not shippable.
2. **You cannot query whether a click would have been accepted** (§2.1). So ClickThrough always activates first. That is harmless for views that already accepted, but it cannot keep the cases where an app deliberately delays ordering (background file drags), except through ⌘ or exclusions.
3. **There is no atomic "activate, then deliver" primitive.** Activation is asynchronous and cooperative. The AX barrier is the best signal available, and a readback right after the write is unreliable (realDGD). Slow or hung apps therefore degrade to native behavior, and the budget has to stay far below the tap timeout.
4. **Hover, tooltips and cursor shape in inactive windows stay app-defined** (tracking-area options, Chromium's `kWhenInActiveWindow`). Windows' "hover works everywhere" cannot be granted from outside.
5. **Non-AppKit toolkits and games** that do their own focus or capture handling may ignore all of this.
6. **Overriding author intent is unavoidable.** Windows' `MA_ACTIVATEANDEAT` is an app choice that Windows honors. pane cannot see the macOS equivalent, so it overrides every refusal and relies on exclusions.
7. **Scroll needs nothing.** It is already Windows-like, and the in-app exceptions (modal sessions, JavaFX phases, menus) are not pane's to change.

---

## 5. Sources

**Windows**
* WM_MOUSEACTIVATE: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mouseactivate
* WM_MOUSEWHEEL: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
* The Old New Thing: https://devblogs.microsoft.com/oldnewthing/20160912-00/?p=94295 and https://devblogs.microsoft.com/oldnewthing/20240919-00/?p=110283
* Wine `dlls/win32u/defwnd.c` (commit `d36039e588`): https://github.com/wine-mirror/wine/blob/master/dlls/win32u/defwnd.c
* MouseWheelRouting: https://winaero.com/disable-scrolling-inactive-windows and https://www.ninjaone.com/blog/turn-on-or-off-scroll-inactive-windows/

**Apple**
* `acceptsFirstMouse(for:)`, `shouldDelayWindowOrdering(for:)`, `preventWindowOrdering()`, `NSSlider.acceptsFirstMouse` (developer.apple.com, fetched through the docs JSON on 2026-10-19)
* Cocoa Event Handling Guide: *Handling Mouse Events* and *Event Architecture* (developer.apple.com archive)
* SDK headers: `NSView.h:225-226`, `NSSlider.h:27`, `NSMatrix.h:109`, `NSApplication.h:224-249,281`, `NSRunningApplication.h:27,135-148`, `CGEventTypes.h:352,356,377-378,402-406`, `CGEvent.h:357-374`

**Toolkits**
* Chromium `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm` (`main`, 2026-10-19): https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm
* Electron `shell/browser/native_window_mac.mm`; docs: https://electronjs.org/docs/latest/tutorial/custom-window-interactions
* Ghostty `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, `SurfaceDragSource.swift`
* SwiftUI: https://christiantietze.de/posts/2024/04/enable-swiftui-button-click-through-inactive-windows

**Commentary and other tools**
* https://ignorethecode.net/blog/2008/12/04/the-dreaded-click-through/
* https://mjtsai.com/blog/2009/11/03/click-through-in-snow-leopard
* Klicko: https://www.iclarified.com/2976/rainer-brockerhoff-releases-klicko-11
* XQuartz: https://leancrew.com/all-this/man/man1/Xquartz.html
* JDK-8126339: https://bugs.openjdk.org/browse/JDK-8126339

## 6. Repos read (all under `refs/`)

| Repo | Commit | Date |
|---|---|---|
| sbmpost/AutoRaise | `cfed944` | 2026-09-22 |
| noah-nuebling/mac-mouse-fix | `3199e73` | 2026-10-19 |
| dainank/apple-click-through → `dainank_apple-click-through` | `ee0be75` | 2026-08-29 |
| laiglk/ClickThrough → `laiglk_ClickThrough` | `8091663` | 2026-10-06 |
| PirouzSR/ClickThrough → `PirouzSR_ClickThrough` | `c71a125` | 2026-09-18 |
| realDGD/macOS-ClickThrough → `realDGD_macOS-ClickThrough` | `65df8d6` | 2026-10-17 |
| yabai (existing clone) | `dd84572` | 2026-06-14 |
| Amethyst (existing clone) | `d1c4eef1` | 2026-10-18 |
| hammerspoon (existing clone) | `23e387e2` | 2026-07-08 |
