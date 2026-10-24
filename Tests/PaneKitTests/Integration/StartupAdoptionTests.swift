// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Experiment (PANE_STRESS=1): pane started midway, with windows already in every state. What does it do with them?
    /// A window in macOS full screen, one reaching under where the taskbar will be, a minimized one, an app with no
    /// windows, a hidden app. Measured before and after pane starts; nothing is asserted beyond pane not breaking them.
    @Suite("Experiments · startup adoption")
    struct StartupAdoptionTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func paneStartedMidway() async throws {
            let screen = Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight)
            // Before pane: all states set up with fixtures.
            let full = try await Fixture.launch(label: "Full", windows: ["F"], frame: CGRect(x: 100, y: 120, width: 500, height: 360))
            defer { full.quit() }
            let low = try await Fixture.launch(label: "Low", windows: ["L"], frame: CGRect(x: 300, y: screen.height - 300, width: 500, height: 290))
            defer { low.quit() }
            let mini = try await Fixture.launch(label: "Mini", windows: ["M"], frame: CGRect(x: 500, y: 200, width: 400, height: 300))
            defer { mini.quit() }
            let empty = try await Fixture.launch(label: "Empty", windows: ["E"], frame: CGRect(x: 600, y: 240, width: 300, height: 200))
            defer { empty.quit() }
            let hidden = try await Fixture.launch(label: "Hidden", windows: ["H"], frame: CGRect(x: 700, y: 260, width: 300, height: 200))
            defer { hidden.quit() }

            let lw = try low.requireWindow("L")
            AX.set(try mini.requireWindow("M"), kAXMinimizedAttribute, kCFBooleanTrue)
            try? empty.close("E")
            hidden.app.hide()
            let fw = try full.requireWindow("F")
            let fullWID = try #require(full.wid("F"))
            AX.set(fw, "AXFullScreen", kCFBooleanTrue)
            let inFull = await eventually(timeout: 6) { PrivateAPI.activeSpace()?.kind == .fullscreen }
            await settle(1.5)
            // Back to the desktop (a fixture window on it), leaving Full in its own Space.
            Focus.focus(lw, using: .skyLight)
            _ = await eventually(timeout: 6) { PrivateAPI.activeSpace()?.kind == .desktop }
            await settle(1.0)
            let lowBefore = AX.frame(lw)
            let miniBefore = AX.windows(of: mini.pid).map { "\(AX.title($0) ?? "?") minimized \(AX.get($0, kAXMinimizedAttribute) == true)" }

            // pane starts.
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            await settle(6)
            let buttons = Harness.taskbarButtons(pane.processIdentifier).map(\.0).filter { $0.contains("PaneFixture") || $0.hasPrefix("Full") || $0.hasPrefix("Low") || $0.hasPrefix("Mini") || $0.hasPrefix("Hidden") || $0.hasPrefix("Empty") }
            let barTop = screen.height - 48
            let lowAfter = AX.frame(lw)
            let lowCovered = (lowAfter?.maxY ?? 0) > barTop
            let fullStill = AX.get(fw, "AXFullScreen") == true || PrivateAPI.spaces(of: fullWID).contains { s in !PrivateAPI.visibleSpaces().contains(s) }
            let emptyAlive = !empty.app.isTerminated
            let hiddenAlive = !hidden.app.isTerminated && hidden.app.isHidden
            let miniWID = mini.wid("M")
            let miniAX = AX.windows(of: mini.pid).map { "\(AX.title($0) ?? "?") minimized \(AX.get($0, kAXMinimizedAttribute) == true)" }
            let miniOnScreen = miniWID.map { wid in WindowServer.windows(onScreenOnly: true).contains { $0.id == wid } } ?? false
            let miniStill = !miniOnScreen && miniAX.allSatisfy { $0.hasSuffix("true") }
            let log = ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("full screen") || $0.contains("quit") }

            // Reaching the full-screen window from the taskbar (a click on its button), then coming back.
            var reached = "no button"
            let groupButtons = Harness.taskbarButtons(pane.processIdentifier)
            if let b = groupButtons.first(where: { $0.0.hasPrefix("group: PaneFixture") }) {
                SyntheticMouse.click(at: b.1) // a group: flyout or the MRU window
                await settle(1.2)
                let flyout = AX.windows(of: pane.processIdentifier).first { AX.title($0) == "Pane Group Flyout" }
                if let flyout, let entry = Self.find(flyout, "flyout: Full F") {
                    SyntheticMouse.click(at: CGPoint(x: entry.midX, y: entry.midY))
                    let went = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .fullscreen }
                    await settle(1.0)
                    let converted = AX.get(fw, "AXFullScreen") != true && PrivateAPI.activeSpace()?.kind == .desktop
                    reached = "flyout entry → full-screen Space reached \(went); converted by pane on arrival \(converted)"
                } else {
                    reached = "flyout \(flyout != nil), no entry for Full F"
                }
            }
            // pane quits (the Dock restarts again to restore your settings): still minimized?
            stopAgent(pane)
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() != 48 }
            await settle(2.5)
            let miniAfterQuit = AX.windows(of: mini.pid).map { AX.get($0, kAXMinimizedAttribute) == true }
            reached += "; after pane quit, minimized window still minimized \(miniAfterQuit)"
            if PrivateAPI.activeSpace()?.kind == .fullscreen { Focus.focus(lw, using: .skyLight) }
            _ = await eventually(timeout: 6) { PrivateAPI.activeSpace()?.kind == .desktop }
            AX.set(fw, "AXFullScreen", kCFBooleanFalse)
            _ = await eventually(timeout: 6) { AX.get(fw, "AXFullScreen") != true }

            let note = """
            full screen entered before pane \(inFull); after pane started: still native full screen \(fullStill); \
            low window \(lowBefore.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "-") → \(lowAfter.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "-"), \
            under the taskbar (from y \(Int(barTop))) \(lowCovered); minimized before pane \(miniBefore), still minimized \(miniStill) (AX \(miniAX), on screen \(miniOnScreen), wid \(miniWID.map(String.init) ?? "nil")); windowless app alive \(emptyAlive); \
            hidden app alive and hidden \(hiddenAlive); taskbar fixture buttons \(buttons); agent log \(log.map { String($0) }); \(reached)
            """
            Report.record("Startup adoption", note)
            print("ADOPT: " + note)
        }

        /// With an auto-hidden Dock, windows reach the screen's bottom. pane starts and reserves the taskbar: the
        /// window must move up out from under the bar (Windows moves windows into a shrunk work area).
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func windowsUnderTheBarMoveUp() async throws {
            // Auto-hide the Dock for this test only, with its own backup (restored in defer, before anything else).
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-autohide-backup.plist")
            let dock = SystemSettings(backupURL: backup)
            try dock.apply([.init("com.apple.dock", "autohide", .bool(true))])
            defer { dock.restore(); _ = SystemSettings.read("com.apple.dock", "autohide") }
            _ = await eventually(timeout: 6) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() < 10 } }
            await settle(1.0)
            let screen = Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight)
            let f = try await Fixture.launch(label: "U", windows: ["Bottom", "Max"], frame: CGRect(x: 200, y: 300, width: 500, height: 300))
            defer { f.quit() }
            let bottom = try f.requireWindow("Bottom"), max = try f.requireWindow("Max")
            AX.setFrame(bottom, CGRect(x: 300, y: screen.height - 320, width: 500, height: 320))
            AX.setFrame(max, CGRect(x: 0, y: 25, width: screen.width, height: screen.height - 25))
            await settle(0.8)
            let before = [AX.frame(bottom), AX.frame(max)]
            let pane = try Harness.launchAgent()
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            let barTop = screen.height - 48
            let after = [AX.frame(bottom), AX.frame(max)]
            let log = ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("out from under") }
            stopAgent(pane)
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() != 48 } }
            func fmt(_ r: CGRect?) -> String { r.map { "y \(Int($0.minY))…\(Int($0.maxY))" } ?? "-" }
            let note = "auto-hide Dock: bottom window \(fmt(before[0])) → \(fmt(after[0])), screen-tall window \(fmt(before[1])) → \(fmt(after[1])); bar from y \(Int(barTop)); \(log.map(String.init))"
            Report.record("Startup · windows under the bar", note)
            print("UNDERBAR: " + note)
            #expect(after.allSatisfy { ($0?.maxY ?? .infinity) <= barTop + 1 })
        }

        /// Windows-style full screen (⌃⌘F) hides the taskbar and auto-hides the Dock: pushing the pointer to the bottom
        /// edge must not slide the Dock up over the window (user report).
        @Test func fullScreenBottomEdgeDoesNotRevealTheDock() async throws {
            let f = try await Fixture.launch(label: "E", windows: ["A"], frame: CGRect(x: 160, y: 160, width: 500, height: 360))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            let a = try f.requireWindow("A")
            Focus.focus(a, using: .skyLight)
            _ = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "E A" }
            SyntheticKeyboard.press(kVK_ANSI_F, [.maskControl, .maskCommand])
            defer { SyntheticKeyboard.releaseAllModifiers() }
            let screenH = NSScreen.screens[0].frame.height
            let filled = await eventually(timeout: 4) { AX.frame(a).map { $0.maxY >= screenH - 1 } ?? false }
            await settle(1.0)
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { Issue.record("no Dock"); return }
            func dockTop() -> CGFloat {
                ((AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? []).compactMap(AX.frame).map(\.minY).min() ?? screenH
            }
            let hiddenTop = dockTop()
            func move(_ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
            for y in stride(from: screenH - 200, through: screenH - 1, by: 6) { move(CGPoint(x: 720, y: y)); try? await Task.sleep(nanoseconds: 12_000_000) }
            for dx in [4.0, -4.0, 2.0] { move(CGPoint(x: 720 + dx, y: screenH - 1)); try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let revealedTop = dockTop()
            let revealed = revealedTop < screenH - 10
            move(CGPoint(x: 720, y: 400))
            await settle(0.8)
            SyntheticKeyboard.press(kVK_ANSI_F, [.maskControl, .maskCommand])
            _ = await eventually(timeout: 4) { AX.frame(a).map { $0.maxY < screenH - 40 } ?? false }
            Report.record("Full screen · Dock at the bottom edge", "filled \(filled); Dock icons' top hidden \(Int(hiddenTop)) → at the bottom edge \(Int(revealedTop)) (revealed \(revealed))")
            print("EDGE: filled \(filled), Dock top \(Int(hiddenTop)) → \(Int(revealedTop)), revealed \(revealed)")
            #expect(filled)
            #expect(!revealed)
        }

        /// Robustness: a window maximized before pane restarts still restores to its earlier size afterwards (pane keeps
        /// its restore frames on disk).
        @Test func maximizedWindowRestoresAfterPaneRestarts() async throws {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-placements.json"))
            let f = try await Fixture.launch(label: "R", windows: ["A"], frame: CGRect(x: 240, y: 220, width: 460, height: 320))
            defer { f.quit() }
            var pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            _ = await eventually(timeout: 10) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("running (pid") }
            await settle(2)
            let a = try f.requireWindow("A")
            let original = try #require(AX.frame(a))
            let work = Geometry.cocoaToAX(NSScreen.screens[0].visibleFrame, primaryHeight: Geometry.primaryHeight)
            func titleBar() -> CGPoint? { AX.frame(a).map { CGPoint(x: $0.midX, y: $0.minY + 12) } }
            if let p = titleBar() { SyntheticMouse.doubleClick(at: p) }
            let maximized = await eventually(timeout: 3) { AX.frame(a).map { Geometry.approximatelyEqual($0, work) } ?? false }
            // pane restarts.
            stopAgent(pane)
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() != 48 } }
            await settle(1.5)
            // macOS may nudge the window while the Dock comes back: put it back in the maximized frame pane gave it.
            AX.setFrame(a, work)
            pane = try Harness.launchAgent(fresh: false)
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            _ = await eventually(timeout: 10) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("running (pid") }
            await settle(2)
            AX.setFrame(a, work) // the work area is the same again
            await settle(0.5)
            if let p = titleBar() { SyntheticMouse.doubleClick(at: p) }
            let restored = await eventually(timeout: 3) { AX.frame(a).map { abs($0.width - original.width) <= 2 && abs($0.height - original.height) <= 2 } ?? false }
            let note = "maximized \(maximized); after pane restarted, double-click restored the earlier size \(restored) (\(AX.frame(a).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"), was \(Int(original.width))x\(Int(original.height)))"
            Report.record("Robustness · restore across a restart", note)
            print("RESTART: " + note)
            #expect(maximized && restored)
        }

        static func find(_ e: AXUIElement, _ title: String) -> CGRect? {
            if (AX.title(e) ?? "").hasPrefix(title) { return AX.frame(e) }
            for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let f = find(c, title) { return f } }
            return nil
        }
    }
}
