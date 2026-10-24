// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Phase 1 of the settings/onboarding plan: pane without Accessibility, a grant and a revoke while running (faked),
    /// and starting pane a second time (it opens the running pane's Settings).
    @Suite("Agent · permissions and second start", .serialized)
    struct AgentLifecycleTests {
        static func log() -> String { (try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "" }
        static func barUp(_ pid: pid_t) -> Bool { WindowServer.windows().contains { $0.pid == pid && $0.bounds.height == 48 } }

        @Test func waitsForAccessibilityThenStartsAndStopsOnRevoke() async throws {
            let fake = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fake-permissions")
            try "accessibility=missing".write(to: fake, atomically: true, encoding: .utf8)
            setenv("PANE_FAKE_PERMISSIONS_FILE", fake.path, 1)
            defer { unsetenv("PANE_FAKE_PERMISSIONS_FILE"); try? FileManager.default.removeItem(at: fake) }
            // A window on the desktop: from a full-screen Space (Terminal's, often) the taskbar rightly stays hidden.
            let f = try await Fixture.launch(label: "G", windows: ["A"], frame: CGRect(x: 220, y: 220, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let waiting = pane.isRunning && Self.log().contains("waiting for Accessibility") && !Self.barUp(pane.processIdentifier)
            let dockUntouched = MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() } != 48
            try "accessibility=granted".write(to: fake, atomically: true, encoding: .utf8)
            let started = await eventually(timeout: 10) { Self.log().contains("Accessibility granted: starting") && Self.barUp(pane.processIdentifier) }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            await settle(1)
            try "accessibility=missing".write(to: fake, atomically: true, encoding: .utf8)
            let stopped = await eventually(timeout: 4) { Self.log().contains("Accessibility revoked") }
            let stillUp = pane.isRunning && Self.barUp(pane.processIdentifier)
            let note = "without Accessibility: stays up, no taskbar \(waiting), Dock untouched \(dockUntouched); granted → started \(started); revoked → handling stopped \(stopped), taskbar still up \(stillUp)"
            Report.record("Agent · permissions", note)
            print("PERMS: " + note)
            #expect(waiting && dockUntouched && started && stopped && stillUp)
        }

        @Test func secondStartOpensSettings() async throws {
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            func second(_ args: [String]) async -> (Int32, String) {
                let p = Process()
                p.executableURL = Harness.binary
                p.arguments = args
                var env = ProcessInfo.processInfo.environment; env["PANE_DEFAULTS_SUITE"] = "pane-test-agent"
                p.environment = env
                let err = Pipe(); p.standardError = err
                try? p.run()
                let deadline = Date().addingTimeInterval(5)
                while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                if p.isRunning { p.terminate() }
                return (p.terminationStatus, String(data: err.fileHandleForReading.availableData, encoding: .utf8) ?? "")
            }
            let (plainStatus, plainOut) = await second([])
            let opened = await eventually(timeout: 3) { Self.log().contains("open settings") }
            let (pageStatus, _) = await second(["--open-settings", "taskbar"])
            let openedPage = await eventually(timeout: 3) { Self.log().contains("open settings (taskbar)") }
            let oneAgent = pane.isRunning
            let note = "second start: exit \(plainStatus) (\(plainOut.trimmingCharacters(in: .whitespacesAndNewlines))), running pane opened Settings \(opened); --open-settings taskbar: exit \(pageStatus), opened that page \(openedPage); the first pane still the only one \(oneAgent)"
            Report.record("Agent · second start", note)
            print("SECOND: " + note)
            #expect(plainStatus == 0 && opened && pageStatus == 0 && openedPage && oneAgent)
        }

        /// E3: `pane --restart` hands over: a new pane takes over without restoring and re-applying the Dock (same Dock
        /// process, the reserved space never moves), and it reads the changed setting.
        @Test func restartHandsOverWithoutDockFlicker() async throws {
            let pane = try Harness.launchAgent()
            var newPID: pid_t = 0
            defer {
                stopAgent(pane)
                if newPID > 0 { stopAgent(pid: newPID) }
            }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            await settle(1.5)
            let dockBefore = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            await MainActor.run { ReservedSettingsTests.change { try? $0.set(PaneSettings.combineButtons, "never") } }
            let pendingLogged = await eventually(timeout: 4) { Self.log().contains("taskbar.combineButtons changed; takes effect when pane restarts") }
            let p = Process()
            p.executableURL = Harness.binary
            p.arguments = ["--restart"]
            try p.run()
            // Watch the reserved space while the restart happens.
            var insets: Set<Int> = []
            let start = Date()
            var tookOver = false
            while Date().timeIntervalSince(start) < 12 {
                insets.insert(Int(MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() }))
                if Self.log().components(separatedBy: "running (pid").count >= 3 { tookOver = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let oldGone = await eventually(timeout: 4) { !pane.isRunning }
            newPID = NSWorkspace.shared.runningApplications.first { $0.executableURL?.path == Harness.binary.path && $0.processIdentifier != pane.processIdentifier }?.processIdentifier
                ?? Self.pid(fromLog: Self.log())
            let dockAfter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            let adopted = Self.log().contains("taking over from the previous pane")
            await settle(2)
            let neverButtons = Harness.taskbarButtons(newPID).contains { $0.0.hasPrefix("pin: ") } // the bar is up
            let note = "pending change logged \(pendingLogged); restart: old pane gone \(oldGone), new pane took over \(tookOver) (pid \(newPID)), kept system settings \(adopted); Dock process the same \(dockBefore == dockAfter); reserved space during the restart \(insets.sorted()); new bar up \(neverButtons)"
            Report.record("Agent · restart handover", note)
            print("RESTARTPANE: " + note)
            #expect(pendingLogged && oldGone && tookOver && adopted && dockBefore == dockAfter && insets == [48])
            // Quit the new pane: it restores everything as usual.
            if newPID > 0 { stopAgent(pid: newPID); newPID = 0 }
            _ = await eventually(timeout: 10) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() } != 48 }
        }

        /// E8: while the settings window records a shortcut, pane's keys stand down (⌥Tab doesn't open Alt+Tab) and
        /// macOS's ⌘Tab is off; afterwards both are back.
        @Test func recordingModeLetsKeysThrough() async throws {
            let f = try await Fixture.launch(label: "Q", windows: ["A", "B"], frame: CGRect(x: 200, y: 220, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane); SyntheticKeyboard.releaseAllModifiers(); _ = AgentLink.send("recording:off") }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            await settle(2)
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            let on = AgentLink.send("recording:on")
            _ = await eventually(timeout: 3) { Self.log().contains("recording a shortcut") }
            let systemOffWhileRecording = PrivateAPI.isSymbolicHotKeyEnabled(.commandTab) == false
            let during = await ReservedSettingsTests.peekSwitcher(pane, front: f, wait: 0.3) ?? [:]
            _ = AgentLink.send("recording:off")
            _ = await eventually(timeout: 3) { Self.log().contains("recording ended") }
            let systemBack = PrivateAPI.isSymbolicHotKeyEnabled(.commandTab) == true
            // ⌥Tab went to the apps meanwhile (AltTab, if it runs, opened its own): back to the fixture first.
            try? await Task.sleep(nanoseconds: 800_000_000)
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            let front = await eventually(timeout: 3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }
            let after = await ReservedSettingsTests.peekSwitcher(pane, front: f, wait: 0.3) ?? [:]
            if after.isEmpty { print("RECORDING after: fixture in front \(front), frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")") }
            let note = "recording on \(on): Alt+Tab opened \(!during.isEmpty), macOS ⌘Tab off \(systemOffWhileRecording); recording off: macOS ⌘Tab back \(systemBack), Alt+Tab opens \(!after.isEmpty)"
            Report.record("Agent · shortcut recording", note)
            print("RECORDING: " + note)
            #expect(on && during.isEmpty && systemOffWhileRecording && systemBack && !after.isEmpty)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }

        static func pid(fromLog log: String) -> pid_t {
            guard let range = log.range(of: "running (pid ", options: .backwards) else { return 0 }
            return pid_t(log[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
    }
}
