// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// M3: Windows Alt+Tab per window (⌥ = Alt), driven with synthesized keys.
    @Suite("M3 · Switcher")
    struct SwitcherTests {
        static func altTabWindowsOnScreen() -> Int {
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.lwouis.alt-tab-macos").map(\.processIdentifier)
            return WindowServer.windows().filter { pids.contains($0.pid) && $0.bounds.width > 100 }.count
        }

        @Test func altTabCyclesMRUAndCommitsOnRelease() async throws {
            let f = try await Fixture.launch(label: "W", windows: ["A", "B", "C"])
            defer { f.quit() }
            let inventory = WindowInventory()
            let history = FocusHistory()
            var seenFocus: [String] = []
            for name in ["A", "B", "C"] {
                Focus.focus(try f.requireWindow(name), using: .skyLight)
                _ = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W \(name)" }
                let list = inventory.refreshNow()
                seenFocus.append(list.first(where: \.isFocused)?.title ?? "none")
                history.update(list)
            }
            _ = inventory.refreshNow()
            await MainActor.run { inventory.scheduleRefresh() }
            _ = await eventually { inventory.windows.contains { $0.title == "W C" } }

            let switcher = SwitcherController(inventory: inventory, history: history)
            let lock = NSLock()
            var shown: [String] = []
            var selections: [Int] = []
            switcher.onShow = { items, start in lock.withLock { if shown.isEmpty { shown = items.prefix(3).map(\.title) }; selections.append(start) } }
            switcher.onSelect = { index in lock.withLock { selections.append(index) } }
            var committed: [String] = []
            switcher.onHide = { window in lock.withLock { committed.append(window?.title ?? "cancel") } }
            try switcher.start()
            defer { switcher.stop(); SyntheticKeyboard.releaseAllModifiers() }

            // Hold ⌥, Tab, Tab, release → A (third in MRU: C, B, A).
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            await settle(0.3)
            let altTabInterfered = Self.altTabWindowsOnScreen()
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            let toA = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W A" }

            // ⌥Tab once → back to the previous window (C), like Windows.
            await settle(0.3)
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            let toC = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W C" }

            // ⌥Tab, Esc → nothing changes.
            await settle(0.3)
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            pressEscape(flags: .maskAlternate)
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            await settle(0.5)
            let stayedC = AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W C"

            Report.record("M3 Switcher", "MRU shown=\(lock.withLock { shown }) selections=\(lock.withLock { selections }); ⌥Tab×2→A=\(toA), ⌥Tab→previous(C)=\(toC), Esc cancels=\(stayedC); committed=\(lock.withLock { committed }); focus seen by inventory=\(seenFocus); AltTab windows on screen during hold=\(altTabInterfered)")
            #expect(lock.withLock { shown } == ["W C", "W B", "W A"])
            #expect(toA)
            #expect(toC)
            #expect(stayedC)
            #expect(!switcher.isActive)
        }

        /// A window in macOS full screen is listed by Alt+Tab (Windows lists full-screen apps), and choosing it goes there.
        @Test func altTabListsFullScreenWindows() async throws {
            let f = try await Fixture.launch(label: "Q", windows: ["Desk", "Full"], frame: CGRect(x: 120, y: 160, width: 420, height: 300))
            defer { f.quit() }
            let desk = try f.requireWindow("Desk"), full = try f.requireWindow("Full")
            AX.set(full, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 6) { PrivateAPI.activeSpace()?.kind == .fullscreen })
            await settle(1.2)
            Focus.focus(desk, using: .skyLight)
            _ = await eventually(timeout: 6) { PrivateAPI.activeSpace()?.kind == .desktop }
            await settle(0.8)
            defer {
                if PrivateAPI.activeSpace()?.kind == .fullscreen || AX.get(full, "AXFullScreen") == true { AX.set(full, "AXFullScreen", kCFBooleanFalse) }
            }
            let inventory = WindowInventory()
            let history = FocusHistory()
            _ = inventory.refreshNow()
            history.update(inventory.windows)
            let switcher = SwitcherController(inventory: inventory, history: history)
            let lock = NSLock()
            var listed: [String] = []
            switcher.onShow = { items, _ in lock.withLock { listed = items.map(\.title) } }
            try switcher.start()
            defer { switcher.stop(); SyntheticKeyboard.releaseAllModifiers() }
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            await settle(0.3)
            let titles = lock.withLock { listed }
            // Pick the full-screen window: step until it's selected, then release.
            if let index = titles.firstIndex(of: "Q Full") {
                for _ in 0..<((index - 1 + titles.count) % titles.count) { SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate) }
            }
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            let went = await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen }
            await settle(1.0)
            Report.record("M3 Switcher · full screen", "listed \(titles.filter { $0.hasPrefix("Q ") }); chose the full-screen window → its Space \(went)")
            #expect(titles.contains("Q Full"))
            #expect(went)
            AX.set(full, "AXFullScreen", kCFBooleanFalse)
            _ = await eventually(timeout: 6) { AX.get(full, "AXFullScreen") != true && PrivateAPI.activeSpace()?.kind == .desktop }
        }
    }
}
