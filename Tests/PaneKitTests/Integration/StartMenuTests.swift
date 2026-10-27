// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// The Start menu, driven over Accessibility in a test agent. Its Start file
    /// is a test copy, the fixture app is indexed (PANE_START_APP_ROOTS) so launching never opens one of your apps,
    /// and power actions go to a fake (PANE_FAKE_POWER; a test agent refuses real ones anyway).
    @Suite("Start menu")
    struct StartMenuTests: StartUIHarness {






        /// The look: home (Category view), List view, search results (test-results/previews/start-*.png).
        @Test func looks() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            var saved: [String] = []
            _ = await Self.open(pid)
            await settle(0.8)
            if let s = await Self.capture(pid, "start-home") { saved.append(s) }
            MainActor.assumeIsolatedOrSync { try? SettingsStore(url: Harness.testConfig).set(PaneSettings.startAllView, "list") }
            await settle(1.2)
            if let s = await Self.capture(pid, "start-list") { saved.append(s) }
            _ = AgentLink.send("start-search:saf")
            await settle(1.5)
            if let s = await Self.capture(pid, "start-search") { saved.append(s) }
            Report.record("Start · look", saved.joined(separator: ", "))
            #expect(!PreviewGate.enabled || saved.count == 3)
        }

        /// U1: Start opens fast, centred above the taskbar with search focused, and closes like Windows' (Start again,
        /// a click elsewhere, Esc); the app you were in stays in front; the Start button opens it too.
        @Test func opensAndCloses() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit(); SyntheticKeyboard.releaseAllModifiers() }
            let pid = pane.processIdentifier
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            _ = await eventually(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }
            let start = Date()
            _ = AgentLink.send("start:toggle")
            let opened = await eventually(timeout: 3) { Self.shown(pid) }
            let openMs = Date().timeIntervalSince(start) * 1000
            let screen = NSScreen.screens[0].frame
            let frame = Self.window(pid).flatMap(AX.frame) ?? .zero
            let centred = abs(frame.midX - screen.midX) < 2 && frame.maxY <= screen.height - 48 - 8 && frame.maxY >= screen.height - 48 - 20
            let focused = Self.find(pid, "start.search").flatMap { AX.get($0, kAXFocusedAttribute) as Bool? } == true
            let fixtureStillFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid
            let agentMs = Double(Self.log().components(separatedBy: "start: shown in ").last?.prefix { $0.isNumber } ?? "") ?? -1
            _ = AgentLink.send("start:toggle")
            let toggledOff = await eventually(timeout: 2) { !Self.shown(pid) }
            // A click elsewhere closes it.
            _ = await Self.open(pid)
            let fixtureFrame = try #require(AX.frame(try f.requireWindow("A")))
            SyntheticMouse.click(at: CGPoint(x: fixtureFrame.midX, y: fixtureFrame.midY))
            let clickClosed = await eventually(timeout: 2) { !Self.shown(pid) }
            // Esc closes it (keys only with the fixture in front).
            _ = await Self.open(pid)
            var escClosed = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid {
                SyntheticKeyboard.press(kVK_Escape)
                escClosed = await eventually(timeout: 2) { !Self.shown(pid) }
            }
            // The Start button.
            var buttonOpens = false
            if let bar = AX.windows(of: pid).first(where: { AX.title($0) == "Pane Taskbar" }), let startButton = SettingsUI.element(bar, "Start") ?? {
                func walk(_ e: AXUIElement) -> AXUIElement? { if AX.title(e) == "Start" && AX.role(e) == kAXButtonRole { return e }; for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let r = walk(c) { return r } }; return nil }
                return walk(bar)
            }() {
                AX.perform(startButton, kAXPressAction)
                buttonOpens = await eventually(timeout: 2) { Self.shown(pid) }
                _ = AgentLink.send("start:hide")
            }
            let note = String(format: "opened %@ in %.0f ms (agent %.0f ms), centred above the taskbar %@ (%@), search focused %@, your app still in front %@; Start again closes %@, a click elsewhere %@, Esc %@; Start button opens %@",
                              "\(opened)", openMs, agentMs, "\(centred)", "\(frame)", "\(focused)", "\(fixtureStillFront)", "\(toggledOff)", "\(clickClosed)", "\(escClosed)", "\(buttonOpens)")
            Report.record("Start · opens and closes", note)
            print("START-U1: " + note)
            #expect(opened && openMs < 300 && agentMs < 100 && centred && focused && fixtureStillFront)
            #expect(toggledOff && clickClosed && escClosed && buttonOpens)
        }

        /// U5: search: Best match first, a pane setting found by its Windows name, the preview pane, Enter opens.
        @Test func search() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = AgentLink.send("start-search:PaneFix")
            let results = await eventually(timeout: 3) { Self.find(pid, "start.result.0") != nil }
            let best = Self.find(pid, "start.result.0").flatMap { AX.get($0, kAXDescriptionAttribute) as String? } ?? ""
            let preview = Self.find(pid, "start.preview") != nil
            var entered = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid {
                SyntheticKeyboard.press(kVK_Return)
                entered = await eventually(timeout: 3) { Self.log().contains("start: opened app:\(FixtureBundle.bundleID)") }
            }
            _ = AgentLink.send("start-search:hide taskbar")
            let paneSetting = await eventually(timeout: 3) {
                (0..<6).contains { Self.find(pid, "start.result.\($0)").flatMap { AX.get($0, kAXDescriptionAttribute) as String? }?.contains("pane Settings ▸ Taskbar") == true }
            }
            _ = AgentLink.send("start-search:wi-fi")
            let systemSetting = await eventually(timeout: 3) { Self.find(pid, "start.result.0").flatMap { AX.get($0, kAXDescriptionAttribute) as String? }?.hasPrefix("Wi-Fi") == true }
            _ = AgentLink.send("start:hide")
            let note = "results \(results), best match “\(best)”, preview \(preview); Enter opened it \(entered); “hide taskbar” → pane setting \(paneSetting); “wi-fi” → System Settings \(systemSetting)"
            Report.record("Start · search", note)
            print("START-U5: " + note)
            #expect(results && best.hasPrefix("PaneFixture") && preview && entered && paneSetting && systemSetting)
        }

        /// U7: every pinned tile and bottom-bar button is labelled; 50 opens don't grow memory after warm-up.
        @Test func accessibleAndLight() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open(pid)
            var unlabeled: [String] = []
            if let w = Self.window(pid) {
                func walk(_ e: AXUIElement, _ d: Int) {
                    if AX.role(e) == kAXScrollBarRole { return } // the scroller's own parts
                    if [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole].contains(AX.role(e) ?? "") {
                        let label = (AX.get(e, kAXDescriptionAttribute) as String?) ?? AX.title(e) ?? ""
                        if label.isEmpty { unlabeled.append((AX.get(e, "AXIdentifier") as String?) ?? "\(AX.role(e) ?? "?") \(AX.frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") help \((AX.get(e, kAXHelpAttribute) as String?) ?? "-")") }
                    }
                    if d < 30 { for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, d + 1) } }
                }
                walk(w, 0)
            }
            func rss() -> Int {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
                let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
                return Int(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            }
            for _ in 0..<10 { _ = AgentLink.send("start:toggle"); await settle(0.15) }
            if Self.shown(pid) { _ = AgentLink.send("start:hide") }
            let before = rss()
            for _ in 0..<50 { _ = AgentLink.send("start:toggle"); await settle(0.15) }
            if Self.shown(pid) { _ = AgentLink.send("start:hide") }
            await settle(1)
            let growthMB = Double(rss() - before) / 1024
            let note = String(format: "unlabeled buttons %@; memory after 50 opens and closes %+.1f MB", "\(unlabeled)", growthMB)
            Report.record("Start · accessibility and memory", note)
            print("START-U7: " + note)
            #expect(unlabeled.isEmpty && growthMB < 15)
        }
    }
}
