// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
import PaneKit
import PaneTestKit

/// Previews via the PanePreview helper (it holds the Screen Recording grant the terminal can't get).
/// Images are saved to test-results/previews/ so they can be checked by eye.

extension IntegrationTests {
    @Suite("Previews (helper)", .enabled(if: PreviewGate.enabled, "Install and allow PanePreview: scripts/install-preview-helper.sh"))
    struct PreviewTests {
        @Test func visibleMinimizedAndOtherSpaceWindows() async throws {
            let f = try await Fixture.launch(label: "Preview", windows: ["Visible", "Minimized"])
            defer { f.quit() }
            let visible = try #require(f.wid("Visible")), minimized = try #require(f.wid("Minimized"))

            let start = Date()
            let (a, sourceA) = try #require(await PreviewClient.thumbnail(visible, maxDimension: 320))
            let latency = Date().timeIntervalSince(start) * 1000
            let urlA = PreviewGate.save(a, "visible")

            AX.set(try f.requireWindow("Minimized"), kAXMinimizedAttribute, kCFBooleanTrue)
            _ = await eventually { !WindowServer.zOrder().contains(minimized) }
            await settle(0.8)
            let b = await PreviewClient.thumbnail(minimized, maxDimension: 320)
            let urlB = b.map { PreviewGate.save($0.0, "minimized") }

            Report.record("Previews", "visible \(a.width)x\(a.height) via \(sourceA.rawValue) in \(String(format: "%.0f", latency)) ms, variety=\(PreviewGate.colorVariety(a)) → \(urlA.lastPathComponent); minimized \(b.map { "\($0.0.width)x\($0.0.height) via \($0.1.rawValue), variety=\(PreviewGate.colorVariety($0.0))" } ?? "nil") → \(urlB?.lastPathComponent ?? "-")")
            #expect(max(a.width, a.height) <= 640)
            #expect(PreviewGate.colorVariety(a) > 3, "visible preview looks blank")
            #expect(b != nil)
        }
    }
}
