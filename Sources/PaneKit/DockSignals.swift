// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// What the real Dock shows on each app's tile, so pane's taskbar can show it the Windows 11 way: the badge (unread
/// count), the progress bar, and the attention request (Windows: the button turns orange until you switch to the app).
///
/// The Dock keeps running under pane's bar (it reserves the bar's space) and exposes, per tile (measured,
/// DockSignalsExperimentTests): `AXStatusLabel` = the badge text, `AXProgressValue` = progress, and an attention request
/// as the tile bouncing (its y moves up from rest). Tiles are read about 4 times a second off the main thread.
public final class DockSignals {
    public struct Signal: Equatable, Sendable {
        public var badge: String?
        public var progress: Double?
        public var attention: Bool
        public init(badge: String? = nil, progress: Double? = nil, attention: Bool = false) {
            self.badge = badge; self.progress = progress; self.attention = attention
        }
        public var isEmpty: Bool { badge == nil && progress == nil && !attention }
    }

    /// Called on the main thread with every app's signal (bundle ID → signal; apps with nothing to show are left out).
    public var onChange: (([String: Signal]) -> Void)?
    private let queue = DispatchQueue(label: "pane.dock-signals")
    private var timer: DispatchSourceTimer?
    private var last: [String: Signal] = [:]
    private var restY: [String: CGFloat] = [:]
    private var attention: Set<String> = []
    private var bundleForURL: [URL: String] = [:]
    private var activationObserver: NSObjectProtocol?

    /// Badges read before pane restarted the Dock (a restarted Dock forgets every app's badge until the app sets it
    /// again — measured). Shown until the app's badge changes, you switch to the app, or it quits.
    private var carried: [String: String] = [:]

    public init() {}

    /// Every app's badge in the Dock right now (call before the Dock restarts) — bundle ID → text.
    public static func currentBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        var badges: [String: String] = [:]
        for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for tile in (AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let badge: String = AX.get(tile, "AXStatusLabel"), !badge.isEmpty,
                      let url: URL = AX.get(tile, kAXURLAttribute as String), let id = Bundle(url: url)?.bundleIdentifier else { continue }
                badges[id] = badge
            }
        }
        return badges
    }

    /// Badges to carry over a Dock restart (`currentBadges()` read before it).
    public func carryOver(_ badges: [String: String]) { queue.async { self.carried = badges } }

    /// 0.4 s: an attention bounce keeps the tile raised for ~0.5 s (measured), so it's still caught; idle CPU was half
    /// pane's at 0.25 s with one AX call per attribute.
    public func start(interval: TimeInterval = 0.4) {
        guard timer == nil else { return }
        // Windows clears the orange button when you switch to the app.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.queue.async { self?.attention.remove(id); self?.carried[id] = nil; self?.poll() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// The Dock's app tiles and their bundle IDs, re-read every 2 s (not every poll: one AX call per list and tile).
    private var tiles: [(AXUIElement, String)] = []
    private var tilesReadAt = Date.distantPast
    private var dockPID: pid_t = 0

    private func appTiles(_ dock: NSRunningApplication) -> [(AXUIElement, String)] {
        if dock.processIdentifier == dockPID, Date().timeIntervalSince(tilesReadAt) < 2 { return tiles }
        dockPID = dock.processIdentifier
        tilesReadAt = Date()
        tiles = []
        for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for tile in (AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard (AX.get(tile, kAXSubroleAttribute) as String?) == "AXApplicationDockItem", let id = bundleID(of: tile) else { continue }
                tiles.append((tile, id))
            }
        }
        return tiles
    }

    private func poll() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var signals: [String: Signal] = [:]
        let names = ["AXStatusLabel", "AXProgressValue", kAXPositionAttribute] as CFArray
        for (tile, id) in appTiles(dock) {
            // One AX call for the three values.
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(tile, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 3 else { continue }
            var signal = signals[id] ?? Signal()
            if let badge = list[0] as? String, !badge.isEmpty { signal.badge = badge }
            if let progress = list[1] as? NSNumber { signal.progress = progress.doubleValue }
            // Bouncing: the tile rises above its resting place. Remember the lowest (resting) y per app.
            if CFGetTypeID(list[2]) == AXValueGetTypeID() {
                var point = CGPoint.zero
                AXValueGetValue(list[2] as! AXValue, .cgPoint, &point)
                let rest = max(restY[id] ?? point.y, point.y)
                restY[id] = rest
                if point.y < rest - 3, id != frontmost { attention.insert(id) }
            }
            signals[id] = signal
        }
        for id in attention { signals[id, default: Signal()].attention = true }
        // Carried-over badges: until the Dock shows one of its own for the app, or the app is gone.
        for (id, badge) in carried {
            if signals[id]?.badge != nil || NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { carried[id] = nil; continue }
            signals[id, default: Signal()].badge = badge
        }
        let shown = signals.filter { !$0.value.isEmpty }
        guard shown != last else { return }
        last = shown
        DispatchQueue.main.async { [weak self] in self?.onChange?(shown) }
    }

    private func bundleID(of tile: AXUIElement) -> String? {
        guard let url: URL = AX.get(tile, kAXURLAttribute as String) else { return nil }
        if let cached = bundleForURL[url] { return cached }
        let id = Bundle(url: url)?.bundleIdentifier
        if let id { bundleForURL[url] = id }
        return id
    }
}
