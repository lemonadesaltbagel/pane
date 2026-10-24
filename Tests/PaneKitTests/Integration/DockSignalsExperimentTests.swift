// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Experiment (PANE_STRESS=1): what the Dock exposes per app tile through AX — the badge (unread count) and the
    /// attention bounce — so the taskbar can mirror them (the Dock runs under pane's bar).
    @Suite("Experiments · Dock signals")
    struct DockSignalsExperimentTests {
        static func tile(_ name: String) -> AXUIElement? {
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
            for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for t in (AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] where AX.title(t) == name { return t }
            }
            return nil
        }

        static func dump(_ e: AXUIElement) -> String {
            var names: CFArray?
            AXUIElementCopyAttributeNames(e, &names)
            return ((names as? [String]) ?? []).map { n in
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(e, n as CFString, &v)
                return "\(n)=\(v.map { "\($0)".prefix(60) } ?? "nil")"
            }.joined(separator: " | ")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func badgeAndAttention() async throws {
            let f = try await Fixture.launch(label: "B", windows: ["A"], extraArguments: ["--badge", "7", "--attention", "3"], frame: CGRect(x: 160, y: 200, width: 400, height: 280))
            defer { f.quit() }
            let other = try await Fixture.launch(label: "O", windows: ["A"], frame: CGRect(x: 600, y: 200, width: 400, height: 280))
            defer { other.quit() }
            Focus.focus(try other.requireWindow("A"), using: .skyLight) // B in the background: attention bounces
            await settle(1.0)
            let t = Self.tile("PaneFixture")
            print("DOCKTILE (badge 7): \(t.map(Self.dump) ?? "no tile")")
            var samples: [String] = []
            let start = Date()
            while Date().timeIntervalSince(start) < 4 {
                // Several PaneFixture tiles may exist (two instances): sample all.
                guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { break }
                var row: [String] = []
                for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    for tile in (AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] where AX.title(tile) == "PaneFixture" {
                        let status: String = AX.get(tile, "AXStatusLabel") ?? "-"
                        row.append("y \(AX.frame(tile).map { Int($0.minY) } ?? -1) status \(status)")
                    }
                }
                samples.append(String(format: "%.1f", Date().timeIntervalSince(start)) + " " + row.joined(separator: ", "))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            print("DOCKATTENTION:\n" + samples.joined(separator: "\n"))
            if let t = Self.tile("PaneFixture") { print("DOCKTILE (after attention): \(Self.dump(t))") }
        }
    }
}
