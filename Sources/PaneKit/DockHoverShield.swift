// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Keeps the real Dock from reacting to the pointer while it's over pane's taskbar.
///
/// pane keeps the Dock under the taskbar to reserve the bar's space (DockReservation). The Dock tracks the pointer by
/// itself, even under another window: hovering the bar over a Dock tile made the Dock draw its app label above the bar
/// (measured, TaskbarLookTests.hoverOverBarDoesNotReachTheDock). An event tap on the Dock's process only drops the
/// pointer-move and enter/exit events the Dock would get while the pointer is inside the bar. Clicks never reach the Dock
/// there anyway (the bar is on top). Dock-owned overlays above the bar (Mission Control, the ⌘⇥ switcher) are left alone.
public final class DockHoverShield {
    private let lock = NSLock()
    private var rect: CGRect? // global top-left coordinates (CG/AX), nil = bar hidden
    /// The Dock's icon row (its hover zones): it pokes a few points above the bar (measured: icons 880–922, bar from 884).
    private var dockZone: CGRect?
    private var zoneTimer: Timer?
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var dockPID: pid_t = 0
    private var overlayCheckedAt = Date.distantPast
    private var overlayShown = false
    private var launchObserver: NSObjectProtocol?
    private let barLevel: Int
    /// Events dropped so far (diagnostics, tests).
    public private(set) var dropped = 0

    public init(barLevel: Int) { self.barLevel = barLevel }

    /// The bar's frame in global top-left coordinates, or nil while it's hidden.
    public func setBar(_ frame: CGRect?) { lock.withLock { rect = frame } }

    /// Windows-style full screen is on (taskbar hidden, Dock auto-hidden): the Dock must not slide up when the pointer
    /// reaches the bottom edge, so the bottom strip of the screen is blocked too.
    private var edge: CGRect?
    /// The bottom edges of the other displays: the pointer held there takes the Dock (and with it the main display's
    /// reserved space) to that display (measured, MultiDisplayTests.dockStaysOnTheMainDisplay).
    private var otherEdges: [CGRect] = []
    private var screenObserver: NSObjectProtocol?
    private func updateOtherEdges() {
        // Tests: PANE_DISABLE=dockdisplays leaves them open (shows what blocking them changes).
        guard !(ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").contains("dockdisplays") else { return }
        // The corners stay open: the Dock runs hot corners too.
        let edges = Geometry.screenFramesAX.dropFirst().map { CGRect(x: $0.minX + 16, y: $0.maxY - 12, width: $0.width - 32, height: 12) }
        lock.withLock { otherEdges = edges }
    }
    private var fullScreenOn = false, autoHideOn = false
    public func setFullScreen(_ on: Bool) { fullScreenOn = on; updateEdge() }
    /// The taskbar auto-hides (the Dock auto-hides too, reserving nothing): the bottom edge is pane's, never the Dock's.
    public func setTaskbarAutoHide(_ on: Bool) { autoHideOn = on; updateEdge() }
    private func updateEdge() {
        // Tests: PANE_DISABLE=dockedge leaves the edge open (shows what blocking it changes).
        if (ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").contains("dockedge") { return }
        let on = fullScreenOn || autoHideOn
        let screen = NSScreen.screens.first.map { Geometry.cocoaToAX($0.frame, primaryHeight: Geometry.primaryHeight) }
        lock.withLock { edge = on ? screen.map { CGRect(x: $0.minX, y: $0.maxY - 12, width: $0.width, height: 12) } : nil }
    }

    /// Call on the main thread. Follows the Dock across restarts (pane restarts it at launch).
    public func start() {
        attach()
        updateOtherEdges()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateOtherEdges()
        }
        refreshDockZone()
        zoneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshDockZone() }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" else { return }
            self?.attach()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshDockZone() }
        }
    }

    /// Reads the Dock's icon row through AX (main thread): blocked along with the bar, padded a little.
    public func refreshDockZone() {
        // The Dock restarted without telling us (its launch isn't always announced): attach to the new one.
        if let live = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first(where: { !$0.isTerminated }),
           live.processIdentifier != dockPID {
            attach()
        }
        // Tests: PANE_DISABLE=dockzone keeps only the bar (shows what the Dock's icon row adds).
        guard dockPID != 0, !(ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").contains("dockzone") else { return }
        let lists = (AX.get(AX.app(dockPID), kAXChildrenAttribute) as [AXUIElement]?) ?? []
        let zone = lists.compactMap(AX.frame).filter { $0.width > 0 }.reduce(CGRect.null) { $0.union($1) }
        lock.withLock { dockZone = zone.isNull ? nil : zone.insetBy(dx: -4, dy: -4) }
    }

    public func stop() {
        zoneTimer?.invalidate()
        zoneTimer = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        detach()
    }

    private func attach() {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first(where: { !$0.isTerminated }) else { return }
        dockPID = dock.processIdentifier
        // Pointer moves, drags (no button is down over the bar, but be thorough) and the WindowServer's tracking-area
        // enter/exit events (types 8 and 9, which drive the Dock's hover; exits are always passed on).
        let types: [UInt32] = [CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDragged.rawValue, 8, 9]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreateForPid(pid: dockPID, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                                callback: { _, type, event, info in
            let shield = Unmanaged<DockHoverShield>.fromOpaque(info!).takeUnretainedValue()
            return shield.filter(type, event)
        }, userInfo: me) else { return }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "pane.dock-hover-shield"
        thread.start()
        ready.wait()
        self.thread = thread
    }

    private func detach() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil; thread = nil
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if TrayLog.enabled, type.rawValue == 8 || type.rawValue == 9 {
            let cursor = CGEvent(source: nil)?.location ?? .zero
            TrayLog.write("dock-shield: type \(type.rawValue) at \(Int(event.location.x)),\(Int(event.location.y)) cursor \(Int(cursor.x)),\(Int(cursor.y))")
        }
        // "Pointer left" always gets through: a label the Dock did show must be able to go away.
        guard type.rawValue != 9 else { return Unmanaged.passUnretained(event) }
        // While the bar is up: the bar and the Dock's whole icon row (which reaches above the bar).
        let snapshot: (CGRect?, CGRect?, CGRect?, [CGRect]) = lock.withLock { (rect, dockZone, edge, otherEdges) }
        let point = event.location
        var inside = false
        if let bar = snapshot.0 { inside = bar.contains(point) || (snapshot.1?.contains(point) ?? false) }
        if let edge = snapshot.2, edge.contains(point) { inside = true }
        if snapshot.3.contains(where: { $0.contains(point) }) { inside = true }
        guard inside, !dockOverlayShown() else { return Unmanaged.passUnretained(event) }
        dropped += 1
        return nil
    }

    /// A Dock window above the bar (Mission Control, the app switcher, Launchpad): the Dock must see the pointer then.
    /// Checked at most 4 times a second.
    private func dockOverlayShown() -> Bool {
        if Date().timeIntervalSince(overlayCheckedAt) < 0.25 { return overlayShown }
        overlayCheckedAt = Date()
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        overlayShown = list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == dockPID && (($0[kCGWindowLayer as String] as? Int) ?? 0) > barLevel
        }
        return overlayShown
    }
}
