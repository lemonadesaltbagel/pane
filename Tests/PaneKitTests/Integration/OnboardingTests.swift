// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Phase 3: first-run onboarding (research/plan-settings-onboarding.md O1–O7), over Accessibility, in a test agent
    /// with a copy of your config. Test agents show it only with PANE_ONBOARDING=1.
    @Suite("Onboarding")
    struct OnboardingTests {
        typealias S = SettingsWindowTests
        static func log() -> String { S.log() }

        static func window(_ pid: pid_t) -> AXUIElement? {
            AX.windows(of: pid).first { (AX.get($0, "AXIdentifier") as String?) == "pane.onboarding" }
        }
        static func find(_ pid: pid_t, _ id: String) -> AXUIElement? { window(pid).flatMap { S.element($0, id) } }
        static func onStep(_ pid: pid_t, _ step: String) -> Bool { find(pid, "onboarding.step.\(step)") != nil }

        /// Continue, then wait for `step`.
        static func advance(_ pid: pid_t, to step: String) async -> Bool {
            guard let button = find(pid, "onboarding.continue") else { return false }
            AX.perform(button, kAXPressAction)
            return await eventually(timeout: 3) { onStep(pid, step) }
        }

        static func value(_ pid: pid_t, _ id: String) -> String? { find(pid, id).flatMap { AX.get($0, kAXValueAttribute) as String? } }

        /// An agent that shows onboarding; `env` is set for its launch only.
        static func launch(env: [String: String] = [:], _ configure: (@MainActor (SettingsStore) -> Void)? = nil) async throws -> (Fixture, Process) {
            let f = try await Fixture.launch(label: "O", windows: ["A"], frame: CGRect(x: 120, y: 160, width: 360, height: 260))
            let all = env.merging(["PANE_ONBOARDING": "1"]) { a, _ in a }
            for (k, v) in all { setenv(k, v, 1) }
            defer { for k in all.keys { unsetenv(k) } }
            let pane = try Harness.launchAgent { store in
                try? store.set(PaneSettings.onboardingDone, 0)
                store.applyShortcutPreset("mac")
                try? store.set(PaneSettings.launchAtLogin, false)
                configure?(store)
            }
            return (f, pane)
        }

        /// O1, O3, O4, O7: shown at first run; every step in order; Start at login
        /// writes the login item (a test folder); Finish writes the version and closes, with no restart when nothing
        /// needs one; "Show welcome again" brings it back.
        @Test func firstRunWalkthrough() async throws {
            let loginDir = FileManager.default.temporaryDirectory.appendingPathComponent("pane-onboarding-login-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: loginDir) }
            let (f, pane) = try await Self.launch(env: ["PANE_LAUNCH_AGENTS_DIR": loginDir.path])
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            let shown = await eventually(timeout: 8) { Self.onStep(pid, "welcome") }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            let accessibility = await Self.advance(pid, to: "accessibility")
            let axGranted = Self.value(pid, "onboarding.accessibility.status") == "granted"
            let previews = await Self.advance(pid, to: "previews")
            let previewState = Self.value(pid, "onboarding.previews.status") ?? "-"
            // The Free build has no keyboard step (the Windows keyboard is pane Pro's).
            let conflicts = await Self.advance(pid, to: "conflicts")
            let changes = await Self.advance(pid, to: "changes")
            let promise = Self.find(pid, "onboarding.promise") != nil
            let login = await Self.advance(pid, to: "login")
            if let toggle = Self.find(pid, "onboarding.login") { AX.perform(toggle, kAXPressAction) }
            let plist = loginDir.appendingPathComponent("\(LoginItem.label).plist")
            let loginOn = await eventually(timeout: 3) { FileManager.default.fileExists(atPath: plist.path) }
            if let toggle = Self.find(pid, "onboarding.login") { AX.perform(toggle, kAXPressAction) }
            let loginOff = await eventually(timeout: 3) { !FileManager.default.fileExists(atPath: plist.path) }
            if let finish = Self.find(pid, "onboarding.continue") { AX.perform(finish, kAXPressAction) }
            let closed = await eventually(timeout: 3) { Self.window(pid) == nil }
            let done = await eventually(timeout: 2) { S.stored(PaneSettings.onboardingDone.id) as? Int == Onboarding.version }
            await settle(1)
            let noRestart = pane.isRunning && Self.log().contains("onboarding finished") && !Self.log().contains("restarting")
            // Show welcome again (Settings ▸ Advanced).
            _ = await S.open("advanced", pid)
            if let again = S.find(pid, "settings.showWelcome") { AX.perform(again, kAXPressAction) }
            let again = await eventually(timeout: 3) { Self.onStep(pid, "welcome") }
            let note = "shown \(shown); steps: accessibility \(accessibility) (granted \(axGranted)), previews \(previews) (\(previewState)), conflicts \(conflicts), changes \(changes) (promise \(promise)), login \(login) (on \(loginOn), off \(loginOff)); finish: closed \(closed), version written \(done), no restart \(noRestart); Show welcome again \(again)"
            Report.record("Onboarding · first run", note)
            print("ONBOARDING-O1: " + note)
            #expect(shown && accessibility && axGranted && previews)
            #expect(conflicts && changes && promise && login && loginOn && loginOff && closed && done && noRestart && again)
            #expect(["granted", "missing"].contains(previewState))
        }

        /// O2: without Accessibility the step is current, Continue waits; a grant completes it within a second, no relaunch.
        @Test func accessibilityStepWaitsForTheGrant() async throws {
            let fake = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fake-permissions-onboarding")
            try "accessibility=missing".write(to: fake, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fake) }
            let (f, pane) = try await Self.launch(env: ["PANE_FAKE_PERMISSIONS_FILE": fake.path])
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            let shown = await eventually(timeout: 8) { Self.onStep(pid, "welcome") }
            let waiting = await eventually(timeout: 3) { Self.log().contains("waiting for Accessibility") }
            let step = await Self.advance(pid, to: "accessibility")
            let missing = Self.value(pid, "onboarding.accessibility.status") == "missing"
            let grantButton = Self.find(pid, "onboarding.accessibility.grant") != nil
            let blocked = Self.find(pid, "onboarding.continue").flatMap { AX.get($0, kAXEnabledAttribute) as Bool? } == false
            try "accessibility=granted".write(to: fake, atomically: true, encoding: .utf8)
            let start = Date()
            let granted = await eventually(timeout: 3) { Self.value(pid, "onboarding.accessibility.status") == "granted" }
            let seconds = Date().timeIntervalSince(start)
            let unblocked = Self.find(pid, "onboarding.continue").flatMap { AX.get($0, kAXEnabledAttribute) as Bool? } == true
            let started = await eventually(timeout: 8) { Self.log().contains("Accessibility granted: starting") }
            let samePane = pane.isRunning
            let note = String(format: "shown %@, agent waiting %@; step %@: missing %@, Allow button %@, Continue blocked %@; grant → granted %@ in %.1f s, Continue enabled %@, services started %@, same process %@",
                              "\(shown)", "\(waiting)", "\(step)", "\(missing)", "\(grantButton)", "\(blocked)", "\(granted)", seconds, "\(unblocked)", "\(started)", "\(samePane)")
            Report.record("Onboarding · Accessibility", note)
            print("ONBOARDING-O2: " + note)
            #expect(shown && waiting && step && missing && grantButton && blocked && granted && seconds < 1.5 && unblocked && started && samePane)
        }

        /// O5, O6: a running conflicting app is listed and Quit ends it; the changes list equals `SystemChanges.describe`,
        /// a switch turns its change off; finishing restarts pane so the choice applies.
        @Test func conflictsAndChanges() async throws {
            let (f, pane) = try await Self.launch(env: ["PANE_EXTRA_CONFLICTS": FixtureBundle.bundleID]) { store in
                try? store.set(PaneSettings.replaceDock, true)
                try? store.set(PaneSettings.autoHide, false)
            }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await eventually(timeout: 8) { Self.onStep(pid, "welcome") }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            for step in ["accessibility", "previews"] { _ = await Self.advance(pid, to: step) }
            let conflicts = await Self.advance(pid, to: "conflicts")
            let listed = await eventually(timeout: 3) { Self.find(pid, "onboarding.conflict.\(FixtureBundle.bundleID)") != nil }
            if let quit = Self.find(pid, "onboarding.conflict.\(FixtureBundle.bundleID).quit") { AX.perform(quit, kAXPressAction) }
            let quitIt = await eventually(timeout: 5) { f.app.isTerminated }
            let changes = await Self.advance(pid, to: "changes")
            let expected = MainActor.assumeIsolatedOrSync { SystemChanges.describe(SettingsStore(url: Harness.testConfig)).map(\.setting) }
            let rows = expected.filter { Self.find(pid, "onboarding.change.\($0)") != nil }
            let allRows = !expected.isEmpty && rows.count == expected.count
            if let dock = Self.find(pid, "onboarding.change.\(PaneSettings.replaceDock.id)") { AX.perform(dock, kAXPressAction) }
            let dockOff = await eventually(timeout: 2) { S.stored(PaneSettings.replaceDock.id) as? Bool == false }
            let listFollows = MainActor.assumeIsolatedOrSync {
                !SystemChanges.describe(SettingsStore(url: Harness.testConfig)).contains { $0.setting == PaneSettings.replaceDock.id }
            }
            let rowStays = Self.find(pid, "onboarding.change.\(PaneSettings.replaceDock.id)") != nil
            _ = await Self.advance(pid, to: "login")
            var newPID: pid_t = 0
            defer { stopAgent(pid: newPID) }
            if let finish = Self.find(pid, "onboarding.continue") { AX.perform(finish, kAXPressAction) }
            let restarted = await eventually(timeout: 15) {
                let p = Harness.agentPID(fromLog: Self.log()); if p > 0 && p != pid { newPID = p; return true }; return false
            }
            let note = "conflicts step \(conflicts): fixture listed \(listed), Quit ended it \(quitIt); changes step \(changes): rows \(rows.count)/\(expected.count) \(expected); Dock switch off → setting off \(dockOff), describe drops it \(listFollows), row stays \(rowStays); finish restarted pane \(restarted)"
            Report.record("Onboarding · conflicts and changes", note)
            print("ONBOARDING-O5O6: " + note)
            #expect(conflicts && listed && quitIt && changes && allRows && dockOff && listFollows && rowStays && restarted)
            stopAgent(pid: newPID)
            _ = await eventually(timeout: 10) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() } != 48 }
        }

        /// No welcome once the version is written.
        @Test func noWelcomeOnceDone() async throws {
            let (f, pane) = try await Self.launch { try? $0.set(PaneSettings.onboardingDone, Onboarding.version) }
            defer { stopAgent(pane); f.quit() }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            await settle(1.5)
            let none = Self.window(pane.processIdentifier) == nil && !Self.log().contains("onboarding shown")
            Report.record("Onboarding · not again", "no welcome when done \(none)")
            #expect(none)
        }

        /// The look of each step, saved to test-results/previews/onboarding-<step>.png (for review by eye).
        @Test func stepsLook() async throws {
            guard PreviewGate.enabled else { return }
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await eventually(timeout: 8) { Self.onStep(pid, "welcome") }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            var saved: [String] = []
            let steps = ["welcome", "accessibility", "previews", "conflicts", "changes", "login"]
            for (i, step) in steps.enumerated() {
                if i > 0 { _ = await Self.advance(pid, to: step) }
                await settle(0.6)
                guard let frame = Self.window(pid).flatMap(AX.frame),
                      let wid = WindowServer.windows().first(where: { $0.pid == pid && Geometry.approximatelyEqual($0.bounds, frame, tolerance: 4) })?.id,
                      let (image, _) = await PreviewClient.thumbnail(wid, maxDimension: 2000) else { continue }
                saved.append(PreviewGate.save(image, "onboarding-\(step)").lastPathComponent)
            }
            Report.record("Onboarding · look", saved.joined(separator: ", "))
            #expect(saved.count == steps.count)
        }
    }
}
