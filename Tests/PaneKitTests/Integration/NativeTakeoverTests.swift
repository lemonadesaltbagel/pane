// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Decision 4: switch off macOS edge tiling. Does the WindowManager pick the preference up live, or does
    /// it need a restart? Restores the user's values afterwards.
    @Suite("M1 · Native tiling takeover")
    struct NativeTakeoverTests {
        @Test func disablingEdgeTilingStopsNativeSnap() async throws {
            TestSystemSettings.recoverIfNeeded()
            let settings = SystemSettings(backupURL: TestSystemSettings.url)
            var restarted: [String] = []
            settings.restartHandler = { restarted.append($0) }
            defer { settings.restartHandler = { _ in }; settings.restore() }

            let f = try await Fixture.launch(label: "N", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))
            let left = Geometry.rect(for: .leftHalf, in: work)

            try settings.apply([
                .init("com.apple.WindowManager", "EnableTilingByEdgeDrag", .bool(false)),
                .init("com.apple.WindowManager", "EnableTopTilingByEdgeDrag", .bool(false)),
            ])
            await settle(0.5)
            SyntheticMouse.drag(from: try MouseTests.titleBarPoint(window), to: CGPoint(x: work.minX, y: work.midY), hold: 0.8)
            await settle(1.2)
            let after = try #require(AX.frame(window))
            let tiled = Geometry.approximatelyEqual(after, left, tolerance: 12)
            Report.record("M1 Takeover · edge tiling pref off (live, no restart)", "drag to left edge → \(after); natively tiled=\(tiled)")
            #expect(!tiled, "WindowManager still tiles: the preference needs a restart of WindowManager")
        }
    }
}
