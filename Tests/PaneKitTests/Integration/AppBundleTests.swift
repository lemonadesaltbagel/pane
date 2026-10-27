// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// pane as an app (`scripts/make-app.sh` builds `.build/app/pane.app`), launched through LaunchServices with the test
    /// isolation: what macOS lets the app do, compared with the same binary run from Terminal; one agent at a time; and
    /// quitting restores what it changed. Skipped until the app is built.
    @Suite("pane as an app", .enabled(if: AppUnderTest.exists(named: "pane"), "build it first: scripts/make-app.sh"))
    struct AppBundleTests {
        static let app = AppUnderTest.url(named: "pane")

        static func describe(_ report: [String: String]) -> String {
            ["accessibility", "screenRecording", "automation.restart", "loginItem", "previewHelper"].map { "\($0) \(report[$0] ?? "-")" }.joined(separator: ", ")
        }

        /// R3 + R5: the report as the app, and as Terminal's child.
        @Test func reportAsTheAppAndFromTerminal() async throws {
            let asApp = AppUnderTest.report(Self.app)
            let fromTerminal = AppUnderTest.report(Self.app, fromTerminal: true)
            let note = "as the app: version \(asApp["version"] ?? "-"), \(Self.describe(asApp)) · from Terminal: \(Self.describe(fromTerminal))"
            Report.record("App · what macOS lets it do", note)
            print("APP-REPORT: " + note)
            #expect(asApp["app"] == "yes" && asApp["bundleID"] == "dev.pane.app")
            #expect(asApp["version"].map { $0 != "development build" } ?? false)
            #expect(asApp["previewHelper"]?.hasPrefix(Self.app.path) == true, "the helper inside the app is used")
            #expect(!fromTerminal.isEmpty)
        }

        /// R4: it runs as the app; a second launch hands over (opens Settings) instead of starting a second pane;
        /// quitting puts the Dock back.
        @Test func oneAgentAndQuit() async throws {
            let dockBefore = DockReservation.bottomInset()
            let running = try #require(await AppUnderTest.launch(Self.app), "the app didn't start")
            await settle(5)
            let asApp = running.bundleURL?.standardizedFileURL == Self.app.standardizedFileURL && running.activationPolicy == .accessory
            AppUnderTest.open(Self.app, wait: true, arguments: [], fakeMissing: true) // a second launch
            let others = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == Self.app.standardizedFileURL && !$0.isTerminated }
            let handedOver = await eventually(timeout: 4) { SettingsUI.window(running.processIdentifier) != nil }
            let trusted = AX.isTrusted // this runner's, for the record
            let quit = await AppUnderTest.quit(running)
            let dockBack = await eventually(timeout: 6) { DockReservation.bottomInset() == dockBefore }
            let log = AppUnderTest.logText().split(separator: "\n").filter { $0.contains("[pane]") }.prefix(6).joined(separator: " / ")
            let note = "runs as the app (no Dock icon) \(asApp); a second launch left \(others.count) running and opened Settings \(handedOver); quit \(quit), Dock back \(dockBack) (runner trusted \(trusted)); log: \(log)"
            Report.record("App · one agent, quit", note)
            print("APP-RUN: " + note)
            #expect(asApp && others.count == 1 && handedOver && quit && dockBack)
        }
    }
}
