// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Windows "Show desktop" (the sliver at the taskbar's right end, Win+D): the first use minimizes every window on this
/// desktop; the second brings back exactly those, and focus returns to the window that had it. If you open or focus a
/// window in between, the next use starts over (Windows does the same).
public final class ShowDesktop {
    private let lock = NSLock()
    private var hidden: [(element: AXUIElement, wid: CGWindowID)] = []
    private var focusedBefore: AXUIElement?
    private var toggledAt = Date.distantPast
    public private(set) var isShowingDesktop = false

    public init() {}

    /// `windows`: this desktop's windows (already filtered to the current desktop / Space).
    public func toggle(windows: [ManagedWindow], element: (CGWindowID) -> AXUIElement?) {
        let restore = lock.withLock { () -> [(element: AXUIElement, wid: CGWindowID)]? in
            guard isShowingDesktop else { return nil }
            isShowingDesktop = false
            defer { hidden = [] }
            return hidden
        }
        if let restore {
            // Still minimized ones come back (others were restored by hand meanwhile).
            for item in restore.reversed() where AX.get(item.element, kAXMinimizedAttribute) == true {
                AX.set(item.element, kAXMinimizedAttribute, kCFBooleanFalse)
            }
            if let focused = lock.withLock({ focusedBefore }) { _ = Focus.focusBest(focused) }
            return
        }
        let focused = AX.frontmostPID().flatMap { AX.focusedWindow(of: $0) }
        var toHide: [(element: AXUIElement, wid: CGWindowID)] = []
        for window in windows where !window.isMinimized && window.isOnVisibleSpace {
            guard let ax = element(window.id), AX.get(ax, "AXFullScreen") != true else { continue }
            toHide.append((ax, window.id))
        }
        guard !toHide.isEmpty else { return }
        for item in toHide { AX.set(item.element, kAXMinimizedAttribute, kCFBooleanTrue) }
        lock.withLock {
            hidden = toHide
            focusedBefore = focused
            isShowingDesktop = true
            toggledAt = Date()
        }
    }

    /// A window was focused or opened by the user meanwhile: the next toggle minimizes again instead of restoring.
    /// (Ignored for a moment after showing the desktop: the window list still reports the old focus then.)
    public func reset() {
        lock.withLock {
            guard Date().timeIntervalSince(toggledAt) > 1.5 else { return }
            isShowingDesktop = false
            hidden = []
        }
    }
}
