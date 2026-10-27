// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Windows' "Show my taskbar on all displays" (setting `taskbar.allDisplays`): a bar on every other display besides the
/// main one. Those bars have Start, the app buttons, the clock and show desktop. The tray and the Dock's reservation
/// stay with the main bar. "When using multiple displays, show my taskbar apps on" (`taskbar.multiDisplayApps`) picks
/// which bar lists a window.
@MainActor
public final class TaskbarDisplays {
    public enum Apps: String, Sendable {
        /// Every bar lists every window (Windows' default); pinned apps on every bar.
        case all
        /// The main bar lists every window; another display's bar lists that display's windows.
        case mainAndOwn
        /// Each bar lists its own display's windows.
        case own
    }

    public let main: TaskbarPanel
    public private(set) var others: [CGDirectDisplayID: TaskbarPanel] = [:]
    public var enabled = false { didSet { if enabled != oldValue { refresh() } } }
    public var apps: Apps = .all { didSet { if apps != oldValue { applyFilters() } } }
    /// The bar whose Start button was clicked, while Start opens (nil: the main bar, or the Win key).
    public private(set) var startedFrom: TaskbarPanel?
    private let make: (CGDirectDisplayID) -> TaskbarPanel
    private let height: CGFloat
    private var lastWindows: [ManagedWindow] = []
    private var observer: NSObjectProtocol?

    /// `make` builds a bar for a display; `height` is what a fixed bar keeps free above it.
    public init(main: TaskbarPanel, height: CGFloat, make: @escaping (CGDirectDisplayID) -> TaskbarPanel) {
        self.main = main
        self.height = height
        self.make = make
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Every bar, the main one first.
    public var all: [TaskbarPanel] { [main] + others.keys.sorted().compactMap { others[$0] } }

    /// Displays came or went, or the setting changed: a bar for each other display, none for a display that's gone.
    public func refresh() {
        let wanted = enabled ? Set(NSScreen.screens.dropFirst().compactMap(\.displayID)) : []
        for (id, bar) in others where !wanted.contains(id) {
            bar.close()
            others[id] = nil
            TrayLog.write("taskbar: removed the bar on display \(id)")
        }
        for id in wanted.sorted() where others[id] == nil {
            let bar = make(id)
            bar.onStart = { [weak self, weak bar] in
                guard let self else { return }
                self.startedFrom = bar
                self.main.onStart?()
                self.startedFrom = nil
            }
            bar.onPinnedChanged = { [weak self] list in
                guard let self else { return }
                self.main.replacePinned(list)
                self.main.onPinnedChanged?(list)
                self.syncSettings()
            }
            others[id] = bar
            bar.copySettings(from: main)
            bar.show()
            TrayLog.write("taskbar: a bar on display \(id)")
        }
        applyFilters()
        updateReserves()
    }

    /// The main bar's settings changed: the other bars follow.
    public func syncSettings() {
        for bar in others.values { bar.copySettings(from: main) }
        updateReserves()
    }

    /// The window list (the main bar is updated by its owner).
    public func update(_ windows: [ManagedWindow]) {
        lastWindows = windows
        for bar in others.values { bar.update(windows) }
    }

    public func close() {
        for bar in others.values { bar.close() }
        others = [:]
        updateReserves()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The display a window is on (most of its frame), as its bar's display: nil for the main display.
    static func display(of window: ManagedWindow) -> CGDirectDisplayID? {
        guard let screen = Geometry.screen(containing: window.frame), screen != NSScreen.screens.first else { return nil }
        return screen.displayID
    }

    private func applyFilters() {
        let separate = apps != .all && !others.isEmpty
        main.displayFilter = separate && apps == .own ? { Self.display(of: $0) == nil } : nil
        for (id, bar) in others {
            bar.displayFilter = separate ? { Self.display(of: $0) == id } : nil
            bar.showsPinned = apps == .all
            bar.update(lastWindows)
        }
        main.update(main.lastWindowList)
    }

    /// Maximize and snaps stop above each fixed bar (macOS only reserves under the Dock, on the main display).
    private func updateReserves() {
        let fixed = !main.autoHide
        let frames = all.filter { fixed && $0.panel.isVisible || $0.isMain && fixed }.map { bar in
            (screen: Geometry.cocoaToAX(bar.screen.frame, primaryHeight: Geometry.primaryHeight), height: height)
        }
        Geometry.setTaskbarReserves(frames)
    }
}
