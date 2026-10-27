// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// Visual check of the taskbar and its pop-ups (images in test-results/previews/, looked at by eye): glass over the
    /// wallpaper like the menu bar, Windows 11 buttons (backplate, running pill), centred and left alignment.
    @Suite("Taskbar look")
    struct TaskbarLookTests {
        @Test func captureTaskbarAndPopups() async throws {
            try #require(PreviewGate.enabled, "PanePreview helper not available")
            var apps: [Fixture] = []
            for label in ["G1", "G2"] {
                apps.append(try await Fixture.launch(label: label, windows: ["A", "B"], frame: CGRect(x: 120, y: 160, width: 420, height: 300)))
            }
            defer { apps.forEach { $0.quit() } }
            Focus.focus(try apps[0].requireWindow("A"), using: .skyLight)
            _ = await eventually { PrivateAPI.activeSpace()?.kind == .desktop }
            let inventory = WindowInventory()
            let pids = Set(apps.map(\.pid))
            let bar = await MainActor.run { () -> TaskbarPanel in
                let bar = TaskbarPanel(inventory: inventory, height: 48, pinned: ["com.apple.finder", "com.apple.Safari"], mode: .always)
                bar.includedPIDs = pids.union(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").map(\.processIdentifier))
                bar.show()
                return bar
            }
            defer { MainActor.assumeIsolatedOrSync { bar.close() } }
            for _ in 0..<20 {
                let windows = inventory.refreshNow()
                await MainActor.run { bar.update(windows) }
                if await MainActor.run(body: { bar.items.count >= 2 }) { break }
                await settle(0.2)
            }
            await settle(2.5) // the wallpaper slice is captured asynchronously
            var notes: [String] = []
            func capture(_ panel: NSWindow, _ name: String, max: CGFloat = 3000) async {
                let wid = await MainActor.run { CGWindowID(Swift.max(0, panel.windowNumber)) }
                if let (image, _) = await PreviewClient.thumbnail(wid, maxDimension: max) {
                    notes.append("\(name) \(image.width)x\(image.height) colours \(PreviewGate.colorVariety(image)) → \(PreviewGate.save(image, name).lastPathComponent)")
                } else { notes.append("\(name): no capture") }
            }
            await capture(bar.panel, "taskbar-center")
            await MainActor.run { bar.alignment = .left }
            await settle(0.5)
            await capture(bar.panel, "taskbar-left")
            await MainActor.run { bar.alignment = .center; bar.solidBackground = true }
            await settle(0.5)
            await capture(bar.panel, "taskbar-solid")
            await MainActor.run { bar.solidBackground = false }

            // The menu bar for comparison (its WindowServer window at the top of the screen).
            let menuBar = WindowServer.windows().filter { $0.bounds.minY == 0 && $0.bounds.height <= 40 && $0.bounds.width >= NSScreen.screens[0].frame.width - 1 }
            if let mb = menuBar.first, let (image, _) = await PreviewClient.thumbnail(mb.id, maxDimension: 3000) {
                notes.append("menu bar → \(PreviewGate.save(image, "menubar").lastPathComponent)")
            }

            // Pop-ups: the choice menu (right-click menu) and the group flyout.
            await MainActor.run {
                ChoicePanel.shared.show([("G1", nil), ("New window", {}), ("Close window", {})], atAX: CGPoint(x: 300, y: 600))
            }
            await settle(0.6)
            await capture(ChoicePanel.shared.window, "choice-menu", max: 800)
            await MainActor.run { ChoicePanel.shared.hide() }
            await MainActor.run { bar.showFlyout(forGroupAt: 0) }
            await settle(1.2)
            await capture(bar.flyoutPanel.panel, "group-flyout", max: 1200)
            await MainActor.run { bar.flyoutPanel.hide() }
            Report.record("Taskbar look", notes.joined(separator: "; "))
            print("LOOK: " + notes.joined(separator: "\n"))
        }

        /// The real Dock sits under the bar (it reserves the bar's space). Hovering the bar must not reach it: the Dock
        /// would show its own app-name labels over pane's bar (seen once the bar became see-through: macOS passes
        /// mouse events through a window's transparent pixels unless it opts out).
        @Test func hoverOverBarDoesNotReachTheDock() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A"], frame: CGRect(x: 160, y: 200, width: 360, height: 240))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 8) { DockReservation.bottomInset() == 48 }
            await settle(6)
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { Issue.record("no Dock"); return }
            let screen = NSScreen.screens[0].frame
            let barTop = screen.height - 48
            for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                print("DOCKLIST \(AX.role(list) ?? "?") \(AX.frame(list).map { "\($0)" } ?? "-")")
                for tile in ((AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? []) {
                    print("DOCKTILE \(AX.title(tile) ?? "?") \(AX.frame(tile).map { "\($0)" } ?? "-")")
                }
            }
            var tiles: [(String, CGRect)] = []
            for list in (AX.get(AX.app(dock.processIdentifier), kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for tile in (AX.get(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    if let frame = AX.frame(tile), frame.width > 0, frame.maxY > barTop + 2 { tiles.append((AX.title(tile) ?? "?", frame)) }
                }
            }
            // The Dock draws its hover label inside its own (screen-wide) window, above the tile: capture the Dock's
            // windows and compare the strip above the bar before and after hovering.
            func dockStrip(_ name: String? = nil) async -> [UInt8]? {
                guard PreviewGate.enabled else { return nil }
                var bytes: [UInt8] = []
                for w in WindowServer.windows(onScreenOnly: true).filter({ $0.pid == dock.processIdentifier && $0.bounds.width > 400 }) {
                    guard let (image, _) = await PreviewClient.thumbnail(w.id, maxDimension: 3000) else { continue }
                    if let name { print("DOCKWIN \(name): \(w.id) \(w.bounds) L\(w.layer) → \(PreviewGate.save(image, "dock-\(name)-\(w.id)").lastPathComponent)") }
                    let k = CGFloat(image.height) / w.bounds.height
                    let top = max(0, (barTop - 60 - w.bounds.minY) * k)
                    guard let strip = image.cropping(to: CGRect(x: 0, y: top, width: CGFloat(image.width), height: 56 * k).integral),
                          let data = strip.dataProvider?.data as Data? else { continue }
                    bytes += [UInt8](data)
                }
                return bytes
            }
            func move(to point: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
            var labels: [String] = []
            move(to: CGPoint(x: screen.midX, y: screen.midY))
            try? await Task.sleep(nanoseconds: 800_000_000)
            let quiet = await dockStrip("quiet")
            for (title, frame) in tiles.prefix(6) {
                let point = CGPoint(x: frame.midX, y: max(barTop + 24, min(frame.midY, screen.height - 4)))
                // "Cut in" from above, as a hand does: through the strip just above the bar (where the Dock's icon row
                // starts) into the bar.
                for y in stride(from: barTop - 40, through: point.y, by: 3) {
                    move(to: CGPoint(x: point.x, y: y))
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                move(to: CGPoint(x: point.x + 2, y: point.y))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let hovered = await dockStrip(title == tiles.first?.0 ? "hover" : nil)
                if let quiet, let hovered, quiet.count == hovered.count {
                    let changed = zip(quiet, hovered).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                    if changed > 2000 { labels.append("\(title) at \(Int(point.x)),\(Int(point.y)): \(changed) bytes changed above the bar") }
                }
            }
            move(to: CGPoint(x: screen.midX, y: screen.midY))
            let note = "Dock tiles under the bar \(tiles.count) (\(tiles.prefix(4).map(\.0))); Dock labels shown on hover: \(labels.isEmpty ? "none" : labels.joined(separator: "; "))"
            Report.record("Taskbar · Dock under the bar", note)
            print("DOCK: " + note)
            #expect(!tiles.isEmpty, "no Dock tile under the bar: the check proves nothing")
            #expect(labels.isEmpty)
        }

    }
}
