// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Hypothesis for the soak's stuck modifiers: a SkyLight focus (front process + synthetic make-key record with
    /// zero flags) made while a modifier is held confuses the synthetic modifier state.
    @Suite("Experiments · focus while a modifier is held")
    struct ModifierFocusExperimentTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func focusWhileModifierHeld() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A", "B"])
            defer { f.quit() }
            let a = try f.requireWindow("A"), b = try f.requireWindow("B")
            var results: [String: Int] = [:]
            for (name, focus) in [("skyLight", { (w: AXUIElement) in _ = Focus.focus(w, using: .skyLight) }),
                                  ("publicActivate", { (w: AXUIElement) in _ = Focus.focus(w, using: .publicActivate) }),
                                  ("frontWithoutWindows", { (_: AXUIElement) in _ = Focus.frontWithoutWindows(pid: f.pid) })] {
                var stuck = 0
                for round in 0..<20 {
                    SyntheticKeyboard.holdModifiers([.maskControl, .maskCommand])
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    focus(round % 2 == 0 ? a : b)
                    SyntheticKeyboard.releaseModifiers([.maskControl, .maskCommand])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !SyntheticKeyboard.heldModifiers.isEmpty { stuck += 1; SyntheticKeyboard.releaseAllModifiers() }
                }
                results[name] = stuck
            }
            Report.record("Focus while a modifier is held", "stuck modifiers per 20 focuses with ⌃⌘ held: \(results.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }
    }
}
