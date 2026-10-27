# Window-management engines on macOS: AeroSpace, yabai, Amethyst, Hammerspoon

How four mature macOS projects build the window-management engine underneath their UX: window registry, focus, threading, Spaces, hotkeys, animations, displays. The goal is to pick the right primitives for a Windows-style window model on macOS (per-window activation, app lifecycle tied to windows, true maximize and snapping, per-window taskbar, Windows keyboard model).

All `file:line` references are relative to `refs/`. Snapshots studied:

| Repo | Commit | Date |
|---|---|---|
| AeroSpace | `74a1bf17` | 2026-10-01 |
| yabai | `dd845723` | 2026-06-14 |
| Amethyst | `d1c4eef1` | 2026-10-18 |
| hammerspoon | `23e387e2` | 2026-07-08 |
| Silica (Amethyst's AX/CGS layer, `ianyh/Silica`, **not** in `refs/`; cloned to a scratch dir for reading) | `09353df4` | 2026-10-17 |

---

## 1. Overview (TL;DR)

* **Everyone uses the same base.** All four use the Accessibility API (`AXUIElement` and `AXObserver`) to enumerate, observe, move, resize, minimize, close and raise windows. All four use exactly one private call to map an AX window to its `CGWindowID`: `_AXUIElementGetWindow`. The window registry is keyed by `CGWindowID`. Window lists and z-order come from the public `CGWindowListCopyWindowInfo`.
* **They differ in how far into private APIs they go:**
  * **AeroSpace** uses one private API (`_AXUIElementGetWindow`) and never needs SIP disabled. It ignores native Spaces and fakes workspaces by moving windows into a screen corner. It has the most careful threading model: one AX thread and one `CFRunLoop` per app, with cancellable jobs.
  * **yabai** goes deep into SkyLight (`SLS*`, about 90 functions) from its own process, which works with SIP on. It optionally injects a payload into `Dock.app` (the WindowServer's "universal owner"), which needs SIP partly off, for anything that changes *another process's* window-server state: spaces, opacity, layer, sticky, shadow, z-order, fast move-to-space.
  * **Amethyst** sits in the middle: Silica (an Objective-C AX wrapper) plus a handful of CGS/SLPS calls for Space info and window-precise focus.
  * **Hammerspoon** exposes the same primitives to Lua. It is the fastest way to prototype the Windows model: `hs.window`, `hs.window.filter`, `hs.application.watcher`, `hs.hotkey`, `hs.eventtap`, `hs.screen`, `hs.canvas`.
* **Focusing one window, not the whole app, is possible without SIP:**
  * Best: `_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)`, plus two synthesized "make key window" event records via `SLPSPostEventRecordTo`, plus `AXRaise`. yabai and Amethyst do this, and it runs in yabai's main process, not the scripting addition.
  * Public fallback: `AXMain=true`, then `AXRaise`, then `NSRunningApplication.activate` (AeroSpace).
  * Deprecated Carbon option: `SetFrontProcessWithOptions(psn, kSetFrontProcessFrontWindowOnly)` (Hammerspoon).
* **AX calls are synchronous IPC into the target app.** A hung app blocks the caller. The defenses:
  * AeroSpace: per-app threads with cancellable jobs.
  * yabai: a 1-second global `AXUIElementSetMessagingTimeout` and a single worker thread.
  * Hammerspoon: `hs.window.timeout()` and a skip list of known-slow apps.
  * Amethyst: no explicit timeout; retries observer registration with backoff.

---

## 2. Per-repo architecture

### 2.1 AeroSpace (Swift, i3-like tiling, no SIP)

```
NSWorkspace notifs ─┐                    ┌─ AxAppThread "pid A" (CFRunLoopRun)
global mouseUp mon ─┼─► MainActor        │    AXObserver(app): WindowCreated, FocusedWindowChanged
hotkeys (Carbon) ───┤   refresh session ─┼─► AXObserver(win): UIElementDestroyed, (De)Miniaturized, Moved, Resized
CLI socket ─────────┘   (cancellable)    └─ AxAppThread "pid B" ...
         │
         ▼
  Tree model (Workspace → TilingContainer/Floating/macOS-native containers → MacWindow{CGWindowID})
         │
  layoutWorkspaces(): AX set size/pos on visible ws, hide invisible ws windows in a screen corner
```

* **Entry point:** `AeroSpace/Sources/AppBundle/initAppBundle.swift:5-36`. It waits for AX permission (polling `AXIsProcessTrusted`, `util/accessibility.swift:5-22`), loads config, starts a socket server, `GlobalObserver.initObserver()`, then runs a non-cancellable startup refresh.
* **Per-app actor:** `tree/MacApp.swift:48-100` spawns a dedicated `Thread` per app. That thread:
  * creates `AXUIElementCreateApplication(pid)`;
  * subscribes app-level notifications `kAXWindowCreatedNotification` and `kAXFocusedWindowChangedNotification` (`:68-70`);
  * calls `CFRunLoopRun()` (`:86`).

  All AX objects for that app live on that thread. `ThreadGuardedValue` (`util/ThreadGuardedValue.swift:3-24`) enforces thread affinity at runtime.
* **Per-window subscriptions** (`MacApp.swift:375-383`): `kAXUIElementDestroyedNotification`, `kAXWindowDeminiaturizedNotification` and `kAXWindowMiniaturizedNotification` trigger a refresh; `kAXMovedNotification` goes to `movedObs` and `kAXResizedNotification` to `resizedObs` (mouse-driven tiling).
* **Refresh session** (`layout/refresh.swift:8-56`): cancels any in-flight refresh, reads the native focused window, then refreshes all apps in a `TaskGroup`, in parallel across app threads (`MacApp.swift:259-298`). It garbage-collects dead windows, registers new ones, normalizes the tree and lays out workspaces.
* **The model is a tree:**
  * `tree/Workspace.swift`, `tree/TilingContainer.swift`;
  * special containers for macOS-owned states (popups, minimized, native-fullscreen, hidden-app windows) in `tree/MacosUnconventionalWindowsContainer.swift`;
  * the state machine moving windows between them in `normalizeLayoutReason.swift:23-51`.
* **Workspaces are emulated:**
  * Invisible workspaces' windows are moved to the bottom-left or bottom-right corner of a monitor, 1 px left visible (`tree/MacWindow.swift:122-155`, `layout/refresh.swift:155-202`).
  * Rationale is in `docs/guide.adoc:427-446`.

### 2.2 yabai (C/ObjC, BSP tiling, SkyLight plus an optional Dock injection)

```
Carbon kEventApp{Launched,Terminated,FrontSwitched} ─┐
NSWorkspace / KVO(finishedLaunching, activationPolicy)┤
AXObserver callbacks (on MAIN runloop) ───────────────┼─► l
```

---

> **INCOMPLETE:** this report was cut off during writing. The rest of the findings (yabai, Amethyst, Hammerspoon, comparison, private-API catalog) are summarized in `README.md` under "Engine layer".
