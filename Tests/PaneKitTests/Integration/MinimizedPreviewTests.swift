// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Previews of real minimized windows (read only: nothing is moved). Gated: PANE_REAL_PREVIEWS=1, because it depends
    /// on which of your windows are minimized right now.
    @Suite("Experiments · minimized previews")
    struct MinimizedPreviewTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_REAL_PREVIEWS"] != nil)) func realMinimizedWindows() async throws {
            try #require(PreviewGate.enabled, "PanePreview helper not available")
            let windows = WindowInventory().refreshNow().filter(\.isMinimized)
            var rows: [String] = []
            for w in windows.prefix(8) {
                let start = Date()
                let result = await PreviewClient.thumbnail(w.id, maxDimension: 440)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let variety = result.map { PreviewGate.colorVariety($0.0) } ?? -1
                if let (image, _) = result { _ = PreviewGate.save(image, "minimized-\(w.id)") }
                rows.append("\(w.appName) “\(w.title.prefix(30))” wid \(w.id): \(result.map { "\($0.0.width)x\($0.0.height) via \($0.1.rawValue), colours \(variety)" } ?? "nil") in \(ms) ms")
            }
            print("MINIMIZED:\n" + rows.joined(separator: "\n"))
            Report.record("Minimized previews (real)", rows.joined(separator: "; "))
        }
    }
}
