// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Windows: right-click a taskbar app → "Pin to taskbar"; the button stays after the app quits; "Unpin from taskbar"
    /// removes it. Saved in the agent's config (a test copy: your config.json must not change).
    @Suite("Taskbar · pin from the right-click menu")
    struct TaskbarPinTests {
        static func choice(_ pid: pid_t, _ title: String) -> CGPoint? {
            guard let menu = AX.windows(of: pid).first(where: { AX.title($0) == "Pane Choices" }) else { return nil }
            func find(_ e: AXUIElement) -> CGPoint? {
                if AX.title(e) == title, let f = AX.frame(e) { return CGPoint(x: f.midX, y: f.midY) }
                for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let p = find(c) { return p } }
                return nil
            }
            return find(menu)
        }

        static func pinnedInConfig() -> [String] {
            guard let data = try? Data(contentsOf: Harness.testConfig),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return ((root["settings"] as? [String: Any])?["taskbar.pinned"] as? [String]) ?? []
        }

        @Test func pinAndUnpinFromTheMenu() async throws {
            let yours = try? Data(contentsOf: SettingsStore.defaultURL)
            var f: Fixture? = try await Fixture.launch(label: "P", windows: ["A"], frame: CGRect(x: 160, y: 200, width: 400, height: 280))
            defer { f?.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            func buttons() -> [(String, CGPoint)] { Harness.taskbarButtons(pane.processIdentifier) }
            let running = try #require(await eventually(timeout: 4) { buttons().contains { $0.0.hasPrefix("group: PaneFixture") } } ? buttons().first { $0.0.hasPrefix("group: PaneFixture") } : nil)

            // Pin.
            SyntheticMouse.rightClick(at: running.1)
            let pinItem = await eventually(timeout: 3) { Self.choice(pane.processIdentifier, "Pin to taskbar") != nil } ? Self.choice(pane.processIdentifier, "Pin to taskbar") : nil
            if let pinItem { SyntheticMouse.click(at: pinItem) }
            let saved = await eventually(timeout: 3) { Self.pinnedInConfig().contains(FixtureBundle.bundleID) }

            // The app quits: its pinned button stays.
            f?.quit(); f = nil
            let stays = await eventually(timeout: 6) { buttons().contains { ["pin: PaneFixture", "pin: dev.pane.fixture"].contains($0.0) } }
            if !stays { print("BUTTONS after quit: \(buttons().map(\.0))") }

            // Unpin from the pinned button's menu.
            var unpinned = false
            if let pin = buttons().first(where: { ["pin: PaneFixture", "pin: dev.pane.fixture"].contains($0.0) }) {
                SyntheticMouse.rightClick(at: pin.1)
                if await eventually(timeout: 3, { Self.choice(pane.processIdentifier, "Unpin from taskbar") != nil }),
                   let item = Self.choice(pane.processIdentifier, "Unpin from taskbar") {
                    SyntheticMouse.click(at: item)
                    unpinned = await eventually(timeout: 4) { !buttons().contains { ["pin: PaneFixture", "pin: dev.pane.fixture"].contains($0.0) } && !Self.pinnedInConfig().contains(FixtureBundle.bundleID) }
                }
            }
            let yoursUnchanged = (try? Data(contentsOf: SettingsStore.defaultURL)) == yours
            Report.record("Taskbar · pin", "menu had Pin to taskbar \(pinItem != nil), saved \(saved); button stays after quit \(stays); unpinned \(unpinned); your config.json unchanged \(yoursUnchanged)")
            print("PIN: menu \(pinItem != nil), saved \(saved), stays \(stays), unpinned \(unpinned), your config unchanged \(yoursUnchanged)")
            #expect(pinItem != nil && saved)
            #expect(stays)
            #expect(unpinned)
            #expect(yoursUnchanged)
        }

        /// "Sync pinned apps with the macOS Dock" on: pinning in pane adds the app to the Dock's pinned apps, unpinning
        /// removes it. Uses your real Dock (gated: PANE_DOCK_SYNC=1); your Dock's list is backed up and put back exactly.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_DOCK_SYNC"] != nil)) func pinsFollowTheDock() async throws {
            func dockList() -> Any? { CFPreferencesAppSynchronize("com.apple.dock" as CFString); return CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) }
            func dockIDs() -> [String] { ((dockList() as? [[String: Any]]) ?? []).compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String } }
            let original = dockList()
            let originalData = original.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            defer {
                let now = dockList().flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
                if now != originalData { DockPins.restore((original as? [[String: Any]]) ?? []) }
            }
            let f = try await Fixture.launch(label: "Y", windows: ["A"], frame: CGRect(x: 160, y: 200, width: 400, height: 280))
            defer { f.quit() }
            let pane = try Harness.launchAgent { try? $0.set(PaneSettings.syncDockPins, true) }
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            func buttons() -> [(String, CGPoint)] { Harness.taskbarButtons(pane.processIdentifier) }
            let startsFromDock = dockIDs().allSatisfy { id in buttons().contains { $0.0.hasPrefix("pin: ") || $0.0.hasPrefix("group: ") } || id.isEmpty }
            func menu(_ title: String) async -> Bool {
                guard let b = buttons().first(where: { $0.0.hasPrefix("group: PaneFixture") }) else { return false }
                SyntheticMouse.rightClick(at: b.1)
                guard await eventually(timeout: 3, { Self.choice(pane.processIdentifier, title) != nil }), let item = Self.choice(pane.processIdentifier, title) else { return false }
                SyntheticMouse.click(at: item)
                return true
            }
            let pinClicked = await menu("Pin to taskbar")
            let inDock = await eventually(timeout: 8) { dockIDs().contains(FixtureBundle.bundleID) }
            await settle(2.5) // the Dock restarts; pane re-reserves nothing (its settings are already written)
            let barStill = await eventually(timeout: 6) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            let unpinClicked = await menu("Unpin from taskbar")
            let outOfDock = await eventually(timeout: 8) { !dockIDs().contains(FixtureBundle.bundleID) }
            await settle(2.5)
            let originalIDs = ((original as? [[String: Any]]) ?? []).compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
            let othersKept = dockIDs() == originalIDs
            if !othersKept { print("DOCK IDS before \(originalIDs)\nDOCK IDS after  \(dockIDs())") }
            let note = "pin clicked \(pinClicked) → in the Dock's pinned apps \(inDock); taskbar space still reserved \(barStill); unpin clicked \(unpinClicked) → removed \(outOfDock); the Dock's other pins unchanged \(othersKept); started from the Dock's pins \(startsFromDock)"
            Report.record("Taskbar · Dock pin sync", note)
            print("DOCKSYNC: " + note)
            #expect(inDock && outOfDock && othersKept)
        }

        /// T2: dragging a pinned app's button past another moves it there, and the pinned order is saved.
        @Test func dragReordersPinnedApps() async throws {
            // A window on the desktop: from a full-screen Space the taskbar rightly stays hidden.
            let f = try await Fixture.launch(label: "R", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 360, height: 260))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            // In screen order (left to right), not the accessibility tree's order.
            func buttons() -> [(String, CGPoint)] { Harness.taskbarButtons(pane.processIdentifier).filter { $0.0.hasPrefix("pin: ") }.sorted { $0.1.x < $1.1.x } }
            let before = buttons().map(\.0)
            guard before.count >= 3 else {
                Issue.record("need 3 pinned apps, have \(before); all buttons \(Harness.taskbarButtons(pane.processIdentifier).map(\.0))")
                return
            }
            // Drag the second pinned app past the third.
            let a = buttons()[1], b = buttons()[2]
            // Apps with a Dock icon, by pid: background helpers come and go on their own.
            func regularApps() -> Set<pid_t> { Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)) }
            let wasRunning = regularApps()
            SyntheticMouse.drag(from: a.1, to: CGPoint(x: b.1.x + 26, y: b.1.y), steps: 20, hold: 0.15)
            let moved = await eventually(timeout: 3) { let now = buttons().map(\.0); return now.firstIndex(of: a.0) ?? 0 > now.firstIndex(of: b.0) ?? 0 }
            let after = buttons().map(\.0)
            let saved = Self.pinnedInConfig()
            let savedOrder = saved.count >= 3
            await settle(1)
            let launched = regularApps().subtracting(wasRunning).compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            let launchedNothing = launched.isEmpty
            if !launchedNothing { print("REORDER launched: \(launched)") }
            let note = "before \(before.prefix(4)); dragged \(a.0) past \(b.0) → moved \(moved); after \(after.prefix(4)); saved pinned \(saved.prefix(4)); no app launched by the drag \(launchedNothing)"
            Report.record("Taskbar · drag to reorder", note)
            print("REORDER: " + note)
            #expect(moved && savedOrder && launchedNothing)
        }
    }
}
