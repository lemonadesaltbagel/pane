// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Can a fixture come to the front while a system alert (UserNotificationCenter) is showing?
    @Suite("Experiments · front with a system alert up")
    struct FrontWithAlertExperimentTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func frontWithAlert() async throws {
            let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            let f = try await Fixture.launch(label: "Q", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 400, height: 300))
            defer { f.quit() }
            let afterLaunch = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            let fronted = await eventually(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }
            let ax = AX.frontmostPID() == f.pid
            Report.record("Front with a system alert up", "before \(before); after launch \(afterLaunch); SkyLight focus → frontmost fixture \(fronted), AX frontmost fixture \(ax)")
        }
    }
}
