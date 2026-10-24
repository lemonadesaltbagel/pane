// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Onboarding's conflict step (E6): a running window manager is listed, and *Quit it* quits it. The fixture stands
    /// in for one (PANE_EXTRA_CONFLICTS adds its bundle ID to the known list).
    @Suite("Onboarding · conflicting apps")
    struct ConflictsTests {
        @Test func aRunningConflictIsListedAndQuits() async throws {
            setenv("PANE_EXTRA_CONFLICTS", FixtureBundle.bundleID, 1)
            defer { unsetenv("PANE_EXTRA_CONFLICTS") }
            let f = try await Fixture.launch(label: "C", windows: ["A"], activate: false)
            defer { f.quit() }
            let found = try #require(Conflicts.runningApps().first { $0.bundleID == FixtureBundle.bundleID })
            #expect(found.pid == f.pid && found.kind == .windowManager)
            #expect(Conflicts.quit(found))
            #expect(await eventually(timeout: 5) { !Conflicts.runningApps().contains { $0.bundleID == FixtureBundle.bundleID } })
        }
    }
}
