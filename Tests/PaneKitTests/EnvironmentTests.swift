// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import CoreGraphics
import Testing
import PaneKit
import PaneTestKit

/// What this Mac allows. Failures here explain failures elsewhere.
@Suite("Environment")
struct EnvironmentTests {
    @Test func accessibilityIsGranted() {
        Report.record("Permissions", "Accessibility=\(AX.isTrusted), ScreenRecording=\(Capture.hasScreenRecording), " +
            "ListenEvents=\(CGPreflightListenEventAccess()), PostEvents=\(CGPreflightPostEventAccess())")
        #expect(AX.isTrusted, "Grant Accessibility to your terminal in System Settings ▸ Privacy & Security ▸ Accessibility")
    }

    @Test func privateSymbolsResolve() {
        let availability = PrivateAPI.availability
        Report.record("Private symbols", availability.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        for (name, present) in availability {
            #expect(present, "\(name) is missing on this macOS")
        }
    }
}
