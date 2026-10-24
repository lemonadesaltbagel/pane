// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// T3: the taskbar's far-right sliver shows the desktop (this desktop's windows minimized) and, clicked again,
    /// brings back exactly those windows at the same frames with the same focus.
    @Suite("Taskbar · show desktop")
    struct ShowDesktopTests {
        @Test func sliverMinimizesAndRestores() async throws {
            let f = try await Fixture.launch(label: "D", windows: ["A", "B"], frame: CGRect(x: 160, y: 200, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            await settle(3)
            let a = try f.requireWindow("A"), b = try f.requireWindow("B")
            Focus.focus(b, using: .skyLight)
            _ = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "D B" }
            let frames = [AX.frame(a), AX.frame(b)]
            let sliver = try #require(Harness.taskbarButtons(pane.processIdentifier).first { $0.0 == "Show desktop" })
            func minimized(_ w: AXUIElement) -> Bool { AX.get(w, kAXMinimizedAttribute) == true }
            SyntheticMouse.click(at: sliver.1)
            let hidden = await eventually(timeout: 4) { minimized(a) && minimized(b) }
            await settle(1.8) // past the moment where a stale focus report could reset it
            SyntheticMouse.click(at: sliver.1)
            let back = await eventually(timeout: 4) { !minimized(a) && !minimized(b) }
            await settle(0.8)
            let sameFrames = [AX.frame(a), AX.frame(b)].enumerated().allSatisfy { i, fr in fr.map { f in frames[i].map { Geometry.approximatelyEqual(f, $0) } ?? false } ?? false }
            let focusBack = AX.focusedWindow(of: f.pid).flatMap(AX.title) == "D B"
            let note = "sliver at x \(Int(sliver.1.x)); first click minimized both \(hidden); second click restored both \(back), same frames \(sameFrames), focus back on B \(focusBack)"
            Report.record("Taskbar · show desktop", note)
            print("SHOWDESKTOP: " + note)
            #expect(hidden && back && sameFrames)
            #expect(focusBack)
        }

        /// T4: with "Automatically hide the taskbar", nothing is reserved, the bar sits as a 2 pt line, comes up at the
        /// bottom edge (the macOS Dock never does), and goes again when the pointer leaves.
        @Test func autoHideTaskbar() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent { try? $0.set(PaneSettings.autoHide, true) }
            var stopped = false
            defer { if !stopped { stopAgent(pane) } }
            let screenH = NSScreen.screens[0].frame.height
            let nothingReserved = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() < 10 } }
            await settle(3)
            func barTop() -> CGFloat? { WindowServer.windows().first { $0.pid == pane.processIdentifier && $0.bounds.height == 48 }?.bounds.minY }
            func move(_ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
            move(CGPoint(x: 720, y: 400))
            let hiddenAtRest = await eventually(timeout: 3) { (barTop() ?? 0) >= screenH - 3 }
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { Issue.record("no Dock"); return }
            func dockTop() -> CGFloat { ((AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? []).compactMap(AX.frame).map(\.minY).min() ?? screenH }
            for y in stride(from: screenH - 120, through: screenH - 1, by: 6) { move(CGPoint(x: 720, y: y)); try? await Task.sleep(nanoseconds: 12_000_000) }
            move(CGPoint(x: 720, y: screenH - 1)) // the very edge (the screen stops a real pointer there)
            let shown = await eventually(timeout: 2) { barTop().map { abs($0 - (screenH - 48)) < 1 } ?? false }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let dockStayedHidden = dockTop() >= screenH - 10
            move(CGPoint(x: 720, y: 400))
            let hiddenAgain = await eventually(timeout: 3) { (barTop() ?? 0) >= screenH - 3 }
            stopAgent(pane); stopped = true
            _ = await eventually(timeout: 8) { SystemSettings.read("com.apple.dock", "autohide") as? Bool == false }
            let dockRestored = (SystemSettings.read("com.apple.dock", "autohide") as? Bool) == false
            let note = "nothing reserved \(nothingReserved); bar a 2 pt line at rest \(hiddenAtRest); pointer at the bottom edge → bar shown \(shown), macOS Dock stayed hidden \(dockStayedHidden); pointer away → hidden again \(hiddenAgain); your Dock's auto-hide back off after quitting \(dockRestored)"
            Report.record("Taskbar · auto-hide", note)
            print("AUTOHIDE: " + note)
            #expect(nothingReserved && hiddenAtRest && shown && dockStayedHidden && hiddenAgain && dockRestored)
        }
    }
}
