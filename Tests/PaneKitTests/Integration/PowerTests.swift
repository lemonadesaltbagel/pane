// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Restart, shut down and log out without a permission prompt: when macOS hasn't allowed pane's Apple event to
    /// loginwindow, pane presses the Apple menu's "now" item over Accessibility. Nothing here restarts anything: the
    /// items are only found, and the pressing is proved on a harmless one (About This Mac), closed again.
    @Suite("Power through the Apple menu")
    struct PowerTests {
        @Test func appleMenuItemsAreFoundAndPressable() async throws {
            let f = try await Fixture.launch(label: "P", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 400, height: 260))
            defer { f.quit() }
            _ = await eventually { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }
            let found = [PowerAction.restart, .shutDown, .logOut].map { Power.appleMenuItem($0) != nil }
            let before = Set(WindowServer.windows().filter(\.isOnScreen).map(\.id))
            let about = try #require(Power.appleMenuItem(identifier: "_aboutThisMacRequested:"), "no About This Mac item")
            let pressed = AX.perform(about, kAXPressAction) == .success
            var window: WindowServerWindow?
            _ = await eventually(timeout: 5) {
                window = WindowServer.windows().first { !before.contains($0.id) && $0.isOnScreen && $0.layer == 0 && $0.pid != f.pid }
                return window != nil
            }
            // Close it again (its close button; never Escape).
            if let window, let ax = AX.windows(of: window.pid).first(where: { AX.frame($0).map { Geometry.approximatelyEqual($0, window.bounds, tolerance: 4) } ?? false }),
               let close = AX.button(ax, kAXCloseButtonAttribute) {
                AX.perform(close, kAXPressAction)
            }
            let closed = await eventually(timeout: 3) { window.map { w in !WindowServer.windows().contains { $0.id == w.id && $0.isOnScreen } } ?? false }
            let note = "restart, shut down, log out items found \(found); About This Mac pressed \(pressed) → a window from \(window?.ownerName ?? "-") \(window != nil), closed again \(closed)"
            Report.record("Power · the Apple menu", note)
            print("POWER-MENU: " + note)
            #expect(found.allSatisfy { $0 } && pressed && window != nil && closed)
        }
    }
}
