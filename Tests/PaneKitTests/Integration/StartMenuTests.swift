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
                pressEscape()
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

        static func menuItem(_ pid: pid_t, _ title: String) -> AXUIElement? {
            for w in AX.windows(of: pid) + [AX.app(pid)] {
                func walk(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
                    if AX.role(e) == kAXMenuItemRole, AX.title(e) == title { return e }
                    guard d < 12 else { return nil }
                    for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let r = walk(c, d + 1) { return r } }
                    return nil
                }
                if let r = walk(w, 0) { return r }
            }
            return nil
        }

        static func storedPins() -> [PinnedItem] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return ((try? Data(contentsOf: startFile)).flatMap { try? decoder.decode(StartData.self, from: $0) })?.pinned ?? []
        }

        /// U2: Pinned shows the Start file's pins; right-click ▸ Move to front and Unpin from Start write the file; a
        /// tile launches its app. Dropping a pin onto another reorders it: folders are an extension's.
        @Test func pinned() async throws {
            let fixture = FixtureBundle.bundleID
            let (f, pane) = try await Self.launch(pins: [.app("com.apple.calculator"), .app(fixture), .app("com.apple.Notes"), .app("com.apple.TextEdit")])
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open(pid)
            let tiles = ["com.apple.calculator", fixture, "com.apple.Notes", "com.apple.TextEdit"].map { Self.find(pid, "start.pinned.\($0)") != nil }
            func contextMenu(_ id: String, _ title: String) async -> Bool {
                guard let tile = Self.find(pid, id) else { return false }
                AX.perform(tile, "AXShowMenu")
                guard await eventually(timeout: 2, { Self.menuItem(pid, title) != nil }), let item = Self.menuItem(pid, title) else { return false }
                return AX.perform(item, kAXPressAction) == .success
            }
            let moved = await contextMenu("start.pinned.com.apple.Notes", "Move to front")
            let frontWritten = await eventually(timeout: 2) { Self.storedPins().first == .app("com.apple.Notes") }
            let unpinned = await contextMenu("start.pinned.com.apple.TextEdit", "Unpin from Start")
            let unpinWritten = await eventually(timeout: 2) { !Self.storedPins().contains(.app("com.apple.TextEdit")) }
            // Drop Calculator's tile onto the middle of Notes' tile: no folder without the extension.
            var noFolder = false
            if let from = Self.find(pid, "start.pinned.com.apple.calculator").flatMap(AX.frame), let to = Self.find(pid, "start.pinned.com.apple.Notes").flatMap(AX.frame) {
                SyntheticMouse.drag(from: CGPoint(x: from.midX, y: from.midY), to: CGPoint(x: to.midX, y: to.midY))
                await settle(1)
                noFolder = !Self.storedPins().contains { if case .folder = $0 { return true }; return false } && Self.find(pid, "start.folder.0") == nil
            }
            _ = AgentLink.send("start:hide"); _ = await Self.open(pid)
            if let tile = Self.find(pid, "start.pinned.\(fixture)") { AX.perform(tile, kAXPressAction) }
            let launched = await eventually(timeout: 3) { Self.log().contains("start: opened app:\(fixture)") }
            let closedAfter = await eventually(timeout: 2) { !Self.shown(pid) }
            let note = "tiles shown \(tiles); Move to front \(moved) → written \(frontWritten); Unpin \(unpinned) → written \(unpinWritten); drop onto another → no folder \(noFolder); tile launches the app \(launched), Start closes \(closedAfter)"
            Report.record("Start · pinned", note)
            print("START-U2: " + note)
            #expect(tiles.allSatisfy { $0 } && moved && frontWritten && unpinned && unpinWritten && noFolder && launched && closedAfter)
        }

        /// U4: All in the engine's views: Grid (the default), and List with letter headers and the jump grid. No
        /// Category view without the extension.
        @Test func allViews() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open(pid)
            let all = await eventually(timeout: 2) { Self.find(pid, "start.all") != nil }
            // The engine's catalog offers Grid and List only (an extension may register more).
            let noCategory = MainActor.assumeIsolatedOrSync {
                if case .choice(let choices)? = PaneSettings.setting(id: PaneSettings.startAllView.id)?.info.kind { return choices.map(\.value) == ["grid", "list"] }
                return false
            }
            var list = false
            if let picker = Self.find(pid, "start.all.view") { list = await SettingsUI.choose(picker, "List") }
            let letters = await eventually(timeout: 2) { Self.find(pid, "start.all.index.C") != nil }
            if let header = Self.find(pid, "start.all.index.C") { AX.perform(header, kAXPressAction) }
            let jump = await eventually(timeout: 2) { Self.find(pid, "start.jumpGrid") != nil }
            if let t = Self.find(pid, "start.jump.T") { AX.perform(t, kAXPressAction) }
            let jumped = await eventually(timeout: 2) { Self.find(pid, "start.jumpGrid") == nil }
            let remembered = await eventually(timeout: 2) { SettingsUI.stored(PaneSettings.startAllView.id) as? String == "list" }
            let note = "All shown \(all); no Category view \(noCategory); List chosen \(list) with letters \(letters); letter → jump grid \(jump), letter picked \(jumped); view remembered \(remembered)"
            Report.record("Start · All views", note)
            print("START-U4: " + note)
            #expect(all && noCategory && list && letters && jump && jumped && remembered)
        }

        /// U6: the account button, the folders next to power, and the power menu (it reaches the fake). Quick Link is an
        /// extension's: without it the agent doesn't know the message.
        @Test func bottomBar() async throws {
            let (f, pane) = try await Self.launch { try? $0.set(PaneSettings.startFolders, ["settings", "downloads"]) }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open(pid)
            let account = Self.find(pid, "start.account") != nil
            let places = Self.find(pid, "start.place.settings") != nil && Self.find(pid, "start.place.downloads") != nil && Self.find(pid, "start.place.finder") == nil
            var restart = false
            if let power = Self.find(pid, "start.power") { restart = await SettingsUI.choose(power, "Restart") }
            let restartFaked = await eventually(timeout: 2) { Self.powerLog() == ["restart"] }
            _ = AgentLink.send("quick-link")
            let noQuickLink = await eventually(timeout: 2) { Self.log().contains("link: unknown message quick-link") }
            let note = "account button \(account); folders as set \(places); power ▸ Restart \(restart) → fake \(restartFaked) (\(Self.powerLog())); no Quick Link \(noQuickLink)"
            Report.record("Start · bottom bar", note)
            print("START-U6: " + note)
            #expect(account && places && restart && restartFaked && noQuickLink)
        }
    }
}
