// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// macOS 26 opens its own menu (Fill, tiles, full screen) when the pointer rests on the green button. Measures
    /// whether AppKit's `NSZoomButtonShowMenu` = false (`NativeTakeover.zoomButtonMenu`) stops it, in an app already
    /// running and in one launched after. Measured: only in apps launched after. The menu stays open after the pointer
    /// leaves; a click away from it closes it. Moves the real pointer; puts your global value back.
    @Suite("Experiments · the green button's menu")
    struct ZoomMenuExperimentTests {
        /// Windows that appear while the pointer rests on the button (not the fixture's own).
        static func menuWindows(over window: AXUIElement, fixture pid: pid_t) async throws -> [WindowServerWindow] {
            let button = try #require(AX.button(window, kAXFullScreenButtonAttribute) ?? AX.button(window, kAXZoomButtonAttribute))
            let frame = try #require(AX.frame(button))
            let target = CGPoint(x: frame.midX, y: frame.midY)
            func move(_ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
            move(CGPoint(x: target.x + 120, y: target.y + 80))
            await settle(0.5)
            let before = Set(WindowServer.windows().filter(\.isOnScreen).map(\.id))
            for step in 1...10 { move(CGPoint(x: target.x + 12 * CGFloat(10 - step), y: target.y + 8 * CGFloat(10 - step))); try? await Task.sleep(nanoseconds: 30_000_000) }
            await settle(2.0)
            let appeared = WindowServer.windows().filter { !before.contains($0.id) && $0.pid != pid && $0.isOnScreen }
            // It stays open after the pointer leaves: a click in the window, away from the menu, closes it.
            if let content = AX.frame(window) { SyntheticMouse.click(at: CGPoint(x: content.maxX - 20, y: content.maxY - 20)) }
            await settle(1.0)
            return appeared
        }

        static func describe(_ windows: [WindowServerWindow]) -> String {
            windows.isEmpty ? "none" : windows.map { "\($0.ownerName ?? "?") \(Int($0.bounds.width))×\(Int($0.bounds.height)) layer \($0.layer)" }.joined(separator: "; ")
        }

        @Test func zoomButtonShowMenuStopsIt() async throws {
            let key = "NSZoomButtonShowMenu" as CFString, any = kCFPreferencesAnyApplication
            let original = CFPreferencesCopyAppValue(key, any)
            defer { CFPreferencesSetAppValue(key, original, any); CFPreferencesAppSynchronize(any) }
            CFPreferencesSetAppValue(key, nil, any); CFPreferencesAppSynchronize(any)

            let a = try await Fixture.launch(label: "Z", windows: ["A"], frame: CGRect(x: 300, y: 250, width: 500, height: 320))
            defer { a.quit() }
            let native = try await Self.menuWindows(over: try a.requireWindow("A"), fixture: a.pid)
            let again = try await Self.menuWindows(over: try a.requireWindow("A"), fixture: a.pid) // a second hover shows it too

            CFPreferencesSetAppValue(key, kCFBooleanFalse, any); CFPreferencesAppSynchronize(any)
            await settle(0.5)
            if let w = a.window("A") { Focus.focus(w, using: .skyLight) }
            await settle(0.5)
            let live = try await Self.menuWindows(over: try a.requireWindow("A"), fixture: a.pid)

            let b = try await Fixture.launch(label: "Y", windows: ["B"], frame: CGRect(x: 320, y: 270, width: 500, height: 320))
            defer { b.quit() }
            let launched = try await Self.menuWindows(over: try b.requireWindow("B"), fixture: b.pid)

            let note = "default: \(Self.describe(native)), hovered again: \(Self.describe(again)) · set while running: \(Self.describe(live)) · app launched after: \(Self.describe(launched))"
            Report.record("Experiments · the green button's menu", note)
            print("ZOOM-MENU: " + note)
            #expect(!native.isEmpty && !again.isEmpty, "macOS's menu didn't appear by default: nothing to compare")
            // Measured: AppKit reads it when an app starts. A running app keeps the menu until it's reopened.
            #expect(launched.isEmpty, "the menu still opened in an app launched after the default was set")
        }
    }
}
