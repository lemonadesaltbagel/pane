// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

// MARK: - Space reservation

/// Makes "maximize" respect a bottom taskbar without private API: a small real Dock (autohide off, no
/// magnification, bottom) reserves exactly the bar's height in every screen's `visibleFrame`, so every app's
/// own zoom/Fill and pane's snapping stop above the bar. The taskbar panel is drawn over the Dock.
///
/// Measured on macOS 26 (KNOWLEDGE.md): reserved height = tile size + 20 pt for small tiles (16→36, 24→44,
/// 32→52), so `apply` starts from that and corrects by re-measuring.
public final class DockReservation {
    public let settings: SystemSettings

    public init(settings: SystemSettings = SystemSettings()) {
        self.settings = settings
    }

    /// Bottom inset of the primary screen. NSScreen geometry is refreshed on the main thread (when AppKit
    /// handles the screen-parameters change), so off-main callers read it there.
    public static func bottomInset() -> CGFloat {
        let read = { () -> CGFloat in
            guard let screen = NSScreen.screens.first else { return 0 }
            return screen.visibleFrame.minY - screen.frame.minY
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    /// Reserves `height` points at the bottom; returns the inset actually achieved (the bar should use it).
    @discardableResult
    public func apply(height: CGFloat, timeout: TimeInterval = 4) throws -> CGFloat {
        var tile = max(16, min(128, Int(height) - 20))
        for _ in 0..<3 {
            let before = Self.bottomInset()
            if before == height { return before }
            try settings.apply([
                .init("com.apple.dock", "tilesize", .int(tile)),
                .init("com.apple.dock", "autohide", .bool(false)),
                .init("com.apple.dock", "magnification", .bool(false)),
                .init("com.apple.dock", "orientation", .string("bottom")),
            ])
            // The Dock restarts asynchronously: wait for the inset to move off its old value and settle.
            let inset = Self.waitForInset(changingFrom: before, timeout: timeout)
            let error = Int(height - inset)
            if error == 0 || tile == 16 || tile == 128 { return inset }
            tile = max(16, min(128, tile + error))
        }
        return Self.bottomInset()
    }

    public func restore(timeout: TimeInterval = 4) {
        let before = Self.bottomInset()
        settings.restore()
        _ = Self.waitForInset(changingFrom: before, timeout: timeout)
    }

    /// The Dock restarts asynchronously; poll until the inset settles.
    public static func waitForInset(changingFrom old: CGFloat?, timeout: TimeInterval) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var last = bottomInset(), stableSince = Date()
        while Date() < deadline {
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } else { Thread.sleep(forTimeInterval: 0.1) }
            let now = bottomInset()
            if now != last { last = now; stableSince = Date() }
            let changed = old.map { now != $0 } ?? true
            if changed && Date().timeIntervalSince(stableSince) > 0.6 { break }
        }
        return last
    }
}

// MARK: - Model

/// One taskbar button: a window, or a pinned app that has no windows.
public struct TaskbarItem: Equatable, Identifiable {
    public enum Kind: Equatable {
        case window(CGWindowID)
        case pinnedApp
    }

    public let id: String
    public let kind: Kind
    public let bundleID: String?
    public let pid: pid_t?
    public let title: String
    public let isActive: Bool
    public let isMinimized: Bool
    public let isOnVisibleSpace: Bool
    public let isPinned: Bool
}

public enum TaskbarLayout {
    /// Windows-style order: pinned apps first in pinned order (each replaced by its windows when it has any),
    /// then other apps' windows, grouped by app in order of the app's first window. Windows keep seat order.
    public static func items(windows: [ManagedWindow], pinned: [String]) -> [TaskbarItem] {
        let byApp = Dictionary(grouping: windows) { $0.bundleID ?? "pid:\($0.pid)" }
        var items: [TaskbarItem] = []
        var placed = Set<String>()
        for bundleID in pinned {
            placed.insert(bundleID)
            if let group = byApp[bundleID], !group.isEmpty {
                items += group.sorted { $0.seat < $1.seat }.map { item(for: $0, pinned: true) }
            } else {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
                items.append(TaskbarItem(id: "pin:\(bundleID)", kind: .pinnedApp, bundleID: bundleID, pid: nil, title: name,
                                         isActive: false, isMinimized: false, isOnVisibleSpace: true, isPinned: true))
            }
        }
        let rest = byApp.filter { !placed.contains($0.key) }.values
            .sorted { ($0.map(\.seat).min() ?? 0) < ($1.map(\.seat).min() ?? 0) }
        for group in rest {
            items += group.sorted { $0.seat < $1.seat }.map { item(for: $0, pinned: false) }
        }
        return items
    }

    static func item(for window: ManagedWindow, pinned: Bool) -> TaskbarItem {
        TaskbarItem(id: "win:\(window.id)", kind: .window(window.id), bundleID: window.bundleID, pid: window.pid, title: window.title,
                    isActive: window.isFocused, isMinimized: window.isMinimized, isOnVisibleSpace: window.isOnVisibleSpace, isPinned: pinned)
    }
}

// MARK: - Actions

/// macOS 26's "Apps" (Launchpad's successor, pinned in the Dock by default) is a background-only launcher: opening
/// Apps.app through LaunchServices returns no app and shows nothing (measured). Its grid is a Spotlight panel the
/// Dock opens on a `com.apple.launchpad.toggle` notification — sending it toggles the panel open and closed
/// (measured: 844×577 Spotlight window, layer 23).
public enum AppsPanel {
    public static let bundleID = "com.apple.apps.launcher"
    private typealias SendFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private static let send: SendFn? = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
                                             "CoreDockSendNotification").map { unsafeBitCast($0, to: SendFn.self) }

    @discardableResult
    public static func toggle() -> Bool {
        guard let send else { return false }
        send("com.apple.launchpad.toggle" as CFString, nil)
        return true
    }

    /// Toggle; when opening, check it showed and toggle again if not (up to twice): right after the menu bar
    /// re-lays out, the first toggles have been seen to be dropped (measured).
    @discardableResult
    public static func toggleVerified() async -> Bool {
        let opening = !isShown
        guard toggle() else { return false }
        guard opening else { return true }
        for _ in 0..<2 {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if isShown { return true }
            toggle()
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if isShown { return true }
        // Still nothing: Spotlight's panel controller is wedged. Seen intermittently after repeated Dock restarts
        // (the test suite starts and stops many agents); only restarting Spotlight cures it (it relaunches at once).
        restartSpotlight()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        toggle()
        for _ in 0..<20 where !isShown { try? await Task.sleep(nanoseconds: 100_000_000) }
        return isShown
    }

    /// Diagnostics: times Spotlight was restarted to recover the Apps panel.
    nonisolated(unsafe) public private(set) static var spotlightRestarts = 0

    static func restartSpotlight() {
        spotlightRestarts += 1
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight") { app.forceTerminate() }
    }

    /// The panel is showing (Spotlight's large layer-23 window).
    public static var isShown: Bool {
        WindowServer.windows().contains { $0.ownerName == "Spotlight" && $0.layer == 23 && $0.bounds.height > 300 }
    }
}

public enum TaskbarActions {
    public enum Outcome: Equatable { case focused, minimized, launched, newWindow, newInstance, closed, failed }

    /// Windows click semantics: the active window's button minimizes it; any other window comes forward alone.
    @discardableResult
    public static func click(_ window: ManagedWindow, inventory: WindowInventory) -> Outcome {
        let element = inventory.element(for: window.id)
        if window.isFocused, !window.isMinimized, let element {
            return AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue) == .success ? .minimized : .failed
        }
        if let element, window.isOnVisibleSpace || window.isMinimized {
            return Focus.focusBest(element) ? .focused : .failed
        }
        // Another Space / a fullscreen Space: needs a real AX element (focusing by id alone doesn't switch Spaces).
        return Focus.focusAnywhere(wid: window.id, pid: window.pid, element: element) ? .focused : .failed
    }

    /// Middle-click: a new window in the running app (the faithful macOS mapping), else a new instance.
    @discardableResult
    public static func middleClick(bundleID: String, pid: pid_t?) async -> Outcome {
        if let pid {
            for path in [["File", "New Window"], ["Shell", "New Window"], ["File", "New"]] where Launcher.pressNewWindow(pid: pid, path: path) {
                return .newWindow
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              (try? await Launcher.open(url, newInstance: pid != nil, activate: true)) != nil else { return .failed }
        return pid != nil ? .newInstance : .launched
    }

    @discardableResult
    public static func launch(bundleID: String) async -> Outcome {
        if bundleID == AppsPanel.bundleID { return await AppsPanel.toggleVerified() ? .launched : .failed }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              (try? await Launcher.open(url, newInstance: false, activate: true)) != nil else { return .failed }
        return .launched
    }

    @discardableResult
    public static func close(_ window: ManagedWindow, inventory: WindowInventory) -> Outcome {
        guard let element = inventory.element(for: window.id), let button = AX.button(element, kAXCloseButtonAttribute) else { return .failed }
        return AX.perform(button, kAXPressAction) == .success ? .closed : .failed
    }
}
