// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 7 end to end with synthesized keys: chords are swallowed and act on the focused window.
    /// Ctrl+Opt+Cmd stands in for "Win" so the test can't collide with anything real.
    @Suite("7b · Keyboard flows")
    struct KeyboardFlowTests {
        static let win: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

        @Test func winArrowSnapsAndAltF4ClosesTheFocusedWindow() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B"])
            defer { f.quit() }
            Focus.focus(try f.requireWindow("B"), using: .skyLight)
            try #require(await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "F B" })
            let b = try f.requireWindow("B")
            let original = try #require(AX.frame(b))
            let work = try #require(Geometry.workArea(for: original))

            let keys = try KeyTap()
            defer { keys.stop() }
            defer { SyntheticKeyboard.releaseAllModifiers() }
            let snap = { (target: Geometry.Snap) in
                guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid), let frame = AX.frame(window),
                      let area = Geometry.workArea(for: frame) else { return }
                AX.setFrame(window, Geometry.rect(for: target, in: area))
            }
            keys.bind(.init(kVK_LeftArrow, Self.win)) { snap(.leftHalf) }
            keys.bind(.init(kVK_UpArrow, Self.win)) { snap(.maximize) }
            keys.bind(.init(kVK_F4, .maskAlternate)) {
                guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid),
                      let close = AX.button(window, kAXCloseButtonAttribute) else { return }
                AX.perform(close, kAXPressAction)
            }

            SyntheticKeyboard.press(kVK_LeftArrow, Self.win)
            let left = await eventually { AX.frame(b).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false }
            SyntheticKeyboard.press(kVK_UpArrow, Self.win)
            let max = await eventually { AX.frame(b).map { Geometry.approximatelyEqual($0, work) } ?? false }
            SyntheticKeyboard.press(kVK_F4, .maskAlternate)
            let closed = await eventually { f.window("B") == nil }
            let aStillOpen = f.window("A") != nil && !f.app.isTerminated
            Report.record("7b Keyboard · chords", "Win+Left→left half=\(left), Win+Up→maximize=\(max), Alt+F4 closed focused only=\(closed && aStillOpen)")
            let diag = "secure input now \(SyntheticKeyboard.secureInputOn), presses during it so far \(SyntheticKeyboard.pressesDuringSecureInput), frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
            #expect(left, "\(diag)")
            #expect(max, "\(diag)")
            #expect(closed && aStillOpen, "\(diag)")
        }

        @Test func loneModifierTapsAreDetected() async throws {
            let keys = try KeyTap()
            defer { keys.stop() }
            let lock = NSLock()
            var taps: [KeyTap.Modifier] = []
            keys.onModifierTap = { modifier in lock.withLock { taps.append(modifier) } }

            defer { SyntheticKeyboard.releaseAllModifiers() }
            SyntheticKeyboard.tap(.option)
            SyntheticKeyboard.tap(.command)
            // A chord must not count as a lone tap.
            SyntheticKeyboard.press(kVK_ANSI_C, .maskAlternate)
            await settle(0.3)
            let seen = lock.withLock { taps }
            let stuck = SyntheticKeyboard.heldModifiers
            Report.record("7b Keyboard · lone modifier taps", "\(seen) (expected [option, command]); modifiers still held afterwards=\(stuck.rawValue == 0 ? "none" : String(stuck.rawValue, radix: 16))")
            #expect(seen == [.option, .command], "secure input now \(SyntheticKeyboard.secureInputOn), presses during it \(SyntheticKeyboard.pressesDuringSecureInput), frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
            #expect(stuck.isEmpty, "synthesized input left a modifier held system-wide")
        }
    }
}
