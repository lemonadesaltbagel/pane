// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    @Suite("Harness · ChoicePanel clicks")
    struct ChoicePanelTests {
        @Test func everyClickActsIncludingTheFirst() async throws {
            final class Box: @unchecked Sendable { var fired: [String] = [] }
            let box = Box()
            let lock = NSLock()
            var results: [Bool] = []
            for round in 0..<3 {
                await MainActor.run {
                    ChoicePanel.shared.show([("Header", nil), ("One \(round)", { lock.withLock { box.fired.append("one\(round)") } }),
                                             ("Two \(round)", { lock.withLock { box.fired.append("two\(round)") } })],
                                            atAX: CGPoint(x: 300, y: 300))
                }
                await settle(0.2)
                let point = try #require(await MainActor.run { Harness.center(of: "Two \(round)", in: ChoicePanelAccess.window) })
                SyntheticMouse.click(at: point)
                results.append(await eventually(timeout: 1) { lock.withLock { box.fired.contains("two\(round)") } })
            }
            Report.record("Harness · ChoicePanel", "clicks acted: \(results) fired=\(lock.withLock { box.fired })")
            #expect(results == [true, true, true])
        }
    }
}
