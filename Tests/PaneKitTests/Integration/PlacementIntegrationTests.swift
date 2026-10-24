// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 4: maximize as a real (emulated) state, snapping, restore.
    @Suite("4 · Maximize and snap")
    struct PlacementIntegrationTests {
        @Test func maximizeFillsTheWorkAreaAndRestoreReturnsExactly() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try #require(f.window("A")), wid = try #require(f.wid("A"))
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))
            var store = PlacementStore()

            let target = store.toggleMaximize(wid, currentFrame: original, workArea: work)
            AX.setFrame(window, target)
            let maximized = await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
            let actual = AX.frame(window) ?? .zero
            Report.record("4 Placement · maximize", "work=\(work) actual=\(actual) ok=\(maximized)")
            #expect(maximized)
            #expect(store.state(of: wid, currentFrame: actual) == .snapped(.maximize))

            AX.setFrame(window, store.toggleMaximize(wid, currentFrame: actual, workArea: work))
            #expect(await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, original) } ?? false })
        }

        @Test("Snap targets", arguments: [Geometry.Snap.leftHalf, .rightHalf, .topLeft, .bottomRight])
        func snap(to snap: Geometry.Snap) async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try #require(f.window("A")), wid = try #require(f.wid("A"))
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))
            var store = PlacementStore()

            let target = store.snap(wid, currentFrame: original, to: snap, workArea: work)
            AX.setFrame(window, target)
            #expect(await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, target) } ?? false },
                    "wanted \(target), got \(AX.frame(window) ?? .zero)")
            let restore = store.restore(wid, currentFrame: AX.frame(window) ?? .zero)
            #expect(restore == original)
        }

        /// How long an AX frame write takes to land, which bounds how responsive drag-snapping can feel.
        @Test func frameWriteLatency() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try #require(f.window("A"))
            let original = try #require(AX.frame(window))
            var samples: [Double] = []
            for step in 1...5 {
                let target = original.offsetBy(dx: CGFloat(step * 20), dy: 0)
                let start = Date()
                AX.setFrame(window, target)
                if await eventually(poll: 0.005, { AX.frame(window).map { Geometry.approximatelyEqual($0, target) } ?? false }) {
                    samples.append(Date().timeIntervalSince(start) * 1000)
                }
            }
            Report.record("4 Placement · AX setFrame latency (ms)", samples.map { String(format: "%.1f", $0) }.joined(separator: ", "))
            #expect(samples.count == 5)
        }
    }
}
