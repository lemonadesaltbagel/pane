// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Soak (seed 11) step 2: ⌃⌘F, then macOS showed the user's full-screen Terminal Space and the fixture's windows
    /// were gone from AX. Replays the soak's opening and records Space, frontmost app and window state.
    @Suite("Experiments · ⌃⌘F Space jump")
    struct FullScreenJumpExperimentTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func controlCommandFJump() async throws {
            let pane = Process()
            pane.executableURL = Harness.binary
            pane.arguments = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID, "--desktop-scope", FixtureBundle.bundleID]
            let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fsjump.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            pane.standardError = try FileHandle(forWritingTo: logURL)
            try pane.run()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            // Fully started (it re-minimizes windows the Dock restart brought back before saying so).
            _ = await eventually(timeout: 10) { ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains("running (pid") }
            await settle(1.0)
            var notes: [String] = []
            for round in 0..<6 {
                let f = try await Fixture.launch(label: "J\(round)", windows: ["A", "B"].prefix(round % 2 + 1).map { $0 },
                                                 frame: CGRect(x: 100 + round * 40, y: 120, width: 520, height: 380))
                defer { f.quit() }
                func state(_ label: String) -> String {
                    let space = PrivateAPI.activeSpace().map { "\($0.kind)" } ?? "?"
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
                    let windows = AX.windows(of: f.pid)
                    let w = windows.first
                    return "\(label): space \(space), front \(front), AX windows \(windows.count), frame \(w.flatMap(AX.frame).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"), AXFullScreen \(w.map { (AX.get($0, "AXFullScreen") as Bool?) == true } ?? false)"
                }
                SyntheticKeyboard.press(kVK_LeftArrow, [.maskControl, .maskCommand])
                await settle(0.6)
                var line = ["round \(round)", state("after ⌃⌘←")]
                SyntheticKeyboard.press(kVK_ANSI_F, [.maskControl, .maskCommand])
                for t in [0.3, 1.0, 2.5] { await settle(t == 0.3 ? 0.3 : t - (t == 1.0 ? 0.3 : 1.0)); line.append(state("+\(t)s")) }
                SyntheticKeyboard.press(kVK_ANSI_F, [.maskControl, .maskCommand])
                await settle(1.0)
                line.append(state("after 2nd ⌃⌘F"))
                notes.append(line.joined(separator: " | "))
                if PrivateAPI.activeSpace()?.kind != .desktop, let wid = f.firstWindowServerWindow() { Focus.focus(wid: wid, pid: f.pid); await settle(1) }
            }
            let log = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("full screen") || $0.contains("convert") }.joined(separator: " / ")
            Report.record("⌃⌘F Space jump", notes.joined(separator: "\n  ") + "\n  agent: " + log)
        }
    }
}
