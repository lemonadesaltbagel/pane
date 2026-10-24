// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// The real `pane` agent as a separate process, driven from outside like a user would.
    @Suite("E2E · pane agent")
    struct AgentE2ETests: AgentHarness {
        @Test func agentRunsTheWholeLoopAndRestoresOnExit() async throws {
            let before = DockReservation.bottomInset()
            let tilingBefore = SystemSettings.read("com.apple.WindowManager", "EnableTilingByEdgeDrag") as? Bool
            let pane = Process()
            pane.executableURL = Self.binary
            pane.arguments = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID]
            pane.standardError = FileHandle.nullDevice
            try pane.run()
            defer { stopAgent(pane) }

            let reserved = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            let tilingOff = SystemSettings.read("com.apple.WindowManager", "EnableTilingByEdgeDrag") as? Bool == false
            #expect(reserved)
            #expect(tilingOff)

            let f = try await Fixture.launch(label: "E", windows: ["A", "B"])
            defer { f.quit() }
            // Default combine mode (Windows' "always"): one group button for the fixture's two windows.
            let groupTitle = "group: PaneFixture (2)"
            let listed = await eventually(timeout: 4) { Self.taskbarButtons(pane.processIdentifier).contains { $0.0 == groupTitle } }
            #expect(listed, "taskbar buttons: \(Self.taskbarButtons(pane.processIdentifier).map(\.0))")

            // Group click → pop-up → window B focused.
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            if let group = Self.taskbarButtons(pane.processIdentifier).first(where: { $0.0 == groupTitle }) { SyntheticMouse.click(at: group.1) }
            var flyoutEntry: AXUIElement?
            _ = await eventually(timeout: 3) {
                guard let flyout = AX.windows(of: pane.processIdentifier).first(where: { AX.title($0) == "Pane Group Flyout" }) else { return false }
                func find(_ element: AXUIElement) -> AXUIElement? {
                    if AX.title(element) == "flyout: E B" { return element }
                    for child in (AX.get(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let hit = find(child) { return hit } }
                    return nil
                }
                flyoutEntry = find(flyout)
                return flyoutEntry != nil
            }
            if let flyoutEntry { AX.perform(flyoutEntry, kAXPressAction) }
            let focused = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "E B" }

            // Drag A to the right edge → right half within the reserved work area.
            let a = try f.requireWindow("A")
            let aFrame = try #require(AX.frame(a))
            let work = try #require(Geometry.workArea(for: aFrame))
            SyntheticMouse.drag(from: try MouseTests.titleBarPoint(a), to: CGPoint(x: work.maxX - 1, y: work.midY), hold: 0.2)
            let right = Geometry.rect(for: .rightHalf, in: work)
            let snapped = await eventually { AX.frame(a).map { Geometry.approximatelyEqual($0, right) } ?? false }
            // Snap Assist offers the other half — non-modal, so pane keeps running normally.
            let assistShown = await eventually(timeout: 2) { AX.windows(of: pane.processIdentifier).contains { AX.title($0) == "Pane Choices" } }

            // Close both windows → the fixture quits (opt-out lifecycle, scoped to fixtures).
            try f.close("B")
            try f.close("A")
            let quit = await eventually(timeout: 6) { f.app.isTerminated }

            pane.terminate()
            let exited = await eventually(timeout: 8) { !pane.isRunning }
            if !exited { kill(pane.processIdentifier, SIGKILL) }
            let restored = await eventually(timeout: 6) { DockReservation.bottomInset() == before }
            let tilingRestored = SystemSettings.read("com.apple.WindowManager", "EnableTilingByEdgeDrag") as? Bool == tilingBefore
            Report.record("E2E · pane agent", "reserved 48=\(reserved) tilingOff=\(tilingOff) listed=\(listed) taskbarClick→focus=\(focused) dragSnap=\(snapped) assistShown=\(assistShown) quitOnLastClose=\(quit) exitedOnSIGTERM=\(exited) restored(inset \(DockReservation.bottomInset()))=\(restored) tilingRestored=\(tilingRestored)")
            #expect(exited)
            #expect(focused)
            #expect(snapped)
            #expect(quit)
            #expect(restored)
            #expect(tilingRestored)
        }

        /// Start and the pinned "Apps" button (user report: both did nothing). Start opens pane's Start (the default since
        /// the Start stage) and "Apps" macOS's Apps panel; a second click closes each.
        @Test func agentStartAndAppsButtons() async throws {
            let pane = Process()
            pane.executableURL = Self.binary
            pane.arguments = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID, "--desktop-scope", FixtureBundle.bundleID]
            var env = ProcessInfo.processInfo.environment; env["PANE_DEBUG_START"] = "1"; pane.environment = env
            let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pane-start.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            pane.standardError = try FileHandle(forWritingTo: logURL)
            try pane.run()
            defer { stopAgent(pane); print("AGENT: " + (((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("start") || $0.contains("pinned") }.joined(separator: " / "))) }
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            let f = try await Fixture.launch(label: "S", windows: ["A"], frame: CGRect(x: 100, y: 200, width: 300, height: 200))
            defer { f.quit() }
            await settle(Double(ProcessInfo.processInfo.environment["PANE_START_SETTLE"] ?? "") ?? 6.0) // pane restarts the Dock at launch; it answers the Apps toggle a few seconds later
            var results: [String] = []
            // Start: pane's Start menu.
            if let button = Self.taskbarButtons(pane.processIdentifier).first(where: { $0.0 == "Start" }) {
                SyntheticMouse.click(at: button.1)
                let opened = await eventually(timeout: 3) { StartMenuTests.window(pane.processIdentifier) != nil }
                await settle(0.5)
                SyntheticMouse.click(at: button.1)
                let closed = await eventually(timeout: 3) { StartMenuTests.window(pane.processIdentifier) == nil }
                results.append("Start: opens pane's Start \(opened), second click closes \(closed)")
                #expect(opened && closed, "Start")
            } else { results.append("Start: no button"); Issue.record("no Start button") }
            for title in ["pin: Apps"] {
                guard let button = Self.taskbarButtons(pane.processIdentifier).first(where: { $0.0 == title }) else { results.append("\(title): no button"); continue }
                // A Dock restarted many times by the suite's agents can answer slowly: generous waits, and a stable
                // state before the next click (a late open would otherwise be toggled shut by it).
                _ = await eventually(timeout: 6) { !AppsPanel.isShown }
                SyntheticMouse.click(at: button.1)
                let opened = await eventually(timeout: 12) { AppsPanel.isShown } // includes the Spotlight-restart heal (~9 s)
                await settle(1.0)
                SyntheticMouse.click(at: button.1)
                let closed = await eventually(timeout: 6) { !AppsPanel.isShown }
                if !closed { AppsPanel.toggle(); _ = await eventually(timeout: 2) { !AppsPanel.isShown } }
                results.append("\(title): opens Apps \(opened), second click closes \(closed)")
                #expect(opened && closed, "\(title)")
            }
            Report.record("E2E · Start and Apps", results.joined(separator: "; "))
        }
}
}
