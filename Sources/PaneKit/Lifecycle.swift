// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Watches one app's windows through an AXObserver on its own thread and run loop (AeroSpace style: AX is
/// blocking IPC, so it never runs on the main thread). Subscribes before enumerating (Swindler's ordering).
///
/// Measured on macOS 26 (see test-results): `kAXUIElementDestroyedNotification` is NOT a reliable close
/// signal — AppKit only tears the window's AX element down when the window is deallocated, which waits for
/// the app's next event-loop turn and never happens for apps that keep closed windows around. No AX
/// notification fires when the last window closes. So every signal is treated as a hint to re-enumerate
/// `kAXWindows` and diff by window ID. The fast signal is the WindowServer's "ordered out" (816), which
/// arrives right as a window closes (also on minimize/hide — the diff tells them apart); a slow poll is the
/// safety net.
public final class WindowWatcher {
    public enum Event: Equatable {
        case opened(CGWindowID)
        case closed(CGWindowID)
    }

    public struct Record {
        public let date: Date
        public let event: Event
        /// The AX notification (or "poll") that led to the event being noticed.
        public let trigger: String
    }

    public let pid: pid_t
    /// Called on the watcher thread.
    public var onEvent: ((Record, Int) -> Void)?
    /// Every notification received, for diagnostics.
    public var onNotification: ((String) -> Void)?

    private var observer: AXObserver?
    private var runLoop: CFRunLoop?
    private var timer: CFRunLoopTimer?
    private var known: [CGWindowID: AXUIElement] = [:]
    private let lock = NSLock()
    private var log: [Record] = []
    private var windowServerToken: UUID?
    /// AXObserverAddNotification errors for per-window registrations (diagnostics).
    public private(set) var registrationFailures: [AXError] = []

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    /// `pollInterval` nil disables the safety-net poll (to measure what notifications alone catch).
    /// `windowServerEvents` adds SkyLight's window notifications as triggers (needs NSApp running).
    public init(pid: pid_t, pollInterval: TimeInterval? = 1.0, windowServerEvents: Bool = false) throws {
        self.pid = pid
        let ready = DispatchSemaphore(value: 0)
        var failure: AXError?
        let thread = Thread { [unowned self] in
            failure = self.setUp(pollInterval: pollInterval)
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if failure == nil { CFRunLoopRun() }
        }
        thread.name = "pane.WindowWatcher.\(pid)"
        thread.start()
        ready.wait()
        if let failure { throw AXFailure(code: failure) }
        if windowServerEvents { subscribeToWindowServer() }
    }

    private func subscribeToWindowServer() {
        let events = WindowServerEvents.shared
        events.start()
        events.watch(lock.withLock { Array(known.keys) })
        windowServerToken = events.addSubscriber { [weak self] kind, wid in
            guard let self, let runLoop = self.runLoop else { return }
            let relevant = kind == .created || self.lock.withLock { self.known[wid] != nil }
            guard relevant else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { self.reconcile(trigger: "ws:\(kind)", emit: true) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    deinit { stop() }

    public func stop() {
        if let token = windowServerToken { WindowServerEvents.shared.removeSubscriber(token) }
        windowServerToken = nil
        if let timer { CFRunLoopTimerInvalidate(timer) }
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    public var trackedCount: Int { lock.withLock { known.count } }
    public var records: [Record] { lock.withLock { log } }

    private func setUp(pollInterval: TimeInterval?) -> AXError? {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification as String)
        }
        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let observer else { return error }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        let app = AX.app(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.appNotifications {
            let error = AXObserverAddNotification(observer, app, notification as CFString, refcon)
            if error != .success && error != .notificationAlreadyRegistered { return error }
        }
        reconcile(trigger: "initial", emit: false)
        if let pollInterval {
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + pollInterval, pollInterval, 0, 0) { [weak self] _ in
                self?.reconcile(trigger: "poll", emit: true)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            self.timer = timer
        }
        return nil
    }

    private func subscribe(_ window: AXUIElement) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.windowNotifications {
            let error = AXObserverAddNotification(observer, window, notification as CFString, refcon)
            if error != .success && error != .notificationAlreadyRegistered { registrationFailures.append(error) }
        }
    }

    private func handle(_ element: AXUIElement, _ notification: String) {
        onNotification?(notification)
        reconcile(trigger: notification, emit: true)
    }

    /// Diff the live `kAXWindows` against what we knew, by CGWindowID.
    private func reconcile(trigger: String, emit: Bool) {
        var live: [CGWindowID: AXUIElement] = [:]
        for window in AX.windows(of: pid) {
            if let wid = PrivateAPI.windowID(of: window) { live[wid] = window }
        }
        let (opened, closed, count) = lock.withLock { () -> ([CGWindowID], [CGWindowID], Int) in
            let opened = live.keys.filter { known[$0] == nil }
            let closed = known.keys.filter { live[$0] == nil }
            known = live
            return (opened, closed, live.count)
        }
        for wid in opened { if let window = live[wid] { subscribe(window) } }
        if windowServerToken != nil && !opened.isEmpty { WindowServerEvents.shared.watch(opened) }
        guard emit else { return }
        let records = opened.map { Record(date: Date(), event: .opened($0), trigger: trigger) } +
            closed.map { Record(date: Date(), event: .closed($0), trigger: trigger) }
        lock.withLock { log.append(contentsOf: records) }
        for record in records { onEvent?(record, count) }
    }
}

public struct AXFailure: Error { public let code: AXError }

/// Everything the quit-on-last-window decision needs, captured fresh at decision time (debounce, then
/// verify — never trust the event stream alone).
public struct AppWindowSnapshot: Equatable {
    public var bundleID: String?
    /// AX windows with subrole AXStandardWindow (minimized ones included).
    public var standardWindows: Int
    /// Panels, palettes, dialogs: AX windows that are not standard.
    public var otherWindows: Int
    /// Owns a menu bar extra (its "tray icon").
    public var hasStatusItem: Bool
    /// Normal-layer WindowServer windows of this pid that AX doesn't report and that sit on a Space not
    /// currently shown — windows on other desktops, which kAXWindows omits and swiftquit therefore misses
    /// (it then quits apps that still have windows).
    public var unaccountedWindowServerWindows: Int
    /// Only `.regular` apps (Dock icon) follow the Windows lifecycle; agents/accessory apps never quit.
    public var isRegularApp: Bool
    /// Hidden with ⌘H: its windows are ordered out but it isn't windowless.
    public var isHidden: Bool

    public init(bundleID: String? = nil, standardWindows: Int = 0, otherWindows: Int = 0, hasStatusItem: Bool = false,
                unaccountedWindowServerWindows: Int = 0, isRegularApp: Bool = true, isHidden: Bool = false) {
        self.bundleID = bundleID
        self.standardWindows = standardWindows
        self.otherWindows = otherWindows
        self.hasStatusItem = hasStatusItem
        self.unaccountedWindowServerWindows = unaccountedWindowServerWindows
        self.isRegularApp = isRegularApp
        self.isHidden = isHidden
    }

    /// Measured on macOS 26: a minimized standard window reports subrole AXDialog, so "minimized" also
    /// counts (panels and real dialogs can't normally be minimized).
    public static func isStandard(_ window: AXUIElement) -> Bool {
        AX.subrole(window) == kAXStandardWindowSubrole || AX.isMinimized(window)
    }

    public static func capture(pid: pid_t) -> AppWindowSnapshot {
        let windows = AX.windows(of: pid)
        let standard = windows.filter(AppWindowSnapshot.isStandard)
        let axIDs = Set(windows.compactMap(PrivateAPI.windowID))
        // Apps keep pre-created windows alive off-screen with no Space, and a just-closed window keeps the
        // current Space until the app frees it. So only a window assigned to a Space that isn't on screen
        // right now (another desktop, a fullscreen Space we're not in) counts as hidden-but-open.
        let visible = PrivateAPI.visibleSpaces()
        let unaccounted = WindowServer.windows(onScreenOnly: false).filter { window in
            guard window.pid == pid, window.layer == 0, !axIDs.contains(window.id) else { return false }
            let spaces = PrivateAPI.spaces(of: window.id)
            return !spaces.isEmpty && spaces.allSatisfy { !visible.contains($0) }
        }
        let extras: AXUIElement? = AX.get(AX.app(pid), "AXExtrasMenuBar")
        let app = NSRunningApplication(processIdentifier: pid)
        return AppWindowSnapshot(
            bundleID: app?.bundleIdentifier,
            standardWindows: standard.count,
            otherWindows: windows.count - standard.count,
            hasStatusItem: extras != nil,
            unaccountedWindowServerWindows: unaccounted.count,
            isRegularApp: app?.activationPolicy == .regular,
            isHidden: app?.isHidden ?? false
        )
    }
}

/// Windows lifecycle rule: an app with no standard windows quits, unless it's a tray app or excluded.
public struct LifecyclePolicy {
    public enum Decision: Equatable {
        case keep(Reason)
        case quit
    }

    public enum Reason: Equatable {
        case hasWindows, excluded, trayApp, possiblyHiddenWindows, notARegularApp, appHidden
    }

    /// swiftquit's hard-coded list plus our own agent-ish system apps.
    public var excludedBundleIDs: Set<String> = ["com.apple.finder", "com.apple.Spotlight", "com.apple.notificationcenterui"]
    /// When true, WindowServer windows that AX can't see block the quit (safe default).
    public var trustWindowServerLeftovers = true

    public init() {}

    public func decide(_ snapshot: AppWindowSnapshot) -> Decision {
        if !snapshot.isRegularApp { return .keep(.notARegularApp) }
        if snapshot.isHidden { return .keep(.appHidden) }
        if let id = snapshot.bundleID, excludedBundleIDs.contains(id) { return .keep(.excluded) }
        if snapshot.standardWindows > 0 { return .keep(.hasWindows) }
        if snapshot.hasStatusItem { return .keep(.trayApp) }
        if trustWindowServerLeftovers && snapshot.unaccountedWindowServerWindows > 0 { return .keep(.possiblyHiddenWindows) }
        return .quit
    }
}

/// Decision 3: quit-on-last-window for every regular app, opt-out. Triggered only by a transition from
/// "has windows" to "none" in the inventory (never at startup, so apps already running windowless are left
/// alone), then debounced and re-verified with a fresh snapshot before a polite terminate.
public final class LifecycleService {
    public var policy = LifecyclePolicy()
    /// User opt-outs (bundle IDs). Added to the policy's built-in exclusions.
    public var optOut: Set<String> = [] { didSet { policy.excludedBundleIDs.formUnion(optOut) } }
    /// When non-nil, only these bundle IDs are ever quit (tests and dry runs use it to protect real apps).
    public var scope: Set<String>?
    public var debounce: TimeInterval = 1.5
    /// Reports every decision (for logs and tests).
    public var onDecision: ((pid_t, String?, LifecyclePolicy.Decision) -> Void)?

    private var counts: [pid_t: Int] = [:]
    private var pending: [pid_t: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "pane.LifecycleService")

    public init() {}

    /// Feed every inventory update (on any queue).
    public func inventoryChanged(_ windows: [ManagedWindow]) {
        let now = Dictionary(grouping: windows, by: \.pid).mapValues(\.count)
        queue.async { [self] in
            if Pause.isOn { counts = now; return } // paused: apps aren't quit
            for (pid, count) in counts where count > 0 && (now[pid] ?? 0) == 0 { schedule(pid) }
            for pid in now.keys { pending[pid]?.cancel(); pending[pid] = nil } // windows came back
            counts = now
        }
    }

    private func schedule(_ pid: pid_t) {
        pending[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate(pid) }
        pending[pid] = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func evaluate(_ pid: pid_t) {
        pending[pid] = nil
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if let scope, !scope.contains(app.bundleIdentifier ?? "") { return }
        let snapshot = AppWindowSnapshot.capture(pid: pid)
        let decision = policy.decide(snapshot)
        onDecision?(pid, app.bundleIdentifier, decision)
        if decision == .quit { app.terminate() }
    }
}
