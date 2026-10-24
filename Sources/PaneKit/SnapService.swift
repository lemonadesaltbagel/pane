// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Decision 4: macOS edge tiling off so pane owns snapping (applied/restored through `SystemSettings`;
/// takes effect live, no WindowManager restart — measured).
public enum NativeTakeover {
    public static let changes: [SystemSettings.Change] = [
        .init("com.apple.WindowManager", "EnableTilingByEdgeDrag", .bool(false)),
        .init("com.apple.WindowManager", "EnableTopTilingByEdgeDrag", .bool(false)),
    ]
}

/// Windows 11 Win+Arrow semantics as a pure state machine.
public enum SnapTransitions {
    public enum Arrow { case left, right, up, down }

    public enum Action: Equatable {
        case snap(Geometry.Snap)
        case restore
        case minimize
        /// Move to the neighbouring display in that direction, landing on the given snap.
        case moveToDisplay(Arrow, Geometry.Snap)
    }

    public static func next(from state: PlacementStore.State, _ arrow: Arrow) -> Action {
        switch (state, arrow) {
        case (.normal, .up): return .snap(.maximize)
        case (.normal, .down): return .minimize
        case (.normal, .left): return .snap(.leftHalf)
        case (.normal, .right): return .snap(.rightHalf)

        case (.snapped(.maximize), .down): return .restore
        case (.snapped(.maximize), .left): return .snap(.leftHalf)
        case (.snapped(.maximize), .right): return .snap(.rightHalf)
        case (.snapped(.maximize), .up): return .snap(.maximize)

        case (.snapped(.leftHalf), .up): return .snap(.topLeft)
        case (.snapped(.leftHalf), .down): return .snap(.bottomLeft)
        case (.snapped(.leftHalf), .right): return .restore
        case (.snapped(.leftHalf), .left): return .moveToDisplay(.left, .rightHalf)

        case (.snapped(.rightHalf), .up): return .snap(.topRight)
        case (.snapped(.rightHalf), .down): return .snap(.bottomRight)
        case (.snapped(.rightHalf), .left): return .restore
        case (.snapped(.rightHalf), .right): return .moveToDisplay(.right, .leftHalf)

        case (.snapped(.topLeft), .down): return .snap(.leftHalf)
        case (.snapped(.topLeft), .right): return .snap(.topRight)
        case (.snapped(.topLeft), .up): return .snap(.maximize)
        case (.snapped(.topLeft), .left): return .moveToDisplay(.left, .topRight)

        case (.snapped(.topRight), .down): return .snap(.rightHalf)
        case (.snapped(.topRight), .left): return .snap(.topLeft)
        case (.snapped(.topRight), .up): return .snap(.maximize)
        case (.snapped(.topRight), .right): return .moveToDisplay(.right, .topLeft)

        case (.snapped(.bottomLeft), .up): return .snap(.leftHalf)
        case (.snapped(.bottomLeft), .right): return .snap(.bottomRight)
        case (.snapped(.bottomLeft), .down): return .minimize
        case (.snapped(.bottomLeft), .left): return .moveToDisplay(.left, .bottomRight)

        case (.snapped(.bottomRight), .up): return .snap(.rightHalf)
        case (.snapped(.bottomRight), .left): return .snap(.bottomLeft)
        case (.snapped(.bottomRight), .down): return .minimize
        case (.snapped(.bottomRight), .right): return .moveToDisplay(.right, .bottomLeft)

        // Thirds (from Snap Layouts): Win+Up maximizes, Win+Down restores, sideways goes to the halves.
        case (.snapped, .up): return .snap(.maximize)
        case (.snapped, .down): return .restore
        case (.snapped, .left): return .snap(.leftHalf)
        case (.snapped, .right): return .snap(.rightHalf)
        }
    }
}

/// Window placement behaviors on every app's windows: title-bar double-click and green button →
/// maximize/restore, drag to an edge → snap (with a preview callback while dragging), dragging a snapped window
/// restores its size, Win+Arrow transitions. Placement state is shared, so all paths agree on "maximized".
public final class SnapService {
    public struct Options {
        public var titleBarDoubleClick = true
        public var greenButton = true
        public var dragSnap = true
        public var snapLayouts = true
        public init() {}
    }

    public let options: Options
    /// Called on the main queue while dragging: the snap target to preview (AX coordinates), or nil.
    public var onPreview: ((CGRect?) -> Void)?
    /// Snap Layouts: pointer rested on a window's green button (main queue) — show the layouts there.
    public var onLayoutsRequested: ((AXUIElement, CGRect) -> Void)?
    public var onLayoutsDismissed: (() -> Void)?
    /// A window was snapped into a zone from a layout or a drag (main queue): Snap Assist offers the zones left.
    public var onAssist: ((AXUIElement, Geometry.Snap) -> Void)?

    private let lock = NSLock()
    private var store = PlacementStore()
    private var mouse: MouseTap?

    // MARK: Settings (live)

    /// Apps whose windows pane doesn't snap (`windows.snap` per app, `apps.ignored`): drag snapping, Win+arrow snaps,
    /// Snap Layouts and Snap Assist leave them alone. The green button and double-click still maximize.
    public var isExcluded: ((pid_t) -> Bool)?
    public var layoutsOnHover = true      // windows.snapLayouts
    public var assistEnabled = true       // windows.snapAssist
    public var gap: CGFloat = 0           // windows.gaps
    public var topDragLayouts = true      // windows.snapLayoutsOnTopDrag
    public var shakeEnabled = false       // windows.shake
    /// Dragging near the top centre (main queue): show the Snap Layouts there; nil = the pointer left (hide them).
    public var onTopDrag: ((CGPoint?) -> Void)?
    /// Title-bar shake (main queue): minimize the other windows, or bring them back.
    public var onShake: ((AXUIElement) -> Void)?
    private var topZone: Geometry.Snap?
    /// The layouts flyout's zone under the pointer (set from the main thread while dragging to the top).
    public func setTopDragZone(_ zone: Geometry.Snap?) { lock.withLock { topZone = zone } }

    func excluded(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return isExcluded?(pid) ?? false
    }

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Remembered across restarts

    /// Where the snap state (restore frames) is kept, so snapped and maximized windows still restore to their earlier
    /// size after pane restarts. nil = memory only (tests, previews).
    public var persistURL: URL? {
        didSet { load() }
    }
    private let saveQueue = DispatchQueue(label: "pane.placements")

    private func load() {
        guard let persistURL, let data = try? Data(contentsOf: persistURL),
              var loaded = try? JSONDecoder().decode(PlacementStore.self, from: data) else { return }
        // Only windows that still exist (any Space, minimized or not).
        loaded.keep(only: Set(WindowServer.windows(onScreenOnly: false).map(\.id)))
        lock.withLock { store = loaded }
    }

    private func save() {
        guard let persistURL else { return }
        let snapshot = lock.withLock { store }
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: persistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: persistURL, options: .atomic)
        }
    }

    /// Windows gone for good (closed): forget them (called with the inventory's windows now and then).
    public func forgetClosed(alive: Set<CGWindowID>) {
        let changed = lock.withLock { () -> Bool in
            let before = store.count
            store.keep(only: alive)
            return store.count != before
        }
        if changed { save() }
    }

    public func start() throws {
        var tapOptions = MouseTap.Options()
        tapOptions.titleBarDoubleClick = options.titleBarDoubleClick
        tapOptions.greenButton = options.greenButton
        tapOptions.dragSnap = options.dragSnap
        tapOptions.greenButtonHover = options.snapLayouts
        let tap = try MouseTap(options: tapOptions)
        tap.onGreenButtonHover = { [weak self] window, frame in
            guard let self, self.layoutsOnHover, !self.excluded(window) else { return }
            DispatchQueue.main.async { self.onLayoutsRequested?(window, frame) }
        }
        tap.onGreenButtonHoverEnded = { [weak self] in DispatchQueue.main.async { self?.onLayoutsDismissed?() } }
        tap.onTitleBarDoubleClick = { [weak self] window in self?.toggleMaximize(window) }
        tap.onGreenButton = { [weak self] window in self?.toggleMaximize(window) }
        tap.onDragStarted = { [weak self] window, point, start in self?.dragStarted(window, at: point, startFrame: start) }
        tap.onDragMoved = { [weak self] _, point in self?.preview(at: point) }
        tap.onDragEnded = { [weak self] window, point in self?.dragEnded(window, at: point) }
        mouse = tap
    }

    public func stop() {
        mouse?.stop()
        mouse = nil
    }

    // MARK: Actions (also used by keyboard handlers)

    public func state(of window: AXUIElement) -> PlacementStore.State {
        guard let wid = PrivateAPI.windowID(of: window), let frame = AX.frame(window) else { return .normal }
        return lock.withLock { store.state(of: wid, currentFrame: frame) }
    }

    public func toggleMaximize(_ window: AXUIElement) {
        guard let wid = PrivateAPI.windowID(of: window), let frame = AX.frame(window), let work = Geometry.workArea(for: frame) else { return }
        let target = lock.withLock { store.toggleMaximize(wid, currentFrame: frame, workArea: work) }
        AX.setFrame(window, target)
        save()
    }

    public func snap(_ window: AXUIElement, to snap: Geometry.Snap, on screen: NSScreen? = nil, assist: Bool = false) {
        guard let wid = PrivateAPI.windowID(of: window), let frame = AX.frame(window) else { return }
        let work = screen.map { Geometry.cocoaToAX($0.visibleFrame, primaryHeight: Geometry.primaryHeight) } ?? Geometry.workArea(for: frame)
        guard let work else { return }
        var target = lock.withLock { store.snap(wid, currentFrame: frame, to: snap, workArea: work) }
        if gap > 0, snap != .maximize {
            target = Geometry.gapped(target, in: work, gap: gap)
            lock.withLock { store.setApplied(wid, target) }
        }
        AX.setFrame(window, target)
        save()
        if assist, assistEnabled { DispatchQueue.main.async { [weak self] in self?.onAssist?(window, snap) } }
    }

    public func restore(_ window: AXUIElement) {
        guard let wid = PrivateAPI.windowID(of: window), let frame = AX.frame(window),
              let target = lock.withLock({ store.restore(wid, currentFrame: frame) }) else { return }
        AX.setFrame(window, target)
        save()
    }

    /// Win+Arrow on `window`.
    public func arrow(_ arrow: SnapTransitions.Arrow, on window: AXUIElement) {
        if excluded(window) { return }
        switch SnapTransitions.next(from: state(of: window), arrow) {
        case .snap(let snap): self.snap(window, to: snap)
        case .restore: restore(window)
        case .minimize: AX.set(window, kAXMinimizedAttribute, kCFBooleanTrue)
        case .moveToDisplay(let direction, let snap):
            if let screen = neighbourScreen(of: window, direction) { self.snap(window, to: snap, on: screen) }
        }
    }

    /// Win+Arrow on the focused window of the frontmost app.
    public func arrowOnFocusedWindow(_ arrow: SnapTransitions.Arrow) {
        guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid) else { return }
        self.arrow(arrow, on: window)
    }

    private func neighbourScreen(of window: AXUIElement, _ direction: SnapTransitions.Arrow) -> NSScreen? {
        guard let frame = AX.frame(window), let current = Geometry.screen(containing: frame) else { return nil }
        let others = NSScreen.screens.filter { $0 != current }
        switch direction {
        case .left: return others.filter { $0.frame.midX < current.frame.midX }.max { $0.frame.midX < $1.frame.midX }
        case .right: return others.filter { $0.frame.midX > current.frame.midX }.min { $0.frame.midX < $1.frame.midX }
        default: return nil
        }
    }

    // MARK: Drag

    private var dragging: (wid: CGWindowID, restoredOnce: Bool)?
    private var draggedWindow: AXUIElement?
    private var dragExcluded = false
    private var inTopRegion = false
    /// Shake detection: x positions of direction changes during this drag.
    private var shakeTurns: [Date] = []
    private var lastX: CGFloat?, lastDirection: CGFloat = 0, runStart: CGFloat?
    private var shookThisDrag = false

    /// Windows: dragging a maximized/snapped window by its title bar restores its free size under the cursor.
    /// The state is judged on the frame from before the drag (by now the window has already moved).
    private func dragStarted(_ window: AXUIElement, at point: CGPoint, startFrame: CGRect) {
        guard let wid = PrivateAPI.windowID(of: window) else { return }
        dragging = (wid, false)
        draggedWindow = window
        dragExcluded = excluded(window)
        shakeTurns = []; lastX = nil; lastDirection = 0; runStart = nil; shookThisDrag = false
        inTopRegion = false
        lock.withLock { topZone = nil }
        if MouseTap.debug { print("SnapService dragStarted start=\(startFrame) state=\(lock.withLock { store.state(of: wid, currentFrame: startFrame) })") }
        guard case .snapped = lock.withLock({ store.state(of: wid, currentFrame: startFrame) }),
              let restoreFrame = lock.withLock({ store.restore(wid, currentFrame: startFrame) }),
              let frame = AX.frame(window) else { return }
        // Keep the grab point at the same relative x within the restored width.
        let ratio = startFrame.width > 0 ? (point.x - frame.minX) / startFrame.width : 0.5
        let origin = CGPoint(x: point.x - restoreFrame.width * ratio, y: frame.minY)
        AX.setFrame(window, CGRect(origin: origin, size: restoreFrame.size))
        dragging = (wid, true)
        save()
    }

    private func screenFrameAX(containing point: CGPoint) -> CGRect? {
        let height = Geometry.primaryHeight
        return NSScreen.screens.map { Geometry.cocoaToAX($0.frame, primaryHeight: height) }.first { $0.contains(point) }
    }

    private func target(at point: CGPoint) -> CGRect? {
        guard let screen = screenFrameAX(containing: point), let zone = SnapZones.zone(for: point, in: screen),
              let work = Geometry.workArea(for: CGRect(origin: point, size: CGSize(width: 1, height: 1))) else { return nil }
        return Geometry.rect(for: zone, in: work)
    }

    private func preview(at point: CGPoint) {
        if shakeEnabled { detectShake(point.x) }
        guard !dragExcluded else { return }
        // Windows 11: dragging to the top centre shows the Snap Layouts there.
        if topDragLayouts, let screen = screenFrameAX(containing: point) {
            let near = point.y < screen.minY + 80 && abs(point.x - screen.midX) < screen.width * 0.2
            if near != inTopRegion {
                inTopRegion = near
                DispatchQueue.main.async { [weak self] in self?.onTopDrag?(near ? point : nil) }
            } else if near {
                DispatchQueue.main.async { [weak self] in self?.onTopDrag?(point) }
            }
            if near { DispatchQueue.main.async { [weak self] in self?.onPreview?(nil) }; return }
        }
        let rect = target(at: point)
        DispatchQueue.main.async { [weak self] in self?.onPreview?(rect) }
    }

    /// Windows' Aero Shake: three quick direction changes (each a swing of 40+ pt) within a second.
    private func detectShake(_ x: CGFloat) {
        defer { lastX = x }
        guard !shookThisDrag, let lastX else { runStart = x; return }
        let direction: CGFloat = x > lastX ? 1 : x < lastX ? -1 : 0
        guard direction != 0 else { return }
        if direction != lastDirection {
            if let start = runStart, abs(lastX - start) >= 40, lastDirection != 0 {
                shakeTurns.append(Date())
                shakeTurns = shakeTurns.filter { Date().timeIntervalSince($0) < 1.0 }
                if shakeTurns.count >= 3, let window = draggedWindow {
                    shookThisDrag = true
                    DispatchQueue.main.async { [weak self] in self?.onShake?(window) }
                }
            }
            runStart = lastX
            lastDirection = direction
        }
    }

    private func dragEnded(_ window: AXUIElement, at point: CGPoint) {
        dragging = nil
        draggedWindow = nil
        DispatchQueue.main.async { [weak self] in self?.onPreview?(nil) }
        if inTopRegion {
            inTopRegion = false
            DispatchQueue.main.async { [weak self] in self?.onTopDrag?(nil) }
            if let zone = lock.withLock({ topZone }) {
                lock.withLock { topZone = nil }
                snap(window, to: zone, assist: true)
                return
            }
        }
        if dragExcluded || shookThisDrag { return }
        guard let screen = screenFrameAX(containing: point), let zone = SnapZones.zone(for: point, in: screen) else { return }
        let height = Geometry.primaryHeight
        snap(window, to: zone, on: NSScreen.screens.first { Geometry.cocoaToAX($0.frame, primaryHeight: height) == screen }, assist: true)
    }
}
