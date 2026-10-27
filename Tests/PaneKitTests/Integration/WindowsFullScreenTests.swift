// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// Windows-style full screen on the current desktop.
    @Suite("Windows full screen")
    struct WindowsFullScreenTests {
        static func dockAutoHidden() -> Bool { (SystemSettings.read("com.apple.dock", "autohide") as? Bool) ?? false }

        @Test func fullScreenOnTheCurrentDesktop() async throws {
            let f = try await Fixture.launch(label: "W", windows: ["A"])
            defer { f.quit() }
            let o = try await Fixture.launch(label: "O", windows: ["Other"], frame: CGRect(x: 900, y: 400, width: 400, height: 300))
            defer { o.quit() }
            let window = try f.requireWindow("A"), other = try o.requireWindow("Other")
            let wid = try #require(f.wid("A")), otherWID = try #require(o.wid("Other"))
            let original = try #require(AX.frame(window))
            let dockBefore = DockReservation.bottomInset()
            // Back = reserved again (a hidden Dock leaves ~0). A crowded Dock re-fits its icons when it comes back, so its
            // height can differ by a few points (measured 94 → 90).
            func dockIsBack() -> Bool { abs(DockReservation.bottomInset() - dockBefore) <= 8 }
            let bar = await MainActor.run { TaskbarPanel(inventory: WindowInventory(), height: 48) }
            let service = FullScreenService()
            service.onTaskbarSuppressed = { hidden, _ in MainActor.assumeIsolated { bar.suppressed = hidden } }
            await MainActor.run { bar.show() }
            defer { service.shutdown(); Task { @MainActor in bar.close() } }
            let barWID = CGWindowID(await MainActor.run { bar.panel.windowNumber })
            func barShown() -> Bool { WindowServer.windows(onScreenOnly: false).first { $0.id == barWID }?.isOnScreen ?? false }
            Focus.focus(window, using: .skyLight)
            _ = await eventually { barShown() }

            // Enter: fills the screen below the menu bar, taskbar hidden, Dock out of the way, same desktop.
            let spaceBefore = PrivateAPI.activeSpace()?.id
            service.toggle(window)
            let screen = Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight)
            let menuBar: CGFloat = 29
            let filled = await eventually(timeout: 2) { AX.frame(window).map { Geometry.approximatelyEqual($0, CGRect(x: 0, y: menuBar, width: screen.width, height: screen.height - menuBar), tolerance: 3) } ?? false }
            let barHidden = await eventually { !barShown() }
            let sameDesktop = PrivateAPI.activeSpace()?.id == spaceBefore
            let filledFrame = AX.frame(window) ?? .zero

            // Another window focused: taskbar back, Dock reserved again; refocus: hidden again.
            Focus.focus(other, using: .skyLight)
            service.focusChanged(to: otherWID)
            let barBack = await eventually { barShown() }
            let dockBack = await eventually(timeout: 2) { dockIsBack() }
            Focus.focus(window, using: .skyLight)
            service.focusChanged(to: wid)
            let barHiddenAgain = await eventually { !barShown() }

            // Leave: exact restore, taskbar and Dock back.
            service.toggle(window)
            let restored = await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, original) } ?? false }
            let dockRestored = await eventually(timeout: 2) { dockIsBack() }
            Report.record("Windows full screen", "filled \(filledFrame) (expected 0,\(Int(menuBar)) \(Int(screen.width))x\(Int(screen.height - menuBar)))=\(filled); taskbar hidden=\(barHidden); same desktop=\(sameDesktop); other focused → taskbar back=\(barBack) Dock back=\(dockBack); refocus → hidden=\(barHiddenAgain); exit → exact restore=\(restored) Dock restored=\(dockRestored)")
            #expect(filled && barHidden && sameDesktop)
            #expect(barBack && dockBack && barHiddenAgain)
            #expect(restored && dockRestored)
            #expect(!Self.dockAutoHidden())
        }

        @Test func aNativeFullScreenWindowComesBackToTheDesktop() async throws {
            let f = try await Fixture.launch(label: "N", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            AX.set(window, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen })
            await settle(1.0)
            let service = FullScreenService()
            defer { service.shutdown() }
            service.toggle(window)
            let onDesktop = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop && AX.get(window, "AXFullScreen") != true }
            await settle(0.5)
            let frame = AX.frame(window) ?? .zero
            Report.record("Windows full screen · from native", "back on the desktop=\(onDesktop), frame \(frame)")
            service.toggle(window)
            #expect(onDesktop)
            #expect(frame.height > 800)
        }
    }
}
