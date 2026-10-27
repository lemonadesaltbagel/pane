// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// T1: badges, progress and attention on the taskbar, read from the Dock.
    @Suite("Taskbar · badges and attention")
    struct TaskbarSignalsTests {
        /// The taskbar button's accessibility value ("badge 7; needs attention").
        static func buttonValue(_ pid: pid_t, _ prefix: String) -> String? {
            guard let bar = AX.windows(of: pid).first(where: { AX.title($0) == "Pane Taskbar" }) else { return nil }
            func find(_ e: AXUIElement) -> AXUIElement? {
                if AX.role(e) == kAXButtonRole, (AX.title(e) ?? "").hasPrefix(prefix) { return e }
                for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let f = find(c) { return f } }
                return nil
            }
            guard let button = find(bar) else { return nil }
            return (AX.get(button, kAXValueAttribute) as String?) ?? ""
        }

        @Test func badgeAndAttentionShowOnTheButton() async throws {
            let badgeFile = URL(fileURLWithPath: "/tmp/pane-fixture-B.badge")
            try? FileManager.default.removeItem(at: badgeFile)
            let f = try await Fixture.launch(label: "B", windows: ["A"], extraArguments: ["--badge", "7", "--attention", "6"], frame: CGRect(x: 160, y: 200, width: 400, height: 280))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            // Something else in front (a Finder window), so the fixture's attention request bounces.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pane-signals-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            NSWorkspace.shared.open(folder)
            let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
            defer {
                if let w = AX.windows(of: finderPID).first(where: { AX.title($0) == folder.lastPathComponent }), let close = AX.button(w, kAXCloseButtonAttribute) { AX.perform(close, kAXPressAction) }
            }
            func value() -> String { Self.buttonValue(pane.processIdentifier, "group: PaneFixture") ?? "(no button)" }
            let badge7 = await eventually(timeout: 6) { value().contains("badge 7") }
            let attention = await eventually(timeout: 10) { value().contains("needs attention") }
            try "12".write(to: badgeFile, atomically: true, encoding: .utf8)
            let badge12 = await eventually(timeout: 4) { value().contains("badge 12") }
            // A picture of the button with its badge and the orange attention look.
            var picture = ""
            if PreviewGate.enabled, let bar = WindowServer.windows().first(where: { $0.pid == pane.processIdentifier && $0.bounds.height == 48 }),
               let (image, _) = await PreviewClient.thumbnail(bar.id, maxDimension: 3000) {
                picture = PreviewGate.save(image, "taskbar-signals").lastPathComponent
            }
            // Switching to the app clears the attention (Windows); clearing the badge removes it.
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            let cleared = await eventually(timeout: 4) { !value().contains("needs attention") }
            try " ".write(to: badgeFile, atomically: true, encoding: .utf8)
            let badgeGone = await eventually(timeout: 4) { !value().contains("badge") }
            let note = "badge 7 shown \(badge7); attention shown \(attention); badge changed to 12 \(badge12); attention cleared on switching to the app \(cleared); badge removed \(badgeGone); picture \(picture)"
            Report.record("Taskbar · badges and attention", note)
            print("SIGNALS: " + note + " (last value: \(value()))")
            #expect(badge7 && badge12 && badgeGone)
            #expect(attention && cleared)
        }
    }
}
