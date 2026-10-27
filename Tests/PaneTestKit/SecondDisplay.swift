// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit
import PaneVirtualDisplay
import Testing

/// A second display for a test: a virtual one (this Mac has a single screen), arranged right of the main display.
/// It's removed when the body ends, even when the body throws, and macOS brings any window left on it back.
public enum SecondDisplay {
    /// Your windows (not fixtures', not pane's): id → frame, to check none moved.
    static func yourWindows() -> [CGWindowID: CGRect] {
        let own = Set(NSRunningApplication.runningApplications(withBundleIdentifier: FixtureBundle.bundleID).map(\.processIdentifier))
        return Dictionary(WindowServer.windows().filter { $0.layer == 0 && $0.isOnScreen && !own.contains($0.pid) && $0.pid != getpid() && !($0.ownerName ?? "").hasPrefix("pane") }
            .map { ($0.id, $0.bounds) }, uniquingKeysWith: { a, _ in a })
    }

    /// The second display's frame in AX coordinates (top-left origin), while it exists.
    @MainActor public static var frame: CGRect? {
        NSScreen.screens.dropFirst().first.map { Geometry.cocoaToAX($0.frame, primaryHeight: Geometry.primaryHeight) }
    }

    /// A display kept across steps (the soak plugs and unplugs it). Gone when removed or released.
    public final class Handle {
        let display: PaneVirtualDisplay
        init(_ display: PaneVirtualDisplay) { self.display = display }
        public var displayID: CGDirectDisplayID { display.displayID }
        public func remove() { display.remove() }
    }

    /// Adds a display and waits until AppKit sees it.
    @MainActor public static func add(width: UInt32 = 1920, height: UInt32 = 1080) async -> Handle? {
        let screens = NSScreen.screens.count
        guard let display = PaneVirtualDisplay(width: width, height: height, hiDPI: false, name: "pane test display") else { return nil }
        _ = await eventually(timeout: 5) { NSScreen.screens.count > screens }
        await settle(1)
        return Handle(display)
    }

    /// Adds a `width` × `height` display, runs `body` with its frame (AX coordinates), removes it.
    @MainActor public static func with<T>(width: UInt32 = 1920, height: UInt32 = 1080, _ body: (CGRect) async throws -> T) async throws -> T {
        let before = yourWindows()
        let screens = NSScreen.screens.count
        let display = try #require(PaneVirtualDisplay(width: width, height: height, hiDPI: false, name: "pane test display"), "no virtual display")
        defer {
            display.remove()
            let moved = yourWindows().filter { id, frame in before[id].map { !Geometry.approximatelyEqual($0, frame, tolerance: 2) } ?? false }
            if !moved.isEmpty { Issue.record("your windows moved while the second display was up: \(moved.keys.sorted())") }
        }
        _ = await eventually(timeout: 5) { NSScreen.screens.count > screens }
        let frame = try #require(Self.frame, "the second display didn't appear")
        await settle(1) // the menu bar and Space settle on it
        let result = try await body(frame)
        display.remove()
        _ = await eventually(timeout: 5) { NSScreen.screens.count == screens }
        await settle(1)
        return result
    }
}
