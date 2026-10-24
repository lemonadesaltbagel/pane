// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// Bug report: clicking the taskbar button of an app that is in macOS native full screen (its own Space) did
    /// nothing. The click must switch to that window.
    @Suite("Full screen · taskbar")
    struct FullscreenTaskbarTests {
        @Test func clickingAFullscreenAppsButtonSwitchesToIt() async throws {
            FixtureBundle.killStrays()
            let desk = try await Fixture.launch(label: "Desk", windows: ["D"], frame: CGRect(x: 900, y: 500, width: 300, height: 200))
            defer { desk.quit() }
            let deskElement = try desk.requireWindow("D") // cached while visible: needed to come back later
            let full = try await Fixture.launch(label: "Full", windows: ["F"])
            defer { full.quit() }
            let fullWindow = try full.requireWindow("F")
            let fullWID = try #require(full.wid("F"))
            AX.set(fullWindow, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen })
            await settle(1.0)
            // Back to the desktop.
            Focus.focusBest(deskElement)
            try #require(await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop })
            await settle(0.8)

            // A fresh pane (its inventory never saw the full-screen window through AX on the desktop Space).
            let inventory = WindowInventory()
            let bar = await MainActor.run { TaskbarPanel(inventory: inventory, height: 48, mode: .never) }
            await MainActor.run {
                bar.includedPIDs = [full.pid]
                inventory.onChange = { windows in MainActor.assumeIsolated { bar.update(windows) } }
                inventory.start()
                bar.show()
            }
            defer { Task { @MainActor in bar.close(); inventory.stop() } }
            let listed = await eventually(timeout: 4) { MainActor.assumeIsolatedOrSync { bar.presentation.buttons.contains { $0.id == "win:\(fullWID)" } } }
            let entry = inventory.windows.first { $0.id == fullWID }
            let title = entry?.title ?? "?"
            let point = await MainActor.run { Harness.center(of: title, in: bar.panel) }
            if let point { SyntheticMouse.click(at: point) }
            let switched = await eventually(timeout: 3) { PrivateAPI.activeSpace()?.kind == .fullscreen && AX.frontmostPID() == full.pid }
            Report.record("Full screen · taskbar click", "listed=\(listed) as '\(title)' (AX element cached=\(inventory.element(for: fullWID) != nil), onVisibleSpace=\(entry?.isOnVisibleSpace ?? false)); button found=\(point != nil); switched to its Space=\(switched)")
            AX.set(fullWindow, "AXFullScreen", kCFBooleanFalse)
            _ = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop }
            #expect(listed)
            #expect(title == "Full F", "the window's real title, found through the remote-token sweep")
            #expect(switched)
        }
    }
}
