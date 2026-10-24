// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 3 (per-window controls) and the AX side of feature 7 (Alt+F4, menu access).
    @Suite("3 · Per-window controls")
    struct ControlsTests {
        @Test func standardWindowExposesEveryButton() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try #require(f.window("A"))
            for attribute in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute] {
                #expect(AX.button(window, attribute) != nil, "\(attribute) missing")
            }
        }

        @Test func minimizeAndRestoreThroughAX() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try #require(f.window("A")), wid = try #require(f.wid("A"))
            AX.set(window, kAXMinimizedAttribute, kCFBooleanTrue)
            #expect(await eventually { !WindowServer.zOrder().contains(wid) })
            #expect(AX.windows(of: f.pid).contains { CFEqual($0, window) }, "minimized windows stay in kAXWindows")
            AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
            #expect(await eventually(timeout: 3) { WindowServer.zOrder().contains(wid) })
        }

        /// Alt+F4 = close the focused window (not ⌘Q, which quits every window of the app).
        @Test func altF4ClosesOnlyTheFocusedWindow() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B"])
            defer { f.quit() }
            Focus.focus(try #require(f.window("B")), using: .skyLight)
            try #require(await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "F B" })

            let focused = try #require(AX.focusedWindow(of: f.pid))
            AX.perform(try #require(AX.button(focused, kAXCloseButtonAttribute)), kAXPressAction)
            #expect(await eventually { f.window("B") == nil })
            #expect(f.window("A") != nil)
            #expect(!f.app.isTerminated)
        }

        @Test func menuBarIsReadableAndPressableThroughAX() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let titles = AX.menuBarItems(of: f.pid).map(\.0)
            Report.record("3 Controls · AX menu bar", titles.joined(separator: " | "))
            #expect(titles.contains("File"))
            #expect(titles.contains("Window"))
            #expect(AX.menuItem(of: f.pid, path: ["File", "Close Window"]) != nil)
        }
    }
}
