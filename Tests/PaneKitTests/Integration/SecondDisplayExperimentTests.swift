// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// What a second display (a virtual one) looks like to pane before any multi-display code: its menu bar and work
    /// area, a fixture window moved there, and whether the Dock follows the pointer to its bottom edge.
    @Suite("Experiments · a second display")
    struct SecondDisplayExperimentTests {
        @Test func measure() async throws {
            let f = try await Fixture.launch(label: "D", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 500, height: 320))
            defer { f.quit() }
            try await SecondDisplay.with { second in
                var notes: [String] = ["second display \(second)"]
                let screen = try #require(NSScreen.screens.dropFirst().first)
                let menuBar = screen.frame.maxY - screen.visibleFrame.maxY, bottom = screen.visibleFrame.minY - screen.frame.minY
                notes.append("its visible frame leaves \(Int(menuBar)) pt at the top, \(Int(bottom)) at the bottom")
                let window = try f.requireWindow("A")
                AX.setFrame(window, CGRect(x: second.minX + 100, y: second.minY + 100, width: 600, height: 400))
                await settle(0.5)
                let landed = AX.frame(window)
                notes.append("window set to +100,+100 on it → \(landed.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-")")
                notes.append("work area there \(landed.flatMap(Geometry.workArea(for:)).map { "\($0)" } ?? "-")")

                // The Dock: hold the pointer at the second display's bottom edge.
                let mainInset = DockReservation.bottomInset()
                let edge = CGPoint(x: second.midX, y: second.maxY - 1)
                for _ in 0..<60 {
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edge, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                await settle(1.5)
                let secondBottom = (NSScreen.screens.dropFirst().first?.visibleFrame.minY ?? 0) - screen.frame.minY
                notes.append("pointer held 3 s at its bottom edge: main inset \(Int(mainInset)) → \(Int(DockReservation.bottomInset())), second's bottom inset \(Int(secondBottom))")
                // Bring the Dock home if it moved: the same at the main display's bottom edge.
                if DockReservation.bottomInset() < mainInset {
                    let home = CGPoint(x: NSScreen.screens[0].frame.midX, y: NSScreen.screens[0].frame.height - 1)
                    for _ in 0..<60 {
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: home, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    await settle(1.5)
                    notes.append("held at the main bottom edge: main inset \(Int(DockReservation.bottomInset()))")
                }
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
                let note = notes.joined(separator: "; ")
                Report.record("Experiments · a second display", note)
                print("SECOND-DISPLAY: " + note)
            }
            let back = f.window("A").flatMap(AX.frame)
            print("SECOND-DISPLAY: after removal the window is at \(back.map { "\($0)" } ?? "-")")
        }

        /// Does the Dock's size decide whether it follows the pointer? The Dock reserved at pane's size (48 pt, no pane
        /// running), then the pointer held at the second display's bottom edge.
        @Test func dockAtPanesSizeFollowsThePointer() async throws {
            TestSystemSettings.recoverIfNeeded()
            let settings = SystemSettings(backupURL: TestSystemSettings.url)
            let reservation = DockReservation(settings: settings)
            let reserved = try reservation.apply(height: 48)
            defer { reservation.restore() }
            await settle(15) // well after the Dock's restart
            var after: CGFloat = 0
            try await SecondDisplay.with { second in
                let edge = CGPoint(x: second.midX, y: second.maxY - 1)
                for _ in 0..<60 {
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edge, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                await settle(1.5)
                after = DockReservation.bottomInset()
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let note = "the Dock at pane's size (main inset \(Int(reserved))), no pane: after the pointer held at the second display's bottom edge, main inset \(Int(after))"
            Report.record("Experiments · a second display", note)
            print("SECOND-DISPLAY-DOCK: " + note)
        }
    }
}
