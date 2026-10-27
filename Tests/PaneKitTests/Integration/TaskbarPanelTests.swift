// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// M2 spike + harness: does a small real Dock reserve the bar's space, does the panel sit above it and
    /// survive Space switches, and do clicks on its buttons act on the right windows?
    @Suite("M2 · Taskbar")
    struct TaskbarPanelTests {
        static let barHeight: CGFloat = 48

        /// Screen rect of the button for `title` in the panel, in AX coordinates.
        @MainActor static func buttonCenter(_ bar: TaskbarPanel, title: String) -> CGPoint? {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.accessibilityTitle() == title { return button }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            guard let content = bar.panel.contentView, let button = find(content) else { return nil }
            let inWindow = button.convert(button.bounds, to: nil)
            let onScreen = bar.panel.convertToScreen(inWindow)
            let ax = Geometry.cocoaToAX(onScreen, primaryHeight: Geometry.primaryHeight)
            return CGPoint(x: ax.midX, y: ax.midY)
        }

        @Test func dockReservationPanelAndClicks() async throws {
            TestSystemSettings.recoverIfNeeded()
            let original = DockReservation.bottomInset()
            let reservation = DockReservation(settings: SystemSettings(backupURL: TestSystemSettings.url))
            defer { reservation.restore() }

            let achieved = try reservation.apply(height: Self.barHeight)
            Report.record("M2 Taskbar · Dock reservation", "inset \(original) → \(achieved) for a \(Self.barHeight) pt bar")
            #expect(achieved == Self.barHeight)

            // Native Fill (title-bar double-click, no pane tap) must stop above the bar.
            let f = try await Fixture.launch(label: "K", windows: ["A", "B"])
            defer { f.quit() }
            let a = try f.requireWindow("A")
            SyntheticMouse.doubleClick(at: try MouseTests.titleBarPoint(a))
            await settle(1.0)
            let filled = try #require(AX.frame(a))
            let screenHeight = NSScreen.screens[0].frame.height
            Report.record("M2 Taskbar · native Fill with reservation", "frame bottom \(filled.maxY) vs bar top \(screenHeight - achieved)")
            #expect(filled.maxY <= screenHeight - achieved + 1)

            // The harness panel over the Dock.
            let inventory = WindowInventory()
            let bar = await MainActor.run { TaskbarPanel(inventory: inventory, height: achieved) }
            await MainActor.run {
                bar.includedPIDs = [f.pid] // per-window mode with every window on this Mac would overflow
                inventory.onChange = { windows in MainActor.assumeIsolated { bar.update(windows) } }
                inventory.start()
                bar.show()
            }
            defer { MainActor.assumeIsolatedOrSync { bar.close(); inventory.stop() } }
            #expect(await eventually(timeout: 3) { MainActor.assumeIsolatedOrSync { bar.items.contains { $0.title == "K B" } } })
            let barWID = CGWindowID(await MainActor.run { bar.panel.windowNumber })
            let panelWindow = try #require(WindowServer.windows().first { $0.id == barWID })
            let dockLevel = WindowServer.windows().filter { $0.ownerName == "Dock" }.map(\.layer).max() ?? 0
            Report.record("M2 Taskbar · panel", "level \(panelWindow.layer) vs Dock \(dockLevel); bounds \(panelWindow.bounds)")
            #expect(panelWindow.layer > dockLevel)
            #expect(panelWindow.bounds.maxY == screenHeight)

            // Click B's button → B comes forward; click again → B minimizes (Windows semantics).
            AX.set(a, kAXMainAttribute, kCFBooleanTrue)
            Focus.focus(a, using: .skyLight)
            let bPoint = try #require(await MainActor.run { Self.buttonCenter(bar, title: "K B") })
            SyntheticMouse.click(at: bPoint)
            let focusedB = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "K B" && AX.frontmostPID() == f.pid }
            inventory.scheduleRefresh()
            _ = await eventually { MainActor.assumeIsolatedOrSync { bar.items.first { $0.title == "K B" }?.isActive == true } }
            let again = try #require(await MainActor.run { Self.buttonCenter(bar, title: "K B") })
            SyntheticMouse.click(at: again)
            let minimized = await eventually { f.window("B").map(AX.isMinimized) == true }
            Report.record("M2 Taskbar · clicks", "click inactive → focused=\(focusedB); click active → minimized=\(minimized)")
            #expect(focusedB)
            #expect(minimized)

            // Middle-click → new window in the running app.
            let aPoint = try #require(await MainActor.run { Self.buttonCenter(bar, title: "K A") })
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: aPoint, mouseButton: .center)
                event?.post(tap: .cghidEventTap)
                usleep(40_000)
            }
            let newWindow = await eventually(timeout: 3) { f.window("New 1") != nil }
            Report.record("M2 Taskbar · middle-click", "new window in running app=\(newWindow)")
            #expect(newWindow)
        }

        /// Windows hides the taskbar for fullscreen apps and keeps it fixed on the desktop.
        @Test func panelAcrossSpaces() async throws {
            // Start from a desktop: fronting a fixture window switches away from any fullscreen Space.
            let d = try await Fixture.launch(label: "D", windows: ["A"])
            defer { d.quit() }
            try #require(await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop })
            let inventory = WindowInventory()
            let bar = await MainActor.run { TaskbarPanel(inventory: inventory, height: Self.barHeight) }
            await MainActor.run { bar.show() }
            defer { MainActor.assumeIsolatedOrSync { bar.close() } }
            let barWID = CGWindowID(await MainActor.run { bar.panel.windowNumber })
            let find = { WindowServer.windows(onScreenOnly: false).first { $0.id == barWID } }
            _ = await eventually { find()?.isOnScreen == true }
            let before = try #require(find())

            let x = try await Fixture.launch(label: "X", windows: ["Full"])
            defer { x.quit() }
            let full = try x.requireWindow("Full")
            AX.set(full, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen })
            await settle(1.0)
            _ = await eventually { find()?.isOnScreen != true }
            let inFullscreen = find()
            AX.set(full, "AXFullScreen", kCFBooleanFalse)
            _ = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.kind == .desktop }
            await settle(1.0)
            _ = await eventually { find()?.isOnScreen == true }
            let after = find()
            Report.record("M2 Taskbar · across Spaces", "desktop onscreen=\(before.isOnScreen); in fullscreen Space onscreen=\(inFullscreen?.isOnScreen ?? false); back on desktop onscreen=\(after?.isOnScreen ?? false) bounds \(before.bounds) → \(after?.bounds ?? .zero)")
            #expect(before.isOnScreen)
            #expect(inFullscreen?.isOnScreen != true)
            #expect(after?.isOnScreen == true && after?.bounds == before.bounds)
        }
    }
}
