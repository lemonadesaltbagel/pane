// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import ApplicationServices
import CoreGraphics

/// Emulated Windows window state. macOS has no "maximized" flag, so — like Rectangle's `WindowHistory` —
/// a window counts as maximized/snapped only while its frame still equals the frame we gave it, and the
/// restore frame is the last frame the *user* chose.
public struct PlacementStore: Codable {
    public enum State: Equatable {
        case normal
        case snapped(Geometry.Snap)
    }

    private struct Entry: Codable {
        var restore: CGRect
        var applied: CGRect?
        var snap: Geometry.Snap?
    }

    private var entries: [CGWindowID: Entry] = [:]
    public var tolerance: CGFloat = 2

    /// Windows that still exist keep their entries (a pane restart: window IDs live as long as their windows).
    public mutating func keep(only alive: Set<CGWindowID>) { entries = entries.filter { alive.contains($0.key) } }
    public var count: Int { entries.count }

    public init() {}

    public func state(of wid: CGWindowID, currentFrame: CGRect) -> State {
        guard let entry = entries[wid], let applied = entry.applied, let snap = entry.snap,
              Geometry.approximatelyEqual(applied, currentFrame, tolerance: tolerance) else { return .normal }
        return .snapped(snap)
    }

    /// Returns the frame to apply. Only a frame that isn't one we placed becomes the restore frame, so
    /// maximize → left half → restore returns to the original free-floating frame (Rectangle `WindowManager.swift:129-143`).
    public mutating func snap(_ wid: CGWindowID, currentFrame: CGRect, to snap: Geometry.Snap, workArea: CGRect) -> CGRect {
        let target = Geometry.rect(for: snap, in: workArea)
        if case .normal = state(of: wid, currentFrame: currentFrame) {
            entries[wid] = Entry(restore: currentFrame, applied: target, snap: snap)
        } else {
            entries[wid]?.applied = target
            entries[wid]?.snap = snap
        }
        return target
    }

    /// Frame to restore to, or nil if the window isn't in a placed state (the user moved it since).
    public mutating func restore(_ wid: CGWindowID, currentFrame: CGRect) -> CGRect? {
        guard case .snapped = state(of: wid, currentFrame: currentFrame), let entry = entries[wid] else { return nil }
        entries[wid] = Entry(restore: entry.restore, applied: nil, snap: nil)
        return entry.restore
    }

    /// Windows title-bar double-click / Win+Up-then-Win+Down semantics.
    public mutating func toggleMaximize(_ wid: CGWindowID, currentFrame: CGRect, workArea: CGRect) -> CGRect {
        if state(of: wid, currentFrame: currentFrame) == .snapped(.maximize), let frame = restore(wid, currentFrame: currentFrame) {
            return frame
        }
        return snap(wid, currentFrame: currentFrame, to: .maximize, workArea: workArea)
    }

    public mutating func forget(_ wid: CGWindowID) { entries[wid] = nil }

    /// Where pane last snapped the window, whatever its frame is now (nil: not snapped, or restored since).
    public func placed(_ wid: CGWindowID) -> (frame: CGRect, snap: Geometry.Snap)? {
        guard let entry = entries[wid], let applied = entry.applied, let snap = entry.snap else { return nil }
        return (applied, snap)
    }

    /// The window went to another display: its restore frame goes along, at the same place relative to the work area
    /// (shrunk to fit), so restoring keeps it there (Windows).
    public mutating func moveRestore(_ wid: CGWindowID, from: CGRect, to: CGRect) {
        guard let restore = entries[wid]?.restore else { return }
        entries[wid]?.restore = Geometry.translated(restore, from: from, to: to)
    }

    /// The frame actually applied (gaps between snapped windows): state detection compares against it.
    public mutating func setApplied(_ wid: CGWindowID, _ frame: CGRect) { entries[wid]?.applied = frame }
}

/// The work area shrank under existing windows (pane started and reserved the taskbar's space): like Windows, move
/// each window back inside it — up so it ends above the bar, and shorter if it's taller than the work area. Windows
/// in macOS full screen, minimized ones and those on other Spaces are left alone.
public enum WorkAreaAdoption {
    /// The frame a window should have inside `work` (AX coordinates), or nil when it already fits.
    public static func fitted(_ frame: CGRect, in work: CGRect) -> CGRect? {
        guard frame.maxY > work.maxY + 1, frame.intersects(work) else { return nil }
        var fitted = frame
        fitted.size.height = min(frame.height, work.height)
        fitted.origin.y = max(work.minY, work.maxY - fitted.height)
        return fitted
    }

    /// Applies `fitted` to every window on the visible Space. Returns how many moved.
    @discardableResult
    public static func adopt(_ windows: [ManagedWindow], element: (CGWindowID) -> AXUIElement?) -> Int {
        var moved = 0
        for window in windows where window.isOnVisibleSpace && !window.isMinimized {
            guard let ax = element(window.id), AX.get(ax, "AXFullScreen") != true, let frame = AX.frame(ax),
                  let work = Geometry.workArea(for: frame), let target = fitted(frame, in: work) else { continue }
            AX.setFrame(ax, target)
            moved += 1
        }
        return moved
    }
}
