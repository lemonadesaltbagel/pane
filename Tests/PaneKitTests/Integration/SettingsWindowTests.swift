// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Phase 2: the settings window, driven over Accessibility in a test
    /// agent with a copy of your config (your config.json never changes).
    @Suite("Settings window")
    struct SettingsWindowTests: SettingsUIHarness {

        /// S1: opens like a Mac app — one window, in front, titled after its page; reopens on the last page; minimize
        /// and zoom off; no taskbar button (D3).
        @Test func opensLikeAMacApp() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            let opened = await Self.open("taskbar", pid)
            let front = await eventually(timeout: 3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
            _ = AgentLink.send("open-settings:taskbar")
            await settle(0.8)
            let one = Self.windows(pid).count == 1
            let w = Self.window(pid)
            func enabled(_ attribute: String) -> Bool? {
                w.flatMap { AX.get($0, attribute) as AXUIElement? }.flatMap { AX.get($0, kAXEnabledAttribute) as Bool? }
            }
            let zoomOff = enabled(kAXZoomButtonAttribute) == false, minimizeOff = enabled(kAXMinimizeButtonAttribute) == false
            // D3 (no taskbar button, no Alt+Tab entry) holds by construction: the inventory leaves pane's own pid out.
            let buttons = Harness.taskbarButtons(pid).map(\.0)
            let noTaskbarButton = !buttons.contains { $0.lowercased().hasPrefix("group: pane ") || $0.lowercased() == "pane" }
            if !noTaskbarButton { print("SETTINGS-S1 buttons: \(buttons)") }
            // Close, then open without a page: the last page again.
            if let close: AXUIElement = w.flatMap({ AX.get($0, kAXCloseButtonAttribute) }) { AX.perform(close, kAXPressAction) }
            let closed = await eventually(timeout: 3) { Self.windows(pid).isEmpty }
            _ = AgentLink.send("open-settings:")
            let reopenedOnLast = await eventually(timeout: 5) { Self.window(pid).flatMap(AX.title) == "Taskbar" }
            let keyboard = await Self.open("keyboard", pid)
            let note = "opened on Taskbar \(opened), pane in front \(front), one window after a second open \(one), zoom off \(zoomOff), minimize off \(minimizeOff), no taskbar button \(noTaskbarButton); closed \(closed), reopened on the last page \(reopenedOnLast); page switch \(keyboard)"
            Report.record("Settings window · opens", note)
            print("SETTINGS-S1: " + note)
            #expect(opened && front && one && zoomOff && minimizeOff && noTaskbarButton && closed && reopenedOnLast && keyboard)
        }

        /// The look of each page, saved to test-results/previews/settings-<page>.png (for review by eye).
        @Test func pagesLook() async throws {
            guard PreviewGate.enabled else { return }
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            var saved: [String] = []
            for page in SettingsPages.all.map(\.id) {
                guard await Self.open(page, pid) else { continue }
                await settle(0.8)
                guard let frame = Self.window(pid).flatMap(AX.frame),
                      let wid = WindowServer.windows().first(where: { $0.pid == pid && Geometry.approximatelyEqual($0.bounds, frame, tolerance: 4) })?.id,
                      let (image, _) = await PreviewClient.thumbnail(wid, maxDimension: 2000) else { continue }
                saved.append(PreviewGate.save(image, "settings-\(page)").lastPathComponent)
            }
            Report.record("Settings window · look", saved.joined(separator: ", "))
            print("SETTINGS-LOOK: \(saved)")
            #expect(saved.count == SettingsPages.all.count)
        }

        // MARK: S2–S8

        static func showAdvanced() { UserDefaults(suiteName: "pane-test-agent")?.set(true, forKey: "PaneSettingsShowAdvanced") }

        static func axValue(_ e: AXUIElement) -> Any? { AX.get(e, kAXValueAttribute) as AnyObject? }

        static func boolValue(_ e: AXUIElement) -> Bool? { (axValue(e) as? NSNumber).map { $0.intValue != 0 } }


        /// S2: every setting the window offers has a control with its id on its page, showing the file's value.
        @Test func coversTheCatalog() async throws {
            let (f, pane) = try await Self.launch()
            defer { stopAgent(pane); f.quit() }
            Self.showAdvanced()
            let pid = pane.processIdentifier
            let store = MainActor.assumeIsolatedOrSync { SettingsStore(url: Harness.testConfig) }
            var missing: [String] = [], wrong: [String] = [], checked = 0
            for page in SettingsPages.all {
                guard await Self.open(page.id, pid), let w = Self.window(pid) else { missing.append("page \(page.id)"); continue }
                await settle(0.6)
                var ids = Set<String>()
                Self.identifiers(w, into: &ids)
                let expected = page.groups.flatMap(\.ids).filter { id in
                    guard let s = PaneSettings.setting(id: id), !SettingsPages.internalIDs.contains(id) else { return false }
                    return s.info.status != .planned || s.info.kind == .shortcut
                }
                for id in expected {
                    guard ids.contains(id) else { missing.append(id); continue }
                    checked += 1
                    guard let e = Self.element(w, id), let s = PaneSettings.setting(id: id) else { continue }
                    let json = MainActor.assumeIsolatedOrSync { store.json(id) }
                    switch s.info.kind {
                    case .toggle:
                        if Self.boolValue(e) != (json == .bool(true)) { wrong.append("\(id)=\(String(describing: Self.axValue(e)))") }
                    case .choice(let choices):
                        if case .string(let v)? = json, let label = choices.first(where: { $0.value == v })?.label,
                           (Self.axValue(e) as? String) != label { wrong.append("\(id)=\(String(describing: Self.axValue(e))) not \(label)") }
                    default: break
                    }
                }
            }
            let note = "\(checked) settings found with their ids; missing \(missing); values not matching the file \(wrong)"
            Report.record("Settings window · covers the catalog", note)
            print("SETTINGS-S2: " + note)
            #expect(missing.isEmpty && wrong.isEmpty && checked > 45) // the engine's: 53 (pane Pro adds its own)
        }

        /// S3: a switch writes the file at once; a hand edit of the file updates the switch.
        @Test func liveRoundTrip() async throws {
            let (f, pane) = try await Self.launch { try? $0.set(PaneSettings.badges, true) }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open("taskbar", pid)
            let toggle = try #require(Self.find(pid, PaneSettings.badges.id))
            let start = Date()
            AX.perform(toggle, kAXPressAction)
            let written = await eventually(timeout: 2) { (Self.stored(PaneSettings.badges.id) as? Bool) == false }
            let writeTime = Date().timeIntervalSince(start)
            MainActor.assumeIsolatedOrSync { try? SettingsStore(url: Harness.testConfig).set(PaneSettings.badges, true) }
            let editStart = Date()
            let followed = await eventually(timeout: 3) { Self.find(pid, PaneSettings.badges.id).flatMap(Self.boolValue) == true }
            let followTime = Date().timeIntervalSince(editStart)
            let note = String(format: "switch → file %@ in %.2f s; hand edit → switch %@ in %.2f s", "\(written)", writeTime, "\(followed)", followTime)
            Report.record("Settings window · live round trip", note)
            print("SETTINGS-S3: " + note)
            #expect(written && writeTime < 0.5 && followed && followTime < 1)
        }

        /// S4: a restart setting changed → the bar lists it → Restart pane → a new pane, Settings open again on the page.
        @Test func restartBar() async throws {
            let (f, pane) = try await Self.launch { try? $0.set(PaneSettings.combineButtons, "always") }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open("taskbar", pid)
            let noBarBefore = Self.find(pid, "settings.restartBar") == nil
            let combine = try #require(Self.find(pid, PaneSettings.combineButtons.id))
            let label = SettingsPages.page("taskbar").flatMap { _ in
                if case .choice(let c) = PaneSettings.combineButtons.info.kind { return c.first { $0.value != "always" }?.label }; return nil
            } ?? ""
            let chose = await Self.choose(combine, label)
            let barShown = await eventually(timeout: 2) { Self.find(pid, "settings.restartBar") != nil }
            var lists = false
            if let bar = Self.find(pid, "settings.restartBar") {
                var texts: [String] = []
                func walk(_ e: AXUIElement) { if let v: String = AX.get(e, kAXValueAttribute) { texts.append(v) }; for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c) } }
                walk(bar)
                lists = texts.contains { $0.contains(PaneSettings.combineButtons.info.title) }
            }
            var newPID: pid_t = 0
            defer { if newPID > 0 && newPID != pid { stopAgent(pid: newPID) } }
            if let button = Self.find(pid, "settings.restartButton") { AX.perform(button, kAXPressAction) }
            let restarted = await eventually(timeout: 15) {
                let p = Harness.agentPID(fromLog: Self.log()); if p > 0 && p != pid { newPID = p; return true }; return false
            }
            let reopened = await eventually(timeout: 8) { newPID > 0 && Self.window(newPID).flatMap(AX.title) == "Taskbar" }
            let barGone = reopened && Self.find(newPID, "settings.restartBar") == nil
            // The new pane has the agent link (the old one held its name a moment longer).
            let linked = reopened ? await Self.open("keyboard", newPID) : false
            let note = "no bar before \(noBarBefore); chose “\(label)” \(chose); bar shown \(barShown), lists the setting \(lists); restarted \(restarted) (pid \(pid) → \(newPID)); Settings reopened on Taskbar \(reopened); bar gone \(barGone); new pane answers the agent link \(linked)"
            Report.record("Settings window · restart bar", note)
            print("SETTINGS-S4: " + note)
            #expect(noBarBefore && chose && barShown && lists && restarted && reopened && barGone && linked)
            if newPID > 0 && newPID != pid {
                stopAgent(pid: newPID)
                _ = await eventually(timeout: 10) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() } != 48 }
                newPID = 0
            }
        }

        /// S6: record ⌃⌥→ for Snap left: stored as text, both rows show the conflict with Snap right; reset puts it back.
        @Test func recordsShortcutsAndShowsConflicts() async throws {
            let (f, pane) = try await Self.launch { store in
                store.applyShortcutPreset("mac")
                store.reset(id: Shortcut.snapLeft.setting.id)
            }
            defer { stopAgent(pane); f.quit(); SyntheticKeyboard.releaseAllModifiers() }
            let pid = pane.processIdentifier
            _ = await Self.open("keyboard", pid)
            let id = Shortcut.snapLeft.setting.id
            let recorder = try #require(Self.find(pid, "\(id).recorder"))
            AX.perform(recorder, kAXPressAction)
            let recording = await eventually(timeout: 2) { Self.find(pid, "\(id).recorder").flatMap { AX.get($0, kAXValueAttribute) as String? } == "recording" }
            // Keys only while pane is in front (never into Terminal).
            let front = await eventually(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
            if recording && front { SyntheticKeyboard.press(kVK_RightArrow, [.maskControl, .maskAlternate]) }
            let stored = await eventually(timeout: 2) { Self.stored(id) as? String == "ctrl+alt+right" }
            let bothConflict = await eventually(timeout: 2) {
                Self.find(pid, "\(id).conflict") != nil && Self.find(pid, "\(Shortcut.snapRight.setting.id).conflict") != nil
            }
            let notRecording = Self.find(pid, "\(id).recorder").flatMap { AX.get($0, kAXValueAttribute) as String? } == "ctrl+alt+right"
            if let reset = Self.find(pid, "\(id).reset") { AX.perform(reset, kAXPressAction) }
            let reset = await eventually(timeout: 2) { Self.stored(id) == nil }
            let conflictGone = await eventually(timeout: 2) { Self.find(pid, "\(id).conflict") == nil }
            let note = "recording \(recording) (pane in front \(front)); ⌃⌥→ stored \(stored); conflict on both rows \(bothConflict); recorder shows it \(notRecording); reset \(reset), conflict gone \(conflictGone)"
            Report.record("Settings window · shortcuts", note)
            print("SETTINGS-S6: " + note)
            #expect(recording && front && stored && bothConflict && notRecording && reset && conflictGone)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
            #expect(!ShortcutRecording.isOn) // the test process's flag; the agent's is checked by keys working in later tests
        }

        /// Search finds Windows names; "Show welcome again" clears the onboarding version; labels on every control; 50
        /// open/close cycles don't grow the agent's memory much (S8).
        @Test func searchActionsAndAccessibility() async throws {
            let (f, pane) = try await Self.launch { try? $0.set(PaneSettings.onboardingDone, 1) }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open("general", pid)
            // Search: "hide taskbar" (a Windows name, not in the title) finds Automatically hide the taskbar.
            // `--open-settings "search:…"` (typing would go through the input method, which may compose words).
            _ = AgentLink.send("open-settings:search:hide taskbar")
            let found = await eventually(timeout: 2) { Self.find(pid, PaneSettings.autoHide.id) != nil }
            let fieldShows = Self.find(pid, "settings.search").flatMap { AX.get($0, kAXValueAttribute) as String? } == "hide taskbar"
            // Show welcome again.
            _ = await Self.open("advanced", pid)
            if let button = Self.find(pid, "settings.showWelcome") { AX.perform(button, kAXPressAction) }
            let welcome = await eventually(timeout: 2) { Self.stored(PaneSettings.onboardingDone.id) == nil }
            // Labels: every switch and pop-up on the Taskbar page has a description.
            _ = await Self.open("taskbar", pid)
            var unlabeled: [String] = []
            if let w = Self.window(pid) {
                func walk(_ e: AXUIElement, _ depth: Int) {
                    let role = AX.role(e) ?? ""
                    if [kAXCheckBoxRole, kAXPopUpButtonRole, kAXSliderRole].contains(role) {
                        let label = (AX.get(e, kAXDescriptionAttribute) as String?) ?? AX.title(e) ?? ""
                        if label.isEmpty { unlabeled.append((AX.get(e, "AXIdentifier") as String?) ?? role) }
                    }
                    if depth < 40 { for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) } }
                }
                walk(w, 0)
            }
            // Memory over 50 open/close cycles.
            func rss() -> Int {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
                let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
                return Int(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            }
            func closeWindow() { if let close: AXUIElement = Self.window(pid).flatMap({ AX.get($0, kAXCloseButtonAttribute) }) { AX.perform(close, kAXPressAction) } }
            for _ in 0..<5 { closeWindow(); _ = await Self.open("multitasking", pid) }
            let before = rss()
            for i in 0..<50 { closeWindow(); _ = await Self.open(i % 2 == 0 ? "keyboard" : "taskbar", pid) }
            await settle(1)
            let middle = rss()
            for i in 0..<50 { closeWindow(); _ = await Self.open(i % 2 == 0 ? "keyboard" : "taskbar", pid) }
            await settle(1)
            let firstMB = Double(middle - before) / 1024
            let growthMB = Double(rss() - middle) / 1024 // the second 50: past first-use caches
            print("SETTINGS-S8 memory: first 50 \(firstMB) MB, second 50 \(growthMB) MB")
            let note = String(format: "search “hide taskbar” found the auto-hide switch %@; Show welcome again cleared the version %@; unlabeled controls %@; memory after 50 open/close %+.1f MB",
                              "\(found)", "\(welcome)", "\(unlabeled)", growthMB)
            Report.record("Settings window · search, actions, accessibility", note)
            print("SETTINGS-S8: " + note)
            #expect(found && fieldShows && welcome && unlabeled.isEmpty && growthMB < 10)
        }

        /// S7: Reset all, keeping app exceptions: the settings go back to defaults, the per-app ones stay.
        @Test func resetAllKeepsAppExceptions() async throws {
            let (f, pane) = try await Self.launch { store in
                try? store.set(PaneSettings.badges, false)
                try? store.setOverride(PaneSettings.snap, false, for: FixtureBundle.bundleID)
            }
            defer { stopAgent(pane); f.quit() }
            let pid = pane.processIdentifier
            _ = await Self.open("advanced", pid)
            if let button = Self.find(pid, "settings.resetAll") { AX.perform(button, kAXPressAction) }
            func alertButton(_ title: String) -> AXUIElement? {
                for w in AX.windows(of: pid) where (AX.get(w, "AXIdentifier") as String?) != "pane.settings" {
                    func walk(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
                        if AX.title(e) == title, [kAXButtonRole, kAXCheckBoxRole].contains(AX.role(e) ?? "") { return e }
                        guard d < 8 else { return nil }
                        for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let r = walk(c, d + 1) { return r } }
                        return nil
                    }
                    if let e = walk(w, 0) { return e }
                }
                return nil
            }
            let alert = await eventually(timeout: 3) { alertButton("Reset") != nil }
            let keepChecked = alertButton("Keep app exceptions").flatMap(Self.boolValue) == true
            if let reset = alertButton("Reset") { AX.perform(reset, kAXPressAction) }
            let reset = await eventually(timeout: 3) { Self.stored(PaneSettings.badges.id) == nil }
            let appsKept = ((Self.config()["apps"] as? [String: Any])?[FixtureBundle.bundleID] as? [String: Any])?[PaneSettings.snap.id] as? Bool == false
            let note = "alert shown \(alert), Keep app exceptions checked \(keepChecked); settings reset \(reset); app exceptions kept \(appsKept)"
            Report.record("Settings window · reset all", note)
            print("SETTINGS-S7: " + note)
            #expect(alert && keepChecked && reset && appsKept)
        }
    }
}
