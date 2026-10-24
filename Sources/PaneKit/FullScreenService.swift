// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Windows-style full screen: the window fills the display on the CURRENT desktop (no separate Space), and the
/// taskbar gets out of the way while that window is focused — it comes back as soon as another window is
/// focused, like Windows.
///
/// Measured on macOS 26 (KNOWLEDGE.md §12):
/// - AppKit clamps every app's window below the menu bar and above the Dock (Edge, VS Code, Finder, fixture) —
///   so pane frees the bottom by switching the Dock to auto-hide live (`CoreDockSetAutoHideEnabled`, no
///   restart) while a full-screen window is focused;
/// - the menu bar can't be hidden from outside (the SkyLight call returns success and changes nothing): it
///   stays unless the user sets "Automatically hide and show the menu bar".
public final class FullScreenService {
    private typealias DockSetFn = @convention(c) (Bool) -> Void
    private typealias DockGetFn = @convention(c) () -> Bool
    private static let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let dockSet: DockSetFn? = dlsym(services, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: DockSetFn.self) }
    private static let dockGet: DockGetFn? = dlsym(services, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: DockGetFn.self) }

    /// Called on the main queue: true while a full-screen window is focused (hide the taskbar).
    public var onTaskbarSuppressed: ((Bool) -> Void)?

    private struct Entry { let element: AXUIElement; let restore: CGRect }
    private var entries: [CGWindowID: Entry] = [:]
    private var dockWasAutoHidden: Bool?
    private var suppressed = false
    private var lastFocused: CGWindowID?
    private let lock = NSLock()

    public init() {}

    public func isFullScreen(_ wid: CGWindowID) -> Bool { lock.withLock { entries[wid] != nil } }

    /// Enter or leave pane full screen for `window`.
    public func toggle(_ window: AXUIElement) {
        guard let wid = PrivateAPI.windowID(of: window) else { return }
        if let entry = lock.withLock({ entries.removeValue(forKey: wid) }) {
            setSuppressed(false)
            AX.setFrame(window, entry.restore)
        } else {
            guard let frame = AX.frame(window) else { return }
            if AX.get(window, "AXFullScreen") == true { // a native full-screen window comes back to the desktop first
                AX.set(window, "AXFullScreen", kCFBooleanFalse)
                Thread.sleep(forTimeInterval: 1.0)
            }
            lock.withLock { entries[wid] = Entry(element: window, restore: AX.frame(window) ?? frame) }
            setSuppressed(true)
            Self.waitForDockToHide()
            fill(window)
        }
    }

    /// The focused window changed (feed from the inventory): suppress the taskbar only while a full-screen
    /// window has focus, and re-fill it (the screen's free area changes with the Dock).
    public func focusChanged(to wid: CGWindowID?) {
        // Act on focus CHANGES only: re-filling on every inventory update pulled a full-screen window back out of
        // virtual-desktop parking (found by the soak run).
        guard lock.withLock({ () -> Bool in
            defer { lastFocused = wid }
            return wid != lastFocused
        }) else { return }
        let entry = wid.flatMap { id in lock.withLock { entries[id] } }
        setSuppressed(entry != nil)
        if let entry {
            Self.waitForDockToHide()
            fill(entry.element)
        }
    }

    /// Forget windows that closed.
    public func prune(alive: Set<CGWindowID>) {
        lock.withLock { entries = entries.filter { alive.contains($0.key) } }
        if lock.withLock({ entries.isEmpty }) { setSuppressed(false) }
    }

    /// Restores the Dock and leaves every window where it is (pane quitting).
    public func shutdown() { setSuppressed(false) }

    /// Apps clamp windows to the free area at the moment they're resized, so wait until the Dock is out.
    static func waitForDockToHide(timeout: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(timeout)
        while DockReservation.bottomInset() > 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func fill(_ window: AXUIElement) {
        // The free area once the Dock auto-hides: the whole screen minus the menu bar.
        guard let frame = AX.frame(window), let screen = Geometry.screen(containing: frame) else { return }
        let full = Geometry.cocoaToAX(screen.frame, primaryHeight: Geometry.primaryHeight)
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        AX.setFrame(window, CGRect(x: full.minX, y: full.minY + menuBar, width: full.width, height: full.height - menuBar))
    }

    private func setSuppressed(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard suppressed != value else { return false }
            suppressed = value
            return true
        }
        guard changed else { return }
        if value {
            dockWasAutoHidden = Self.dockGet?() ?? false
            if dockWasAutoHidden == false { Self.dockSet?(true) }
        } else if dockWasAutoHidden == false {
            Self.dockSet?(false)
            dockWasAutoHidden = nil
        }
        DispatchQueue.main.async { [weak self] in self?.onTaskbarSuppressed?(value) }
    }
}
