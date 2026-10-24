// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Soak found a modifier left held after a ⌃⌘ desktop chord (2 of ~100). Reproduce: many switches against the
    /// real agent, and for any held modifier, watch whether it clears by itself.
    @Suite("Experiments · modifiers after desktop chords")
    struct ModifierStressTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func desktopChordsLeaveNoModifierHeld() async throws {
            let pane = Process()
            pane.executableURL = Harness.binary
            pane.arguments = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID, "--desktop-scope", FixtureBundle.bundleID]
            pane.standardError = FileHandle.nullDevice
            pane.environment = ProcessInfo.processInfo.environment // passes PANE_PARK_AFTER_RELEASE through
            try pane.run()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            await settle(1.0)
            // PANE_STRESS_WINDOWS=n: n windows to park per switch (the soak parks many; 2 never reproduced it).
            let count = Int(ProcessInfo.processInfo.environment["PANE_STRESS_WINDOWS"] ?? "") ?? 2
            let f = try await Fixture.launch(label: "M", windows: ["A", "B"] + (0..<max(0, count - 2)).map { "W\($0)" })
            defer { f.quit() }
            // Desktop 2 stays empty: switching to it fronts pane itself with no window (the soak's failing case).
            Focus.focus(try f.requireWindow("B"), using: .skyLight)
            await settle(0.3)
            SyntheticKeyboard.press(kVK_ANSI_D, [.maskControl, .maskCommand])
            await settle(0.5)
            let empty = ProcessInfo.processInfo.environment["PANE_STRESS"] == "empty"

            var stuck: [String] = []
            let rounds = Int(ProcessInfo.processInfo.environment["PANE_STRESS_ROUNDS"] ?? "") ?? 150
            for round in 0..<rounds {
                // PANE_STRESS=create: ⌃⌘D / ⌃⌘F4 pairs (the soak's failing actions: pane fronts itself on the new,
                // empty desktop); otherwise ⌃⌘← / ⌃⌘→ between a full and an empty desktop.
                let create = ProcessInfo.processInfo.environment["PANE_STRESS"] == "create"
                let chord: (Int, CGEventFlags) = create ? (round % 2 == 0 ? kVK_ANSI_D : kVK_F4, [.maskControl, .maskCommand])
                    : (round % 2 == 0 ? kVK_LeftArrow : kVK_RightArrow, [.maskControl, .maskCommand])
                _ = empty
                // PANE_STRESS_POINTER=over|away: rest the pointer on a window pane is about to move, or on an empty
                // spot (right of the cascade, below the menu bar). Hypothesis: moving a window under the pointer
                // makes the window server synthesize mouse events stamped with the modifiers held at that moment.
                switch ProcessInfo.processInfo.environment["PANE_STRESS_POINTER"] {
                case "over":
                    if let frame = f.standardWindows.compactMap(AX.frame).first(where: { $0.width > 100 && $0.minX < 1300 }) {
                        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
                    }
                case "away": CGWarpMouseCursorPosition(CGPoint(x: 1340, y: 60))
                default: break
                }
                // Warping suppresses mouse events for ~0.25 s: let that pass so it doesn't mask the effect.
                if ProcessInfo.processInfo.environment["PANE_STRESS_POINTER"] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                SyntheticKeyboard.press(chord.0, chord.1)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let held = SyntheticKeyboard.heldModifiers
                if !held.isEmpty {
                    let mask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                    let session = CGEventSource.flagsState(.combinedSessionState).intersection(mask).rawValue
                    var trace = ["0.3s:hid \(held.rawValue) session \(session)"]
                    for t in 1...10 {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        trace.append("\(String(format: "%.1f", 0.3 + Double(t) * 0.2))s:\(SyntheticKeyboard.heldModifiers.rawValue)")
                        if SyntheticKeyboard.heldModifiers.isEmpty { break }
                    }
                    stuck.append("round \(round) \(chord.1.rawValue): \(trace.joined(separator: " "))")
                    SyntheticKeyboard.releaseAllModifiers()
                }
            }
            Report.record("Modifiers after desktop chords", "pointer \(ProcessInfo.processInfo.environment["PANE_STRESS_POINTER"] ?? "-"), windows \(count): \(rounds) chords, \(stuck.count) left a modifier held: \(stuck.joined(separator: "; "))")
            #expect(stuck.isEmpty)
        }
    }
}
