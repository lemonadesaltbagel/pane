// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Start over Accessibility in a test agent: its Start file is a test copy, the fixture app is indexed
/// (PANE_START_APP_ROOTS) so launching never opens one of your apps, and power actions go to a fake (PANE_FAKE_POWER).
public protocol StartUIHarness {}

public extension StartUIHarness {
    static func log() -> String { SettingsUI.log() }
    static var startFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-start-menu.json") }
    static var powerFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-power.txt") }
    static func window(_ pid: pid_t) -> AXUIElement? {
        AX.windows(of: pid).first { (AX.get($0, "AXIdentifier") as String?) == "pane.start" || AX.title($0) == "Start" }
    }
    static func find(_ pid: pid_t, _ id: String) -> AXUIElement? { window(pid).flatMap { SettingsUI.element($0, id) } }
    static func shown(_ pid: pid_t) -> Bool { window(pid) != nil }
    static func open(_ pid: pid_t) async -> Bool {
        if !shown(pid) { _ = AgentLink.send("start:toggle") }
        return await eventually(timeout: 3) { shown(pid) }
    }
    static func powerLog() -> [String] {
        ((try? String(contentsOf: powerFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// Fixture in front, then a test agent with Start's test files; `pins` written to the Start file first.
    static func launch(pins: [PinnedItem]? = nil, _ configure: (@MainActor (SettingsStore) -> Void)? = nil) async throws -> (Fixture, Process) {
        let f = try await Fixture.launch(label: "St", windows: ["A"], frame: CGRect(x: 120, y: 160, width: 380, height: 260))
        try? FileManager.default.removeItem(at: startFile)
        try? FileManager.default.removeItem(at: powerFile)
        if let pins {
            var data = StartData()
            data.pinned = pins
            data.indexed = true
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(data).write(to: startFile)
        }
        let env = ["PANE_START_FILE": startFile.path, "PANE_FAKE_POWER": powerFile.path,
                   "PANE_START_APP_ROOTS": FixtureBundle.url.deletingLastPathComponent().path]
        for (k, v) in env { setenv(k, v, 1) }
        defer { for k in env.keys { unsetenv(k) } }
        let pane = try Harness.launchAgent { store in
            try? store.set(PaneSettings.startMenu, "pane")
            try? store.set(PaneSettings.alignment, "center")
            configure?(store)
        }
        _ = await eventually(timeout: 10) { log().contains("running (pid") }
        await settle(1.5)
        return (f, pane)
    }
    static func capture(_ pid: pid_t, _ name: String) async -> String? {
        guard PreviewGate.enabled, let frame = window(pid).flatMap(AX.frame),
              let wid = WindowServer.windows().first(where: { $0.pid == pid && Geometry.approximatelyEqual($0.bounds, frame, tolerance: 4) })?.id,
              let (image, _) = await PreviewClient.thumbnail(wid, maxDimension: 2000) else { return nil }
        return PreviewGate.save(image, name).lastPathComponent
    }
}
