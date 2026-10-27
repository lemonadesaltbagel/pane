// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Windows-style snap zones for drag-to-edge (Rectangle's thresholds: 5 pt edge margin, 20 pt corners). An edge another
/// display touches at the pointer doesn't snap: the pointer crosses there (Windows).
public enum SnapZones {
    public static func zone(for point: CGPoint, in screen: CGRect, others: [CGRect] = [], margin: CGFloat = 5, corner: CGFloat = 20) -> Geometry.Snap? {
        func touches(_ other: CGRect, _ edge: CGRectEdge) -> Bool {
            switch edge {
            case .minXEdge: return abs(other.maxX - screen.minX) < 1 && point.y >= other.minY && point.y < other.maxY
            case .maxXEdge: return abs(other.minX - screen.maxX) < 1 && point.y >= other.minY && point.y < other.maxY
            case .minYEdge: return abs(other.maxY - screen.minY) < 1 && point.x >= other.minX && point.x < other.maxX
            case .maxYEdge: return abs(other.minY - screen.maxY) < 1 && point.x >= other.minX && point.x < other.maxX
            }
        }
        func open(_ edge: CGRectEdge) -> Bool { !others.contains { $0 != screen && touches($0, edge) } }
        let left = point.x <= screen.minX + margin && open(.minXEdge), right = point.x >= screen.maxX - margin - 1 && open(.maxXEdge)
        let top = point.y <= screen.minY + margin && open(.minYEdge), bottom = point.y >= screen.maxY - margin - 1 && open(.maxYEdge)
        let nearTop = point.y <= screen.minY + corner, nearBottom = point.y >= screen.maxY - corner - 1
        if left && nearTop || top && point.x <= screen.minX + corner { return .topLeft }
        if right && nearTop || top && point.x >= screen.maxX - corner - 1 { return .topRight }
        if left && nearBottom || bottom && point.x <= screen.minX + corner { return .bottomLeft }
        if right && nearBottom || bottom && point.x >= screen.maxX - corner - 1 { return .bottomRight }
        if top { return .maximize }
        if left { return .leftHalf }
        if right { return .rightHalf }
        return nil
    }
}

/// An active session event tap that implements the Windows mouse behaviors on other apps' windows:
/// title-bar double-click → maximize/restore, green button → maximize (instead of a fullscreen Space), and
/// drag-to-edge snapping. It runs on its own thread; hit-testing uses AX (Rectangle's TitleBarManager /
/// GreenButtonManager / SnappingManager approach). Handlers are called on the tap thread.
public final class MouseTap {
    public struct Options {
        public var titleBarDoubleClick = true
        public var greenButton = true
        public var dragSnap = true
        /// Report a dwell over a window's green button (Snap Layouts flyout trigger).
        public var greenButtonHover = false
        public init() {}
    }

    public var onTitleBarDoubleClick: ((AXUIElement) -> Void)?
    public var onGreenButton: ((AXUIElement) -> Void)?
    /// Window, pointer location (AX coordinates). Started fires once the window has actually moved, with the
    /// frame the window had when the button went down.
    public var onDragStarted: ((AXUIElement, CGPoint, CGRect) -> Void)?
    public var onDragMoved: ((AXUIElement, CGPoint) -> Void)?
    public var onDragEnded: ((AXUIElement, CGPoint) -> Void)?
    /// Pointer rested on a green button: window and the button's AX frame. Ended: pointer left it.
    public var onGreenButtonHover: ((AXUIElement, CGRect) -> Void)?
    public var onGreenButtonHoverEnded: (() -> Void)?
    public var hoverDwell: TimeInterval = 0.35
    private var lastHoverCheck = Date.distantPast
    private var hoverStart: Date?
    private var hoverFired = false

    public let options: Options
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var swallowNextUp = false
    private var drag: (window: AXUIElement, startFrame: CGRect, started: Bool)?

    public static let debug = ProcessInfo.processInfo.environment["PANE_DEBUG_TAP"] != nil

    /// Height of the title-bar band for windows without a toolbar.
    public static let titleBarHeight: CGFloat = 28

    public init(options: Options = Options()) throws {
        self.options = options
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            var types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
            if options.greenButtonHover { types.append(.mouseMoved) }
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                let tap = Unmanaged<MouseTap>.fromOpaque(refcon!).takeUnretainedValue()
                return tap.handle(type, event)
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
        thread.name = "pane.MouseTap"
        thread.start()
        ready.wait()
        if tap == nil { throw MouseTapError.tapRefused }
    }

    deinit { stop() }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if Pause.isOn, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            TapDiagnostics.disabled("MouseTap", type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            let point = event.location
            let hit = Self.hitTest(point)
            if Self.debug { print("MouseTap down at \(point) clickState=\(event.getIntegerValueField(.mouseEventClickState)) hit=\(hit.map { "\($0.subrole ?? "-") titleBar=\($0.inTitleBar)" } ?? "nil")") }
            guard let hit else { return Unmanaged.passUnretained(event) }
            // The green button reports AXFullScreenButton, or AXZoomButton on windows that can't go fullscreen
            // (then macOS zooms to "fit", which isn't Windows' maximize either). Option-click passes through.
            if options.greenButton, hit.subrole == "AXFullScreenButton" || hit.subrole == "AXZoomButton", !event.flags.contains(.maskAlternate) {
                swallowNextUp = true
                onGreenButton?(hit.window)
                return nil
            }
            if hit.inTitleBar {
                if options.titleBarDoubleClick, event.getIntegerValueField(.mouseEventClickState) == 2 {
                    swallowNextUp = true
                    onTitleBarDoubleClick?(hit.window)
                    return nil
                }
                if options.dragSnap, let frame = AX.frame(hit.window) { drag = (hit.window, frame, false) }
            }
            return Unmanaged.passUnretained(event)
        case .mouseMoved:
            checkHover(event.location)
            return Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            if var current = drag {
                if !current.started, let frame = AX.frame(current.window), frame.origin != current.startFrame.origin {
                    // Only a real move counts (Rectangle compares frames to tell a drag from a click).
                    current.started = true
                    drag = current
                    onDragStarted?(current.window, event.location, current.startFrame)
                }
                if current.started { onDragMoved?(current.window, event.location) }
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if swallowNextUp { swallowNextUp = false; return nil }
            if let current = drag {
                drag = nil
                let moved = current.started || AX.frame(current.window).map { $0.origin != current.startFrame.origin } ?? false
                if moved { onDragEnded?(current.window, event.location) }
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private var hoverGeneration = 0
    private var lastPoint = CGPoint.zero

    /// Throttled (~12 Hz) AX hit test; fires once per dwell over a green button. A resting pointer sends no
    /// more events, so the dwell is confirmed by a timed re-check rather than by the next move.
    private func checkHover(_ point: CGPoint) {
        lastPoint = point
        let now = Date()
        guard now.timeIntervalSince(lastHoverCheck) > 0.08 else { return }
        lastHoverCheck = now
        let onGreen = Self.greenButtonHit(point) != nil
        if !onGreen {
            if hoverFired { onGreenButtonHoverEnded?() }
            hoverStart = nil
            hoverFired = false
            hoverGeneration += 1
            return
        }
        guard hoverStart == nil else { return }
        hoverStart = now
        hoverGeneration += 1
        let generation = hoverGeneration
        guard let runLoop else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + hoverDwell) { [weak self] in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                guard let self, generation == self.hoverGeneration, !self.hoverFired,
                      let (window, frame) = Self.greenButtonHit(self.lastPoint) else { return }
                self.hoverFired = true
                self.onGreenButtonHover?(window, frame)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    static func greenButtonHit(_ point: CGPoint) -> (AXUIElement, CGRect)? {
        guard let hit = hitTest(point), hit.subrole == "AXFullScreenButton" || hit.subrole == "AXZoomButton",
              let button = AX.button(hit.window, kAXFullScreenButtonAttribute) ?? AX.button(hit.window, kAXZoomButtonAttribute),
              let frame = AX.frame(button) else { return nil }
        return (hit.window, frame)
    }

    struct Hit {
        let window: AXUIElement
        let subrole: String?
        let inTitleBar: Bool
    }

    /// The element under the pointer, its window, and whether the point is in the title-bar band.
    static func hitTest(_ point: CGPoint) -> Hit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element else { return nil }
        var window: AXUIElement? = AX.role(element) == kAXWindowRole ? element : AX.get(element, kAXWindowAttribute)
        if window == nil { window = AX.get(element, kAXTopLevelUIElementAttribute) }
        guard let window, AX.subrole(window) == kAXStandardWindowSubrole, let frame = AX.frame(window) else { return nil }
        let role = AX.role(element)
        let isControl = role == kAXButtonRole || role == kAXTextFieldRole || role == kAXPopUpButtonRole
        return Hit(window: window, subrole: AX.subrole(element), inTitleBar: !isControl && point.y - frame.minY <= titleBarHeight)
    }
}

public enum MouseTapError: Error { case tapRefused }

/// Synthesized input for tests and demos (posted at the HID level, so the system treats it like a real mouse).
public enum SyntheticMouse {
    public static func click(at point: CGPoint, clickState: Int64 = 1) {
        // Arrive first: a press far from the current cursor position can register as a tiny title-bar drag.
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    public static func rightClick(at point: CGPoint, modifiers: CGEventFlags = []) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        SyntheticKeyboard.holdModifiers(modifiers)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        SyntheticKeyboard.releaseModifiers(modifiers)
    }

    /// A click with modifiers held the way a person does: real modifier key down/up around it. Setting flags on
    /// the mouse events instead leaves those modifiers held system-wide (measured: Shift stuck after ⇧-click).
    public static func click(at point: CGPoint, modifiers: CGEventFlags) {
        SyntheticKeyboard.holdModifiers(modifiers)
        usleep(20_000)
        click(at: point)
        SyntheticKeyboard.releaseModifiers(modifiers)
    }

    public static func doubleClick(at point: CGPoint) {
        click(at: point, clickState: 1)
        usleep(60_000)
        click(at: point, clickState: 2)
    }

    /// Press at `from`, move to `to` in `steps`, optionally hold, release.
    public static func drag(from: CGPoint, to: CGPoint, steps: Int = 30, hold: TimeInterval = 0.3) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        usleep(useconds_t(hold * 1_000_000))
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
