// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Windows-style full screen = the window covers the whole display on the current desktop. Can another app's
    /// window be put over the menu-bar strip (normal menu bar vs auto-hidden)?
    @Suite("Experiments · Windows full screen")
    struct WindowsFullScreenExperimentTests {
        @Test func coverTheWholeScreen() async throws {
            TestSystemSettings.recoverIfNeeded()
            let f = try await Fixture.launch(label: "Z", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            let screen = Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight)

            AX.setFrame(window, screen)
            await settle(0.5)
            let normal = AX.frame(window) ?? .zero

            let settings = SystemSettings(backupURL: TestSystemSettings.url)
            settings.restartHandler = { _ in
                DistributedNotificationCenter.default().postNotificationName(.init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            try settings.apply([.init(SystemSettings.globalDomain, "_HIHideMenuBar", .bool(true))])
            defer { settings.restore() }
            await settle(1.5)
            AX.setFrame(window, screen)
            await settle(0.5)
            let hidden = AX.frame(window) ?? .zero
            let visible = NSScreen.screens[0].visibleFrame
            Report.record("Windows full screen · cover", "screen \(screen); menu bar shown → window \(normal); menu bar auto-hidden → window \(hidden) (visibleFrame top inset now \(NSScreen.screens[0].frame.maxY - visible.maxY))")
        }
    }
}
