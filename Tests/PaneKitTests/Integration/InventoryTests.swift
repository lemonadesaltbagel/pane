// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// M0 exit criterion: the WindowServer-first inventory matches reality while fixture windows open, close,
    /// minimize, tab and move to another Space.
    @Suite("M0 · Window inventory")
    struct InventoryTests {
        static func mine(_ inventory: WindowInventory, _ f: Fixture) -> [ManagedWindow] {
            inventory.refreshNow().filter { $0.pid == f.pid }
        }

        @Test func tracksOpenCloseMinimizeWithStableSeats() async throws {
            let f = try await Fixture.launch(label: "I", windows: ["A", "B", "C"])
            defer { f.quit() }
            let inventory = WindowInventory()
            let initial = Self.mine(inventory, f)
            #expect(Set(initial.map(\.title)) == ["I A", "I B", "I C"])
            let seats = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.seat) })

            try f.close("B")
            #expect(await eventually { !Self.mine(inventory, f).contains { $0.title == "I B" } })
            AX.set(try f.requireWindow("A"), kAXMinimizedAttribute, kCFBooleanTrue)
            #expect(await eventually { Self.mine(inventory, f).first { $0.title == "I A" }?.isMinimized == true })

            let after = Self.mine(inventory, f)
            #expect(after.count == 2)
            for window in after { #expect(window.seat == seats[window.id], "seat changed for \(window.title)") }
        }

        @Test func nativeTabsAreOneEntry() async throws {
            let f = try await Fixture.launch(label: "T", windows: ["A", "B", "C"], tabs: true, requireVisibleInAX: false)
            defer { f.quit() }
            _ = await f.waitUntilVisibleInAX([])
            await settle(0.5)
            let entries = Self.mine(WindowInventory(), f)
            Report.record("M0 Inventory · native tabs", "3 tabs → \(entries.count) entry: \(entries.map(\.title))")
            #expect(entries.count == 1)
        }

        @Test func windowsOnAnotherSpaceStayListedWithTheirTitles() async throws {
            let f = try await Fixture.launch(label: "S", windows: ["A", "B"])
            defer { f.quit() }
            let inventory = WindowInventory()
            _ = Self.mine(inventory, f) // sighting while visible caches titles

            let x = try await Fixture.launch(label: "X", windows: ["Full"])
            defer { x.quit() }
            let full = try x.requireWindow("Full")
            AX.set(full, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen })
            await settle(1.0)

            let entries = Self.mine(inventory, f)
            Report.record("M0 Inventory · other Space", "from a fullscreen Space: AX sees \(AX.windows(of: f.pid).count) F windows; inventory lists \(entries.map { "\($0.title)(visible=\($0.isOnVisibleSpace))" })")
            #expect(Set(entries.map(\.title)) == ["S A", "S B"])
            #expect(entries.allSatisfy { !$0.isOnVisibleSpace })
            #expect(inventory.element(for: try #require(entries.first?.id)) != nil, "cached AX element should survive the Space change")
            AX.set(full, "AXFullScreen", kCFBooleanFalse)
            _ = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop }
            await settle(0.8)
        }

        @Test func pushesChangesQuickly() async throws {
            let f = try await Fixture.launch(label: "P", windows: ["A", "B"])
            defer { f.quit() }
            let inventory = WindowInventory()
            let lock = NSLock()
            var latest: [ManagedWindow] = []
            inventory.onChange = { list in lock.withLock { latest = list } }
            await MainActor.run { inventory.start(pollInterval: 5) } // long poll: measure the event path
            defer { inventory.stop() }
            #expect(await eventually(timeout: 3) { lock.withLock { latest.contains { $0.title == "P B" } } })

            try f.close("B")
            let closeLatency = await timeUntil(timeout: 3) { lock.withLock { !latest.contains { $0.title == "P B" } } }
            Launcher.pressNewWindow(pid: f.pid)
            let openLatency = await timeUntil(timeout: 3) { lock.withLock { latest.contains { $0.title == "P New 1" } } }
            Report.record("M0 Inventory · push latency", "close \(closeLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "missed"), open \(openLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "missed")")
            #expect((closeLatency ?? 9) < 1)
            #expect((openLatency ?? 9) < 1)
        }
    }
}
