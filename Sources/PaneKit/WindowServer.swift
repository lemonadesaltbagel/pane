// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import CoreGraphics

/// One entry of `CGWindowListCopyWindowInfo`. Bounds are in AX/Quartz coordinates (top-left origin).
public struct WindowServerWindow: Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    public let bounds: CGRect
    public let isOnScreen: Bool
    /// `kCGWindowName` is only filled in when we hold Screen Recording permission (macOS 10.15+).
    public let name: String?
    public let ownerName: String?
}

public enum WindowServer {
    /// Windows front-to-back. `onScreenOnly` drops minimized/hidden/other-Space windows; occluded windows
    /// are still included, which is what makes this usable as a z-order oracle.
    public static func windows(onScreenOnly: Bool = true) -> [WindowServerWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            var bounds = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
            }
            return WindowServerWindow(
                id: id,
                pid: pid,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                name: info[kCGWindowName as String] as? String,
                ownerName: info[kCGWindowOwnerName as String] as? String
            )
        }
    }

    /// Front-to-back IDs of normal (layer 0) on-screen windows.
    /// Which of these windows still exist (on any Space, minimized or not). An inventory update can miss a window
    /// during a Space switch; this asks the Window Server directly.
    public static func existing(_ ids: Set<CGWindowID>) -> Set<CGWindowID> {
        guard !ids.isEmpty else { return [] }
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } })
    }

    public static func zOrder() -> [CGWindowID] {
        windows().filter { $0.layer == 0 }.map(\.id)
    }

    /// True when `a` is in front of `b` in the current on-screen order.
    public static func isAbove(_ a: CGWindowID, _ b: CGWindowID, in order: [CGWindowID] = zOrder()) -> Bool? {
        guard let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: b) else { return nil }
        return ia < ib
    }
}
