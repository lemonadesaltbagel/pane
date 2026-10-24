// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// The settings that were stored but not built (research/plan-reserved-settings.md), honoured by the real agent.
    @Suite("Settings · honoured", .serialized)
    struct ReservedSettingsTests: LiveSettingsHarness {

        /// G1: badges, flashing, hover previews and the show-desktop corner off; badges back on live.
        @Test func taskbarToggles() async throws {
            let f = try await Fixture.launch(label: "G", windows: ["A"], extraArguments: ["--badge", "7", "--attention", "6"], frame: CGRect(x: 160, y: 200, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent { store in
                try? store.set(PaneSettings.badges, false)
                try? store.set(PaneSettings.flashing, false)
                try? store.set(PaneSettings.farCornerShowsDesktop, false)
            }
            defer { stopAgent(pane) }
            await Self.ready()
            // Something else in front so the attention request bounces.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pane-settings-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            NSWorkspace.shared.open(folder)
            let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
            defer { if let w = AX.windows(of: finderPID).first(where: { AX.title($0) == folder.lastPathComponent }), let c = AX.button(w, kAXCloseButtonAttribute) { AX.perform(c, kAXPressAction) } }
            try? await Task.sleep(nanoseconds: 7_000_000_000) // past the attention request
            func value() -> String { TaskbarSignalsTests.buttonValue(pane.processIdentifier, "group: PaneFixture") ?? "(no button)" }
            let quiet = !value().contains("badge") && !value().contains("attention")
            let noCorner = !Harness.taskbarButtons(pane.processIdentifier).contains { $0.0 == "Show desktop" }
            // Hover: no preview.
            var noPreview = true
            if let b = Harness.taskbarButtons(pane.processIdentifier).first(where: { $0.0.hasPrefix("group: PaneFixture") }) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: b.1, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                noPreview = !AX.windows(of: pane.processIdentifier).contains { AX.title($0) == "Pane Group Flyout" }
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 700, y: 300), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            // Live: badges on again.
            await MainActor.run { Self.change { try? $0.set(PaneSettings.badges, true) } }
            let badgeBack = await eventually(timeout: 4) { value().contains("badge 7") }
            let note = "with the toggles off: no badge or orange \(quiet), no show-desktop corner \(noCorner), no hover preview \(noPreview); badges switched on while running → shown \(badgeBack)"
            Report.record("Settings · taskbar toggles", note)
            print("TOGGLES: " + note + " (value \(value()))")
            #expect(quiet && noCorner && noPreview && badgeBack)
        }

        /// G2: an app hidden from the taskbar has no button and isn't in Alt+Tab.
        @Test func hiddenAppStaysOffTheBarAndAltTab() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A"], frame: CGRect(x: 160, y: 200, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent { try? $0.setOverride(PaneSettings.hideFromTaskbar, true, for: FixtureBundle.bundleID) }
            defer { stopAgent(pane); SyntheticKeyboard.releaseAllModifiers() }
            await Self.ready()
            let noButton = !Harness.taskbarButtons(pane.processIdentifier).contains { $0.0.contains("PaneFixture") || $0.0.hasPrefix("H A") }
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            guard await eventually(timeout: 2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }) else { Issue.record("fixture not in front"); return }
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            try? await Task.sleep(nanoseconds: 600_000_000)
            var tiles: [String] = []
            if let sw = AX.windows(of: pane.processIdentifier).first(where: { AX.title($0) == "Pane Switcher" }) {
                func walk(_ e: AXUIElement) { if let t = AX.title(e), t.hasPrefix("switcher: ") { tiles.append(t) }; for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c) } }
                walk(sw)
            }
            SyntheticKeyboard.tapKey(kVK_Escape, flags: .maskAlternate) // the switcher has the keys: Esc cancels
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            let notInSwitcher = !tiles.contains("switcher: H A")
            let note = "no taskbar button \(noButton); Alt+Tab tiles \(tiles.count), the hidden app's window not among them \(notInSwitcher)"
            Report.record("Settings · hidden app", note)
            print("HIDDEN: " + note)
            #expect(noButton && notInSwitcher)
        }



        /// G3: "⌘⇥ opens pane's switcher": hold ⌘, Tab, release → the previous window; macOS's ⌘Tab off meanwhile.
        @Test func commandTabSwitcher() async throws {
            let f = try await Fixture.launch(label: "W", windows: ["A", "B"], frame: CGRect(x: 160, y: 200, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent { try? $0.set(PaneSettings.replaceCommandTab, true) }
            var stopped = false
            defer { if !stopped { stopAgent(pane) }; SyntheticKeyboard.releaseAllModifiers() }
            await Self.ready()
            let systemOff = PrivateAPI.isSymbolicHotKeyEnabled(.commandTab) == false
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            _ = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W A" }
            await settle(0.4)
            Focus.focus(try f.requireWindow("B"), using: .skyLight)
            _ = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W B" }
            await settle(0.6)
            guard await eventually(timeout: 2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }) else { Issue.record("fixture not in front"); return }
            SyntheticKeyboard.holdModifiers(.maskCommand)
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let shown = AX.windows(of: pane.processIdentifier).contains { AX.title($0) == "Pane Switcher" }
            SyntheticKeyboard.releaseModifiers(.maskCommand)
            let toA = await eventually(timeout: 3) { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "W A" }
            stopAgent(pane); stopped = true
            let systemBack = await eventually(timeout: 3) { PrivateAPI.isSymbolicHotKeyEnabled(.commandTab) == true }
            let note = "macOS ⌘Tab off while pane runs \(systemOff); ⌘Tab showed pane's switcher \(shown); releasing ⌘ switched to the previous window \(toA); macOS ⌘Tab back after quitting \(systemBack)"
            Report.record("Settings · ⌘Tab switcher", note)
            print("CMDSWITCH: " + note)
            #expect(systemOff && shown && toA && systemBack)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }

        // MARK: G4 snap


        // MARK: G5 general

        /// Pause, switched on while pane runs: Alt+Tab and drag-snapping stand down; switched off, they're back.
        @Test func pauseIsLive() async throws {
            let f = try await Fixture.launch(label: "U", windows: ["A", "B"], frame: CGRect(x: 420, y: 240, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane); SyntheticKeyboard.releaseAllModifiers() }
            await Self.ready()
            await MainActor.run { Self.change { try? $0.set(PaneSettings.paused, true) } }
            _ = await eventually(timeout: 4) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("paused:") }
            let a = try f.requireWindow("A")
            Focus.focus(a, using: .skyLight)
            let pausedTiles = await Self.peekSwitcher(pane, front: f, wait: 0.3) ?? [:]
            if let bar = Self.titleBar(a) { await Self.drag([bar, CGPoint(x: Self.work.minX + 2, y: Self.work.midY)]) }
            let left = Geometry.rect(for: .leftHalf, in: Self.work)
            let notSnapped = !(AX.frame(a).map { Geometry.approximatelyEqual($0, left) } ?? false)
            await MainActor.run { Self.change { try? $0.set(PaneSettings.paused, false) } }
            _ = await eventually(timeout: 4) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("resumed") }
            AX.setFrame(a, CGRect(x: 420, y: 240, width: 420, height: 300))
            Focus.focus(a, using: .skyLight)
            let resumedTiles = await Self.peekSwitcher(pane, front: f, wait: 0.3) ?? [:]
            let note = "paused: Alt+Tab shown \(!pausedTiles.isEmpty), drag to the edge snapped \(!notSnapped); resumed: Alt+Tab shown \(!resumedTiles.isEmpty)"
            Report.record("Settings · pause", note)
            print("PAUSE: " + note)
            #expect(pausedTiles.isEmpty && notSnapped && !resumedTiles.isEmpty)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }

        /// Login item (in a test folder), theme (pane's solid taskbar dark, then light), diagnostic log file.
        @Test func loginItemThemeAndLog() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pane-login-\(UUID().uuidString.prefix(6))")
            let logFile = folder.appendingPathComponent("pane.log")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            setenv("PANE_LAUNCH_AGENTS_DIR", folder.path, 1); setenv("PANE_LOG_FILE", logFile.path, 1)
            defer { unsetenv("PANE_LAUNCH_AGENTS_DIR"); unsetenv("PANE_LOG_FILE") }
            let plist = folder.appendingPathComponent("\(LoginItem.label).plist")
            let pane = try Harness.launchAgent { store in
                try? store.set(PaneSettings.launchAtLogin, true)
                try? store.set(PaneSettings.material, "solid")
                try? store.set(PaneSettings.theme, "dark")
                try? store.set(PaneSettings.debugLog, true)
            }
            defer { stopAgent(pane) }
            await Self.ready()
            let written = FileManager.default.fileExists(atPath: plist.path)
            let program = ((NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String])?.first) ?? "-"
            func barBrightness() async -> Double? {
                guard PreviewGate.enabled, let bar = WindowServer.windows().first(where: { $0.pid == pane.processIdentifier && $0.bounds.height == 48 }),
                      let (image, _) = await PreviewClient.thumbnail(bar.id, maxDimension: 600),
                      let data = image.dataProvider?.data as Data? else { return nil }
                let bytes = [UInt8](data)
                var total = 0, count = 0
                for i in stride(from: 0, to: bytes.count - 4, by: 4 * 37) { total += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]); count += 3 }
                return count > 0 ? Double(total) / Double(count) : nil
            }
            let dark = await barBrightness()
            await MainActor.run { Self.change { try? $0.set(PaneSettings.theme, "light"); try? $0.set(PaneSettings.launchAtLogin, false) } }
            _ = await eventually(timeout: 4) { !FileManager.default.fileExists(atPath: plist.path) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let light = await barBrightness()
            let removed = !FileManager.default.fileExists(atPath: plist.path)
            let logLines = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").count
            let themed = (dark ?? 255) < 90 && (light ?? 0) > 160
            let note = "login item written \(written) (runs \(program)), removed when switched off \(removed); taskbar brightness dark \(dark.map { Int($0) } ?? -1) → light \(light.map { Int($0) } ?? -1); log file lines \(logLines)"
            Report.record("Settings · login, theme, log", note)
            print("GENERAL: " + note)
            #expect(written && program.hasSuffix("/" + Harness.binary.lastPathComponent) && removed)
            #expect(themed)
            #expect(logLines > 3)
        }

        // MARK: G6 tray

    }
}
