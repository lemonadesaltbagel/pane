// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// One user-facing window, as the taskbar / switcher see it.
public struct ManagedWindow: Equatable, Identifiable {
    public let id: CGWindowID
    public let pid: pid_t
    public var title: String
    public var appName: String
    public var bundleID: String?
    public var frame: CGRect
    public var isMinimized: Bool
    /// On a Space that's shown right now (false: another desktop or a fullscreen Space we're not in).
    public var isOnVisibleSpace: Bool
    public var isFocused: Bool
    /// Order of first sighting — stable across refreshes, so taskbar buttons don't jump around.
    public var seat: Int

    public init(id: CGWindowID, pid: pid_t, title: String, appName: String, bundleID: String?, frame: CGRect,
                isMinimized: Bool, isOnVisibleSpace: Bool, isFocused: Bool, seat: Int) {
        self.id = id
        self.pid = pid
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.frame = frame
        self.isMinimized = isMinimized
        self.isOnVisibleSpace = isOnVisibleSpace
        self.isFocused = isFocused
        self.seat = seat
    }
}

/// The live list of user windows, WindowServer-first (KNOWLEDGE.md §2): CGWindowList + Space membership is the
/// source of truth, AX adds titles/subroles/minimized for windows it can reach. Windows on Spaces that aren't
/// shown are invisible to `kAXWindows`, so they come from the WindowServer, with titles remembered from the
/// last time AX could see them.
///
/// Refreshes are coalesced and run on a background queue; AX reads run concurrently per app with a short
/// messaging timeout so one hung app can't stall the list. `onChange` is delivered on the main queue.
public final class WindowInventory {
    public private(set) var windows: [ManagedWindow] = []
    public var onChange: (([ManagedWindow]) -> Void)?

    private let queue = DispatchQueue(label: "pane.WindowInventory")
    private var seats: [CGWindowID: Int] = [:]
    private var nextSeat = 0
    private var titleCache: [CGWindowID: String] = [:]
    /// Windows the remote-token sweep already failed on (don't retry every refresh).
    private var lookupFailed: Set<CGWindowID> = []
    private var elementCache: [CGWindowID: AXUIElement] = [:]
    private let cacheLock = NSLock()
    private var refreshScheduled = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var eventToken: UUID?
    /// Pids never listed (pane itself, plus anything a caller excludes).
    public var excludedPIDs: Set<pid_t> = [getpid()]

    public init() {}

    deinit { stop() }

    /// Starts listening: NSWorkspace app events, SkyLight window events (needs NSApp running), and a poll.
    public func start(pollInterval: TimeInterval = 1.0) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.scheduleRefresh() })
        }
        let events = WindowServerEvents.shared
        events.start()
        eventToken = events.addSubscriber { [weak self] kind, _ in
            if kind != .moved && kind != .resized { self?.scheduleRefresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.scheduleRefresh(full: false) }
        scheduleRefresh()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        if let eventToken { WindowServerEvents.shared.removeSubscriber(eventToken) }
        eventToken = nil
    }

    /// The AX element for a window, if AX has ever seen it (cached elements keep working across Spaces).
    public func element(for wid: CGWindowID) -> AXUIElement? {
        cacheLock.withLock { elementCache[wid] }
    }

    /// `full: false` (the safety-net poll) skips the Accessibility pass when the WindowServer looks unchanged
    /// since the last full refresh, except every `titleInterval` (titles change without WindowServer events).
    /// Measured idle cost before this: ~1.8% of a core, almost all in the per-second AX pass.
    public func scheduleRefresh(full: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            if full { self.pendingFull = true }
            guard !self.refreshScheduled else { return }
            self.refreshScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                self.refreshScheduled = false
                let full = self.pendingFull
                self.pendingFull = false
                if !full, Date().timeIntervalSince(self.lastFullRefresh) < self.titleInterval, self.fingerprint() == self.lastFingerprint {
                    self.skippedPolls += 1
                    return
                }
                self.refresh()
            }
        }
    }

    private var pendingFull = false
    private var lastFingerprint: Int?
    private var lastFullRefresh = Date.distantPast
    /// Longest time between full refreshes while nothing else changes (title updates).
    public var titleInterval: TimeInterval = 3
    /// Diagnostics: polls answered by the fingerprint alone.
    public private(set) var skippedPolls = 0

    /// What the WindowServer shows (normal windows in z-order, their frames and on-screen state), plus the
    /// frontmost app and the shown Spaces.
    private func fingerprint() -> Int {
        var hasher = Hasher()
        // On-screen windows only: describing every off-screen window was itself most of the idle cost. Minimize,
        // hide and Space switches all change the on-screen list; other-Space changes arrive as SkyLight events.
        for window in WindowServer.windows(onScreenOnly: true) where window.layer == 0 {
            hasher.combine(window.id)
            hasher.combine(window.bounds.origin.x); hasher.combine(window.bounds.origin.y)
            hasher.combine(window.bounds.width); hasher.combine(window.bounds.height)
        }
        hasher.combine(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        hasher.combine(PrivateAPI.visibleSpaces())
        return hasher.finalize()
    }

    /// Synchronous refresh (tests). Returns the new list.
    @discardableResult
    public func refreshNow() -> [ManagedWindow] {
        queue.sync { refresh() }
        return queue.sync { currentSnapshot }
    }

    private var currentSnapshot: [ManagedWindow] = []
    /// When a listed window first went missing from AX (minimize animations and Space transitions blink windows
    /// out of kAXWindows for a refresh; dropping them made the taskbar rebuild under the pointer).
    private var missingSince: [CGWindowID: Date] = [:]
    public var disappearanceGrace: TimeInterval = 0.5

    private struct AXWindowInfo {
        let wid: CGWindowID
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
        let frame: CGRect
    }

    private func refresh() {
        lastFingerprint = fingerprint()
        lastFullRefresh = Date()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !excludedPIDs.contains($0.processIdentifier) }
        let visible = PrivateAPI.visibleSpaces()
        let server = WindowServer.windows(onScreenOnly: false).filter { $0.layer == 0 }
        let serverByPID = Dictionary(grouping: server, by: \.pid)

        // AX per app, concurrently; each app element carries a short messaging timeout.
        var axByPID = [pid_t: [AXWindowInfo]]()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let pid = apps[index].processIdentifier
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            let elements: [AXUIElement] = AX.get(app, kAXWindowsAttribute) ?? []
            let infos = elements.compactMap { element -> AXWindowInfo? in
                guard AppWindowSnapshot.isStandard(element), let wid = PrivateAPI.windowID(of: element) else { return nil }
                return AXWindowInfo(wid: wid, element: element, title: AX.title(element) ?? "", isMinimized: AX.isMinimized(element),
                                    frame: AX.frame(element) ?? .zero)
            }
            lock.withLock { axByPID[pid] = infos }
        }

        let frontPID = AX.frontmostPID()
        let focusedWID = frontPID.flatMap { AX.focusedWindow(of: $0) }.flatMap(PrivateAPI.windowID)
        var result: [ManagedWindow] = []
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "?"
            var seen = Set<CGWindowID>()
            for info in axByPID[pid] ?? [] {
                seen.insert(info.wid)
                cacheLock.withLock {
                    elementCache[info.wid] = info.element
                    if !info.title.isEmpty { titleCache[info.wid] = info.title }
                }
                let spaces = PrivateAPI.spaces(of: info.wid)
                result.append(ManagedWindow(id: info.wid, pid: pid, title: info.title.isEmpty ? name : info.title, appName: name,
                                            bundleID: app.bundleIdentifier, frame: info.frame, isMinimized: info.isMinimized,
                                            isOnVisibleSpace: spaces.isEmpty || spaces.contains(where: visible.contains),
                                            isFocused: info.wid == focusedWID, seat: seats[info.wid] ?? Int.max))
            }
            // Windows AX can't see: on a Space that isn't shown. Keep the substantial ones (fullscreen apps also
            // own toolbar/backdrop windows on their Space; drop anything under 40% of the largest per Space).
            let hidden = (serverByPID[pid] ?? []).filter { !seen.contains($0.id) && $0.bounds.width >= 200 && $0.bounds.height >= 150 }
                .map { ($0, PrivateAPI.spaces(of: $0.id)) }
                .filter { !$0.1.isEmpty && !$0.1.contains(where: visible.contains) }
            let largestPerSpace = Dictionary(grouping: hidden, by: { $0.1.first ?? 0 }).mapValues { $0.map { $0.0.bounds.width * $0.0.bounds.height }.max() ?? 0 }
            for (window, spaces) in hidden where window.bounds.width * window.bounds.height >= 0.4 * (largestPerSpace[spaces.first ?? 0] ?? 0) {
                // Never seen through AX (e.g. already on a fullscreen Space when pane started): find its element once
                // with the remote-token sweep — gives the real title and a handle that can switch Spaces.
                if cacheLock.withLock({ elementCache[window.id] == nil }) && !lookupFailed.contains(window.id) {
                    if let element = PrivateAPI.windowElement(pid: pid, wid: window.id, budget: 0.15) {
                        cacheLock.withLock {
                            elementCache[window.id] = element
                            if let title = AX.title(element), !title.isEmpty { titleCache[window.id] = title }
                        }
                    } else {
                        lookupFailed.insert(window.id)
                    }
                }
                let title = cacheLock.withLock { titleCache[window.id] } ?? name
                result.append(ManagedWindow(id: window.id, pid: pid, title: title, appName: name, bundleID: app.bundleIdentifier,
                                            frame: window.bounds, isMinimized: false, isOnVisibleSpace: false, isFocused: false,
                                            seat: seats[window.id] ?? Int.max))
            }
        }
        // Grace: a window that vanished from this refresh but still exists in the WindowServer stays listed for
        // `disappearanceGrace` (closed windows drop out of CGWindowList or lose their Space shortly after).
        let listed = Set(result.map(\.id))
        let serverIDs = Set(server.map(\.id))
        let now = Date()
        for previous in currentSnapshot where !listed.contains(previous.id) {
            let since = missingSince[previous.id] ?? now
            if serverIDs.contains(previous.id), now.timeIntervalSince(since) < disappearanceGrace,
               apps.contains(where: { $0.processIdentifier == previous.pid }) {
                missingSince[previous.id] = since
                result.append(previous)
            } else {
                missingSince[previous.id] = nil
            }
        }
        for wid in listed { missingSince[wid] = nil }
        if !missingSince.isEmpty { scheduleRefresh() } // re-check once the grace ends

        // Windows first seen in this refresh get seats in creation order (window IDs increase with creation),
        // not in AX's front-to-back order — so a running app's windows line up A, B, C like on Windows.
        let fresh = result.filter { seats[$0.id] == nil }.map(\.id).sorted()
        for wid in fresh { _ = seat(for: wid) }
        result = result.map { var window = $0; window.seat = seats[$0.id] ?? window.seat; return window }
        result.sort { $0.seat < $1.seat }

        // Forget windows that are gone.
        let alive = Set(result.map(\.id))
        seats = seats.filter { alive.contains($0.key) }
        cacheLock.withLock {
            elementCache = elementCache.filter { alive.contains($0.key) }
            titleCache = titleCache.filter { alive.contains($0.key) }
        }

        // Opt every listed window into SkyLight notifications (nothing is delivered for unwatched windows).
        WindowServerEvents.shared.watch(Array(alive))

        guard result != currentSnapshot else { return }
        currentSnapshot = result
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windows = result
            self.onChange?(result)
        }
    }

    private func seat(for wid: CGWindowID) -> Int {
        if let seat = seats[wid] { return seat }
        nextSeat += 1
        seats[wid] = nextSeat
        return nextSeat
    }
}
