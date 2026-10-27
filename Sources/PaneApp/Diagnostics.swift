// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices
import PaneKit

/// `pane --report <file>`: what this copy of pane is and what macOS lets it do, as JSON. Run through LaunchServices
/// (`open -a pane.app --args --report …`), it reports for the app itself, not for Terminal. It names no windows and no
/// other apps. Extensions add their own entries (`PaneExtension.diagnostics`).
public enum Diagnostics {
    @MainActor public static func report(extensions: [PaneExtension]) async -> [String: String] {
        var entries: [String: String] = [
            "version": AppBundle.version ?? "development build",
            "app": AppBundle.isApp ? "yes" : "no (a bare binary)",
            "bundle": Bundle.main.bundlePath,
            "bundleID": Bundle.main.bundleIdentifier ?? "-",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": AXIsProcessTrusted() ? "granted" : "not granted",
            "screenRecording": CGPreflightScreenCaptureAccess() ? "granted" : "not granted",
            "previewHelper": FileManager.default.fileExists(atPath: PreviewClient.helperURL.path) ? PreviewClient.helperURL.path : "missing",
            "automation.restart": Power.automationStatus(),
            "loginItem": LoginItem.status,
        ]
        for e in extensions { entries.merge(await e.diagnostics()) { _, new in new } }
        return entries
    }

    /// Writes the report to `path` and exits.
    @MainActor static func write(to path: String, extensions: [PaneExtension]) async -> Never {
        let entries = await report(extensions: extensions)
        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        do { try data.write(to: URL(fileURLWithPath: path)); exit(0) } catch { log("report: couldn't write \(path): \(error)"); exit(1) }
    }
}
