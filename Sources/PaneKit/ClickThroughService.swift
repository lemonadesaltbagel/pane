// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Windows-style click-through: the first click on an inactive window both activates it and acts.
///
/// Measured on macOS 26: scrolling inactive windows already works natively, AppKit buttons
/// already accept the first click, but plain content views (AppKit's default `acceptsFirstMouse` = NO) eat it —
/// the click only activates. That decision lives inside the target app's views and can't be changed from
/// outside, so pane compensates: it holds the mouse-down on an inactive window, brings that window forward,
/// then replays the down (and any drag/up that arrived meanwhile) to the now-active window.
///
/// Left alone: pane's own windows, excluded apps, title bars (dragging inactive windows already works), ⌘-clicks
/// (macOS's "click in a background window without activating it"), double-clicks, clicks on the frontmost app's
/// key window, and any click while pane is replaying. Design matches docs/research/click-through.md.
public final class ClickThroughService {
    /// Marks pane's replayed events so its own tap lets them through.
    static let replayTag: Int64 = 0x5041_4E45 // "PANE"

    public var excludedPIDs: Set<pid_t> = [getpid()]
    /// Apps that keep macOS's own first-click behavior.
    public var excludedBundleIDs: Set<String> = []
    /// Longest wait for the activation before replaying anyway (the click then behaves like plain macOS).
    public var activationTimeout: TimeInterval = 0.2
    /// Diagnostics: number of clicks held and replayed.
    public private(set) var replayed = 0
    /// How long the last held click waited before replay (the extra latency on an activating click).
    public private(set) var lastHold: TimeInterval?

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    /// While a click is held: the events that arrived after it (drag/up), in order.
    private var pending: [CGEvent]?

    public init() {}

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                Unmanaged<ClickThroughService>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            }
            self.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap = self.tap {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if self.tap != nil { CFRunLoopRun() }
        }
        thread.name = "pane.ClickThrough"
        thread.start()
        ready.wait()
        if tap == nil { throw MouseTapError.tapRefused }
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            TapDiagnostics.disabled("ClickThrough", type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if Pause.isOn { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return Unmanaged.passUnretained(event) }

        // A click is being held: queue what follows it so the replay keeps the order (drags, double clicks).
        let holding = lock.withLock { () -> Bool in
            guard pending != nil else { return false }
            if let copy = event.copy() { pending?.append(copy) }
            return true
        }
        if holding { return nil }

        guard type == .leftMouseDown, event.getIntegerValueField(.mouseEventClickState) <= 1,
              let target = Self.inactiveTarget(for: event, excluding: excludedPIDs),
              !excludedBundleIDs.contains(NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier ?? "") else {
            return Unmanaged.passUnretained(event)
        }
        guard let down = event.copy() else { return Unmanaged.passUnretained(event) }
        lock.withLock { pending = [] }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.activateAndReplay(target, down) }
        return nil // held
    }

    struct Target {
        let pid: pid_t
        let window: AXUIElement
    }

    /// The window under the pointer when it's not the frontmost app's focused window and the click lands in its
    /// content (not the title bar), without ⌘.
    static func inactiveTarget(for event: CGEvent, excluding excluded: Set<pid_t>) -> Target? {
        if event.flags.contains(.maskCommand) { return nil }
        let point = event.location
        guard let hit = MouseTap.hitTest(point), let pid = AX.pid(of: hit.window), !excluded.contains(pid), !hit.inTitleBar,
              let frame = AX.frame(hit.window), frame.contains(point) else { return nil }
        if let subrole = hit.subrole, ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole) { return nil }
        let frontmost = AX.frontmostPID()
        if frontmost == pid, let focused = AX.focusedWindow(of: pid), CFEqual(focused, hit.window) { return nil }
        return Target(pid: pid, window: hit.window)
    }

    private func activateAndReplay(_ target: Target, _ down: CGEvent) {
        let start = Date()
        Focus.focusFast(target.window)
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if AX.frontmostPID() == target.pid, let focused = AX.focusedWindow(of: target.pid), CFEqual(focused, target.window) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.03) // let the app finish becoming key
        // Replay the held down and everything queued behind it; keep holding until the queue is drained so a
        // live mouse-up can't overtake the replayed mouse-down.
        down.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
        down.post(tap: .cgSessionEventTap)
        lock.withLock { lastHold = Date().timeIntervalSince(start) }
        while true {
            let batch = lock.withLock { () -> [CGEvent] in
                let events = pending ?? []
                if events.isEmpty { pending = nil } else { pending = [] }
                return events
            }
            if batch.isEmpty { break }
            for event in batch {
                event.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
                event.post(tap: .cgSessionEventTap)
            }
        }
        lock.withLock { replayed += 1 }
    }
}
