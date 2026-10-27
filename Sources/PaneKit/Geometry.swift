// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Conversions between Cocoa coordinates (origin bottom-left of the primary screen, y up) and AX/Quartz
/// coordinates (origin top-left of the primary screen, y down). The primary screen is `NSScreen.screens[0]`.
public enum Geometry {
    public static func cocoaToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func axToCocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        // The flip is its own inverse.
        cocoaToAX(rect, primaryHeight: primaryHeight)
    }

    public static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The screen holding most of `axFrame`.
    public static func screen(containing axFrame: CGRect) -> NSScreen? {
        let height = primaryHeight
        return NSScreen.screens.max { a, b in
            area(cocoaToAX(a.frame, primaryHeight: height).intersection(axFrame)) <
                area(cocoaToAX(b.frame, primaryHeight: height).intersection(axFrame))
        }
    }

    /// What pane's taskbars keep free at the bottom of screens (each screen's AX frame and the bar's height). macOS
    /// reserves space only under the Dock, on one display; the work area takes the larger. Set on the main thread by
    /// the agent, read from the event taps too.
    public static func setTaskbarReserves(_ reserves: [(screen: CGRect, height: CGFloat)]) { reserveLock.withLock { self.reserves = reserves } }
    static func taskbarReserve(_ screen: CGRect) -> CGFloat {
        reserveLock.withLock { reserves.first { $0.screen == screen }?.height ?? 0 }
    }
    private static let reserveLock = NSLock()
    nonisolated(unsafe) private static var reserves: [(screen: CGRect, height: CGFloat)] = []

    /// The Windows "work area" of a screen: minus the menu bar, the Dock and pane's taskbar there, in AX coordinates.
    public static func workArea(of screen: NSScreen) -> CGRect {
        var visible = screen.visibleFrame
        let extra = taskbarReserve(cocoaToAX(screen.frame, primaryHeight: primaryHeight)) - (visible.minY - screen.frame.minY)
        if extra > 0 { visible.origin.y += extra; visible.size.height -= extra }
        return cocoaToAX(visible, primaryHeight: primaryHeight)
    }

    /// The work area of the screen holding most of `axFrame`.
    public static func workArea(for axFrame: CGRect) -> CGRect? {
        screen(containing: axFrame).map(workArea(of:))
    }

    /// Screens' frames in AX coordinates, the primary first.
    public static var screenFramesAX: [CGRect] {
        let height = primaryHeight
        return NSScreen.screens.map { cocoaToAX($0.frame, primaryHeight: height) }
    }

    /// Gaps between snapped windows (`SnapService.gap`): every edge moves in by half the gap, and edges on the
    /// work area's border by a whole gap, so neighbours end up `gap` apart and `gap` from the screen's edges.
    public static func gapped(_ rect: CGRect, in work: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return rect }
        func edge(_ onBorder: Bool) -> CGFloat { onBorder ? gap : gap / 2 }
        let left = edge(abs(rect.minX - work.minX) < 1), right = edge(abs(rect.maxX - work.maxX) < 1)
        let top = edge(abs(rect.minY - work.minY) < 1), bottom = edge(abs(rect.maxY - work.maxY) < 1)
        return CGRect(x: rect.minX + left, y: rect.minY + top, width: rect.width - left - right, height: rect.height - top - bottom)
    }

    /// Windows-style snap targets inside a work area.
    public enum Snap: String, CaseIterable, Codable, Sendable {
        case maximize, leftHalf, rightHalf, topLeft, topRight, bottomLeft, bottomRight
        // Snap Layouts (Windows 11): thirds and two-thirds.
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    }

    public static func rect(for snap: Snap, in work: CGRect) -> CGRect {
        let halfW = (work.width / 2).rounded(.down)
        let halfH = (work.height / 2).rounded(.down)
        switch snap {
        case .maximize: return work
        case .leftHalf: return CGRect(x: work.minX, y: work.minY, width: halfW, height: work.height)
        case .rightHalf: return CGRect(x: work.minX + halfW, y: work.minY, width: work.width - halfW, height: work.height)
        case .topLeft: return CGRect(x: work.minX, y: work.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: work.minX + halfW, y: work.minY, width: work.width - halfW, height: halfH)
        case .bottomLeft: return CGRect(x: work.minX, y: work.minY + halfH, width: halfW, height: work.height - halfH)
        case .bottomRight: return CGRect(x: work.minX + halfW, y: work.minY + halfH, width: work.width - halfW, height: work.height - halfH)
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            let third = (work.width / 3).rounded(.down)
            let x1 = work.minX + third, x2 = work.minX + 2 * third
            switch snap {
            case .leftThird: return CGRect(x: work.minX, y: work.minY, width: third, height: work.height)
            case .centerThird: return CGRect(x: x1, y: work.minY, width: third, height: work.height)
            case .rightThird: return CGRect(x: x2, y: work.minY, width: work.maxX - x2, height: work.height)
            case .leftTwoThirds: return CGRect(x: work.minX, y: work.minY, width: x2 - work.minX, height: work.height)
            default: return CGRect(x: x1, y: work.minY, width: work.maxX - x1, height: work.height)
            }
        }
    }

    /// `frame` moved from work area `from` to `to`: the same size (shrunk to fit) and the same share of the free space
    /// left of and above it.
    public static func translated(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, to.width), height: min(frame.height, to.height))
        func place(_ offset: CGFloat, _ room: CGFloat, _ newRoom: CGFloat) -> CGFloat {
            room > 0 ? (offset / room * newRoom).rounded() : (newRoom / 2).rounded()
        }
        let x = to.minX + max(0, min(to.width - size.width, place(frame.minX - from.minX, from.width - frame.width, to.width - size.width)))
        let y = to.minY + max(0, min(to.height - size.height, place(frame.minY - from.minY, from.height - frame.height, to.height - size.height)))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

extension NSScreen {
    /// The screen's display (`NSScreenNumber`).
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
