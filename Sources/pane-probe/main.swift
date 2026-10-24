// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit


// Manual probe for real apps. Examples:
//   pane-probe perms
//   pane-probe list --bundle com.apple.TextEdit
//   pane-probe zorder
//   pane-probe focus <pid> "<title substring>" [publicActivate|axFrontmost|skyLight]
//   pane-probe snap <pid> "<title substring>" maximize|leftHalf|rightHalf|topLeft|topRight|bottomLeft|bottomRight
//   pane-probe watch <pid> [seconds]
//   pane-probe focus-wid <pid> <wid>
//   pane-probe minimize|unminimize <pid> "<title substring>"
//   pane-probe watch-ws <pid> [seconds]
//   pane-probe survey                     (read-only table of every running app)

func usage() -> Never {
    print("usage: pane-probe perms | list (--pid N | --bundle ID) | zorder | focus PID TITLE [STRATEGY] | snap PID TITLE SNAP | watch PID [SECONDS] | focus-wid PID WID | minimize|unminimize PID TITLE")
    exit(2)
}

func pids(from args: ArraySlice<String>) -> [pid_t] {
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--pid": return [pid_t(it.next() ?? "") ?? 0]
        case "--bundle": return NSRunningApplication.runningApplications(withBundleIdentifier: it.next() ?? "").map(\.processIdentifier)
        default: break
        }
    }
    usage()
}

func window(_ pid: pid_t, matching title: String) -> AXUIElement {
    guard let window = AX.windows(of: pid).first(where: { (AX.title($0) ?? "").contains(title) }) else {
        print("no window of \(pid) titled like \"\(title)\""); exit(1)
    }
    return window
}

func describe(_ rect: CGRect?) -> String {
    guard let r = rect else { return "-" }
    return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { usage() }

switch command {
case "perms":
    print("Accessibility:", AX.isTrusted, " Screen Recording:", Capture.hasScreenRecording)
    for (name, present) in PrivateAPI.availability.sorted(by: { $0.key < $1.key }) { print("  \(name): \(present)") }

case "list":
    for pid in pids(from: args.dropFirst()) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("== \(name) pid \(pid) hidden=\(NSRunningApplication(processIdentifier: pid)?.isHidden ?? false) frontmost=\(AX.frontmostPID() == pid)")
        print("AX windows:")
        for w in AX.windows(of: pid) {
            let wid = PrivateAPI.windowID(of: w).map(String.init) ?? "-"
            print("  wid=\(wid) \"\(AX.title(w) ?? "")\" \(AX.role(w) ?? "-")/\(AX.subrole(w) ?? "-") minimized=\(AX.isMinimized(w)) frame=\(describe(AX.frame(w)))")
        }
        print("WindowServer windows (all, front-to-back):")
        for w in WindowServer.windows(onScreenOnly: false) where w.pid == pid {
            print("  wid=\(w.id) layer=\(w.layer) onscreen=\(w.isOnScreen) spaces=\(PrivateAPI.spaces(of: w.id)) bounds=\(describe(w.bounds)) name=\(w.name ?? "-")")
        }
        print("Snapshot:", AppWindowSnapshot.capture(pid: pid), "→", LifecyclePolicy().decide(AppWindowSnapshot.capture(pid: pid)))
    }

case "zorder":
    for w in WindowServer.windows() where w.layer == 0 {
        print("wid=\(w.id) pid=\(w.pid) \(w.ownerName ?? "?") bounds=\(describe(w.bounds))")
    }

case "focus":
    let a = Array(args)
    guard a.count >= 3, let pid = pid_t(a[1]) else { usage() }
    let strategy = a.count > 3 ? FocusStrategy(rawValue: a[3]) ?? .skyLight : .skyLight
    print("focus via \(strategy):", Focus.focus(window(pid, matching: a[2]), using: strategy))

case "focus-wid":
    // By WindowServer id: reaches windows AX can't see (other Spaces).
    let a = Array(args)
    guard a.count == 3, let pid = pid_t(a[1]), let wid = CGWindowID(a[2]) else { usage() }
    print("focus wid \(wid):", Focus.focus(wid: wid, pid: pid))

case "minimize", "unminimize":
    let a = Array(args)
    guard a.count == 3, let pid = pid_t(a[1]) else { usage() }
    print(AX.set(window(pid, matching: a[2]), kAXMinimizedAttribute, command == "minimize" ? kCFBooleanTrue : kCFBooleanFalse).rawValue)

case "snap":
    let a = Array(args)
    guard a.count == 4, let pid = pid_t(a[1]) else { usage() }
    let snaps: [String: Geometry.Snap] = ["maximize": .maximize, "leftHalf": .leftHalf, "rightHalf": .rightHalf,
                                          "topLeft": .topLeft, "topRight": .topRight, "bottomLeft": .bottomLeft, "bottomRight": .bottomRight]
    guard let snap = snaps[a[3]] else { usage() }
    let w = window(pid, matching: a[2])
    guard let frame = AX.frame(w), let work = Geometry.workArea(for: frame) else { print("no frame"); exit(1) }
    let target = Geometry.rect(for: snap, in: work)
    AX.setFrame(w, target)
    print("target \(describe(target)) → actual \(describe(AX.frame(w)))")

case "watch":
    let a = Array(args)
    guard a.count >= 2, let pid = pid_t(a[1]) else { usage() }
    let seconds = a.count > 2 ? Double(a[2]) ?? 30 : 30
    let watcher = try WindowWatcher(pid: pid)
    watcher.onEvent = { record, count in print("\(record.date) \(record.event) via \(record.trigger) tracked=\(count)") }
    watcher.onNotification = { print("\(Date())   notification \($0)") }
    setvbuf(stdout, nil, _IOLBF, 0)
    print("watching \(pid) for \(Int(seconds))s (tracked=\(watcher.trackedCount), registration failures=\(watcher.registrationFailures.map(\.rawValue)))")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))

case "press":
    // Press a menu item through AX, e.g. press <pid> "File>New Window"
    let a = Array(args)
    guard a.count == 3, let pid = pid_t(a[1]) else { usage() }
    let path = a[2].split(separator: ">").map(String.init)
    guard let item = AX.menuItem(of: pid, path: path) else { print("no menu item \(path)"); exit(1) }
    print("enabled=\(AX.get(item, kAXEnabledAttribute) as Bool? ?? false) press=\(AX.perform(item, kAXPressAction).rawValue)")

case "realapps":
    // Write-path check on real apps using ONLY windows this command opens (File ▸ New … via AX) and closes.
    let only = Array(args).dropFirst().first
    let allTargets: [(String, [[String]])] = [
        ("com.apple.finder", [["File", "New Finder Window"]]),
        ("com.microsoft.edgemac", [["File", "New Window"]]),
        ("com.microsoft.VSCode", [["File", "New Window"]]),
        // Not Terminal: it hosts the user's sessions, and in a fullscreen Space "New Window" becomes a tab there.
    ]
    let targets = allTargets.filter { only == nil || $0.0 == only }
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }
    let snap = SnapService()
    print("| App | new window | maximize | left half | restore exact | setFrame ms | focus (public) | closed |")
    print("|---|---|---|---|---|---|---|---|")
    for (bundle, paths) in targets {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
        let pid = app.processIdentifier
        let before = Set(AX.windows(of: pid).compactMap(PrivateAPI.windowID))
        Focus.focusBest(AX.windows(of: pid).first ?? AX.app(pid))
        var pressed = false
        for path in paths where !pressed { if let item = AX.menuItem(of: pid, path: path) { pressed = AX.perform(item, kAXPressAction) == .success } }
        var window: AXUIElement?
        _ = waitFor(5) {
            window = AX.windows(of: pid).first { w in PrivateAPI.windowID(of: w).map { !before.contains($0) } ?? false && AppWindowSnapshot.isStandard(w) }
            return window != nil
        }
        guard let window, let original = AX.frame(window), let work = Geometry.workArea(for: original) else {
            print("| \(app.localizedName ?? bundle) | no (pressed=\(pressed)) | | | | | | |"); continue
        }
        Thread.sleep(forTimeInterval: 0.8)
        let start = Date()
        snap.toggleMaximize(window)
        let maxOK = waitFor(2) { AX.frame(window).map { Geometry.approximatelyEqual($0, work, tolerance: 4) } ?? false }
        let ms = Date().timeIntervalSince(start) * 1000
        if !maxOK { FileHandle.standardError.write("\(bundle): maximize target \(describe(work)) got \(describe(AX.frame(window)))\n".data(using: .utf8)!) }
        snap.toggleMaximize(window)
        snap.snap(window, to: .leftHalf)
        let leftOK = waitFor(2) { AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work), tolerance: 4) } ?? false }
        snap.restore(window)
        let pre = AX.frame(window)
        let restoreOK = waitFor(2) { AX.frame(window).map { Geometry.approximatelyEqual($0, original, tolerance: 4) } ?? false }
        // Focus: put Terminal's front window over it, then bring this one back alone.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first.flatMap({ AX.focusedWindow(of: $0.processIdentifier) }), bundle != "com.apple.Terminal" {
            Focus.focusBest(other)
            Thread.sleep(forTimeInterval: 0.4)
        }
        let focusOK = Focus.focusBest(window) && waitFor(1) { AX.focusedWindow(of: pid).flatMap(PrivateAPI.windowID) == PrivateAPI.windowID(of: window) }
        let wid = PrivateAPI.windowID(of: window)
        if let close = AX.button(window, kAXCloseButtonAttribute) { AX.perform(close, kAXPressAction) }
        let closed = waitFor(3) { !AX.windows(of: pid).contains { PrivateAPI.windowID(of: $0) == wid } }
        _ = pre
        print("| \(app.localizedName ?? bundle) | yes | \(maxOK) | \(leftOK) | \(restoreOK) | \(String(format: "%.0f", ms)) | \(focusOK) | \(closed) |")
    }

case "cover-test":
    // Throwaway window in an app (default Edge): can AX place it over the menu bar / Dock area? Closes it after.
    let a = Array(args)
    let bundle = a.count > 1 ? a[1] : "com.microsoft.edgemac"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("not running"); exit(1) }
    let pid = app.processIdentifier
    let before = Set(AX.windows(of: pid).compactMap(PrivateAPI.windowID))
    Focus.focusBest(AX.windows(of: pid).first ?? AX.app(pid))
    for path in [["File", "New Window"], ["File", "New Finder Window"]] { if let item = AX.menuItem(of: pid, path: path), AX.perform(item, kAXPressAction) == .success { break } }
    var window: AXUIElement?
    for _ in 0..<100 {
        window = AX.windows(of: pid).first { PrivateAPI.windowID(of: $0).map { !before.contains($0) } ?? false }
        if window != nil { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let window else { print("no new window"); exit(1) }
    Thread.sleep(forTimeInterval: 0.8)
    let screen = Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight)
    AX.setFrame(window, screen)
    Thread.sleep(forTimeInterval: 0.5)
    print("\(app.localizedName ?? bundle): asked \(describe(screen)) → got \(describe(AX.frame(window)))")
    if let close = AX.button(window, kAXCloseButtonAttribute) { AX.perform(close, kAXPressAction) }

case "menu-survey":
    // Read-only: how much of each app's menu bar AX exposes (no menu is opened or pressed).
    print("| App | Kind | Top-level menus | Items (1st level) | With shortcut | Read ms |")
    print("|---|---|---|---|---|---|")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let start = Date()
        let top = MenuMirror.topLevel(of: app.processIdentifier)
        let items = top.flatMap(MenuMirror.items)
        let ms = Date().timeIntervalSince(start) * 1000
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: app.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? "")) ?? []
        let kind = frameworks.contains("Electron Framework.framework") ? "Electron" : frameworks.contains(where: { $0.contains("Chrom") || $0.contains("Edge") }) ? "Chromium" : "native"
        print("| \(app.localizedName ?? "?") | \(kind) | \(top.count) (\(top.prefix(6).map(\.title).joined(separator: ", "))) | \(items.filter { !$0.isSeparator }.count) | \(items.filter { $0.shortcut != nil }.count) | \(String(format: "%.0f", ms)) |")
    }

case "survey":
    // Read-only: how pane's rules see every running app (nothing is clicked or changed).
    let visible = PrivateAPI.visibleSpaces()
    let server = WindowServer.windows(onScreenOnly: false)
    print("| App | Kind | AX windows (std/other/min) | AX ms | Subroles | CG normal windows on a Space (shown/hidden Space) | Status item | Decision |")
    print("|---|---|---|---|---|---|---|---|")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
        let pid = app.processIdentifier
        let start = Date()
        let windows = AX.windows(of: pid)
        let ms = Date().timeIntervalSince(start) * 1000
        let standard = windows.filter(AppWindowSnapshot.isStandard).count
        let minimized = windows.filter(AX.isMinimized).count
        let subroles = Set(windows.compactMap(AX.subrole)).sorted().joined(separator: ",")
        let onSpaces = server.filter { $0.pid == pid && $0.layer == 0 }.map { PrivateAPI.spaces(of: $0.id) }.filter { !$0.isEmpty }
        let shown = onSpaces.filter { $0.contains(where: visible.contains) }.count
        let snapshot = AppWindowSnapshot.capture(pid: pid)
        let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? ""
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
        let kind = contents.contains("Electron Framework.framework") ? "Electron"
            : contents.contains(where: { $0.contains("Chromium") || $0.contains("Edge Framework") || $0.contains("Chrome Framework") }) ? "Chromium"
            : app.activationPolicy == .accessory ? "accessory" : "regular"
        print("| \(app.localizedName ?? "?") | \(kind) | \(standard)/\(windows.count - standard)/\(minimized) | \(String(format: "%.1f", ms)) | \(subroles.isEmpty ? "-" : subroles) | \(shown)/\(onSpaces.count - shown) | \(snapshot.hasStatusItem ? "yes" : "-") | \(LifecyclePolicy().decide(snapshot)) |")
    }

case "watch-ws":
    // SkyLight window notifications for one app's windows (plus connection-wide create/destroy).
    let a = Array(args)
    guard a.count >= 2, let pid = pid_t(a[1]) else { usage() }
    let seconds = a.count > 2 ? Double(a[2]) ?? 30 : 30
    setvbuf(stdout, nil, _IOLBF, 0)
    // The connection's notifications are delivered through AppKit's event machinery.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    NSApp.finishLaunching()
    let events = WindowServerEvents.shared
    let start = Date()
    events.handler = { kind, wid in print(String(format: "+%.3fs", Date().timeIntervalSince(start)), kind, wid) }
    let wids = WindowServer.windows(onScreenOnly: false).filter { $0.pid == pid && $0.layer == 0 }.map(\.id)
    print("start=\(events.start()) watch=\(events.watch(wids)) wids=\(wids)")
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
    NSApp.run()

case "noise":
    // Synthetic "user" input from another process, confined to a rect (a test fixture's window):
    //   pane-probe noise SECONDS X Y W H [--clicks] [--scroll]
    // HID-level pointer moves every ~12 ms, plus a click and/or a scroll every ~90 ms. Pointer restored at the end.
    let a = Array(args)
    guard a.count >= 6, let seconds = Double(a[1]), let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]) else { usage() }
    let clicks = a.contains("--clicks"), scroll = a.contains("--scroll")
    let original = CGEvent(source: nil)?.location
    let source = CGEventSource(stateID: .hidSystemState)
    let start = Date()
    var step = 0, posted = (moves: 0, clicks: 0, scrolls: 0)
    while Date().timeIntervalSince(start) < seconds {
        step += 1
        let p = CGPoint(x: x + w * (0.2 + 0.6 * Double((step * 37) % 100) / 100), y: y + h * (0.3 + 0.4 * Double((step * 53) % 100) / 100))
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        posted.moves += 1
        if clicks, step % 8 == 0 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.flags = []
                e?.post(tap: .cghidEventTap)
                usleep(8_000)
            }
            posted.clicks += 1
        }
        if scroll, step % 8 == 4 {
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            posted.scrolls += 1
        }
        usleep(12_000)
    }
    if let original { CGWarpMouseCursorPosition(original) }
    print("noise posted moves \(posted.moves) clicks \(posted.clicks) scrolls \(posted.scrolls)")

case "cursor-hide-test":
    // Does CGDisplayHideCursor work from a background process, with and without the private
    // "SetsCursorInBackground" connection property? Reports CGCursorIsVisible (via dlsym) each way.
    let rt = dlopen(nil, RTLD_NOW)
    typealias VisibleFn = @convention(c) () -> Int32
    typealias MainConn = @convention(c) () -> Int32
    typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let visSym = dlsym(rt, "CGCursorIsVisible") else { print("CGCursorIsVisible unavailable"); exit(1) }
    let visible = unsafeBitCast(visSym, to: VisibleFn.self)
    let display = CGMainDisplayID()
    print("front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"); visible at start: \(visible())")
    CGDisplayHideCursor(display); usleep(50_000)
    print("plain hide → visible: \(visible())")
    CGDisplayShowCursor(display); usleep(50_000)
    if let mc = dlsym(rt, "CGSMainConnectionID"), let sp = dlsym(rt, "CGSSetConnectionProperty") {
        let cid = unsafeBitCast(mc, to: MainConn.self)()
        let r = unsafeBitCast(sp, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        print("SetsCursorInBackground set → \(r)")
        CGDisplayHideCursor(display); usleep(50_000)
        print("hide with property → visible: \(visible())")
        CGDisplayShowCursor(display); usleep(50_000)
    } else { print("CGS symbols unavailable") }
    print("visible at end: \(visible())")

case "cursor-hide-visual":
    // For a human watching the cursor: 2 s visible, 2 s plain hide, 2 s visible, 2 s hide with
    // SetsCursorInBackground, then visible. Hide/show calls are balanced.
    let rt = dlopen(nil, RTLD_NOW)
    typealias MainConn = @convention(c) () -> Int32
    typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    let display = CGMainDisplayID()
    sleep(2)
    CGDisplayHideCursor(display); sleep(2); CGDisplayShowCursor(display)
    sleep(2)
    if let mc = dlsym(rt, "CGSMainConnectionID"), let sp = dlsym(rt, "CGSSetConnectionProperty") {
        let cid = unsafeBitCast(mc, to: MainConn.self)()
        _ = unsafeBitCast(sp, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
    CGDisplayHideCursor(display); sleep(2); CGDisplayShowCursor(display)
    print("done")

default:
    usage()
}
