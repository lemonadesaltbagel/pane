// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import Testing
import PaneKit
import PaneTestKit

// Settings API (Sources/PaneKit/Settings.swift): pure logic on temporary files, safe to run in parallel.

@Suite("Settings")
@MainActor
struct SettingsTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pane-settings-\(UUID().uuidString).json")
    }

    func json(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    @Test func defaultsWithoutAFile() {
        let store = SettingsStore(url: tempURL())
        #expect(store[PaneSettings.replaceDock] == true)
        #expect(store[PaneSettings.combineButtons] == "always")
        #expect(store[PaneSettings.pinned] == nil)
        #expect(store[Shortcut.fullScreen.setting] == KeyBinding([.ctrl, .cmd], "f"))
        #expect(store.issues.isEmpty)
    }

    @Test func onlyNonDefaultValuesAreWritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        try store.set(PaneSettings.combineButtons, "never")
        try store.set(PaneSettings.replaceDock, true) // the default: not written
        let settings = json(url)["settings"] as? [String: Any]
        #expect(json(url)["version"] as? Int == 2)
        #expect(settings?["taskbar.combineButtons"] as? String == "never")
        #expect(settings?["taskbar.replaceDock"] == nil)
        // Back to the default removes it.
        try store.set(PaneSettings.combineButtons, "always")
        #expect((json(url)["settings"] as? [String: Any])?["taskbar.combineButtons"] == nil)
        // A fresh store reads what was saved.
        try store.set(PaneSettings.barHeight, 56)
        #expect(SettingsStore(url: url)[PaneSettings.barHeight] == 56)
    }

    @Test func invalidValuesAreRefused() {
        let store = SettingsStore(url: nil)
        #expect(throws: SettingsError.invalid(id: "taskbar.combineButtons")) { try store.set(PaneSettings.combineButtons, "sometimes") }
        #expect(throws: SettingsError.invalid(id: "taskbar.height")) { try store.set(PaneSettings.barHeight, 500) }
        #expect(throws: SettingsError.notPerApp(id: "taskbar.replaceDock")) { try store.setOverride(PaneSettings.replaceDock, false, for: "com.x") }
        #expect(store[PaneSettings.combineButtons] == "always")
    }

    @Test func badValuesInTheFileFallBackToDefaults() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"version": 2, "settings": {"taskbar.combineButtons": "sometimes", "taskbar.height": 52, "future.setting": 3}}"#.data(using: .utf8)!.write(to: url)
        let store = SettingsStore(url: url)
        #expect(store[PaneSettings.combineButtons] == "always")
        #expect(store[PaneSettings.barHeight] == 52)
        #expect(store.issues.contains { $0.contains("taskbar.combineButtons") })
        // A newer pane's setting survives a save by this one.
        try store.set(PaneSettings.clickThrough, false)
        #expect((json(url)["settings"] as? [String: Any])?["future.setting"] as? Int == 3)
    }

    @Test func v1FilesMigrate() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"optOut": ["com.apple.Terminal"], "combineButtons": "whenFull", "barHeight": 40}"#
            .data(using: .utf8)!.write(to: url)
        let store = SettingsStore(url: url)
        #expect(store[PaneSettings.combineButtons] == "whenFull")
        #expect(store[PaneSettings.barHeight] == 40)
        #expect(store.value(PaneSettings.quitOnLastWindow, for: "com.apple.Terminal") == false)
        #expect(store.value(PaneSettings.quitOnLastWindow, for: "com.apple.Safari") == true)
        // The first change rewrites it as v2, keeping everything.
        try store.set(PaneSettings.clickThrough, false)
        let again = SettingsStore(url: url)
        #expect(json(url)["version"] as? Int == 2)
        #expect(again.value(PaneSettings.quitOnLastWindow, for: "com.apple.Terminal") == false)
        #expect(again[PaneSettings.combineButtons] == "whenFull")
    }

    @Test func perAppOverridesAndBuiltIns() throws {
        let store = SettingsStore(url: nil)
        try store.setOverride(PaneSettings.quitOnLastWindow, false, for: "com.a")
        #expect(store.value(PaneSettings.quitOnLastWindow, for: "com.a") == false)
        #expect(store.overrides(PaneSettings.quitOnLastWindow) == ["com.a": false])
        try store.setOverride(PaneSettings.quitOnLastWindow, nil, for: "com.a")
        #expect(store.overrides(PaneSettings.quitOnLastWindow).isEmpty)
        // VMs and remote desktops ignore pane's shortcuts unless the user says otherwise.
        #expect(store.value(PaneSettings.ignoreShortcuts, for: "com.vmware.fusion") == "always")
        try store.setOverride(PaneSettings.ignoreShortcuts, "never", for: "com.vmware.fusion")
        #expect(store.value(PaneSettings.ignoreShortcuts, for: "com.vmware.fusion") == "never")
    }

    @Test func observersHearChanges() throws {
        let store = SettingsStore(url: nil)
        var heard: [String] = [], all: [String] = []
        let one = store.observe(PaneSettings.combineButtons) { heard.append($0) }
        let any = store.observeAll { all.append($0) }
        try store.set(PaneSettings.combineButtons, "never")
        try store.set(PaneSettings.combineButtons, "never") // unchanged: no call
        store.reset(PaneSettings.combineButtons)
        try store.set(PaneSettings.clickThrough, false)
        #expect(heard == ["never", "always"])
        #expect(all == ["taskbar.combineButtons", "taskbar.combineButtons", "windows.clickThrough"])
        one.cancel()
        try store.set(PaneSettings.combineButtons, "whenFull")
        #expect(heard == ["never", "always"])
        _ = any
    }

    @Test func exportImportRoundTrip() throws {
        let a = SettingsStore(url: nil)
        try a.set(PaneSettings.alignment, "left")
        try a.setOverride(PaneSettings.quitOnLastWindow, false, for: "com.a")
        try a.set(Shortcut.snapLeft.setting, KeyBinding([.ctrl, .alt], "left"))
        let b = SettingsStore(url: nil)
        let problems = try b.importData(a.exportData())
        #expect(problems.isEmpty)
        #expect(b[PaneSettings.alignment] == "left")
        #expect(b.value(PaneSettings.quitOnLastWindow, for: "com.a") == false)
        #expect(b[Shortcut.snapLeft.setting] == KeyBinding([.ctrl, .alt], "left"))
        #expect(throws: SettingsError.self) { try b.importData(Data("nope".utf8)) }
        b.resetAll()
        #expect(b[PaneSettings.alignment] == "center")
        #expect(b.overrides(PaneSettings.quitOnLastWindow).isEmpty)
    }

    @Test func keyBindingsParseAndPrint() {
        let b = KeyBinding("Ctrl+Cmd+Left")
        #expect(b == KeyBinding([.ctrl, .cmd], "left"))
        #expect(b?.text == "ctrl+cmd+left")
        #expect(b?.display == "⌃⌘←")
        #expect(KeyBinding("⌥+F4")?.display == "⌥F4")
        #expect(KeyBinding("tap:cmd") == .tap(.cmd))
        #expect(KeyBinding("tap:win") == .tap(.cmd))
        #expect(KeyBinding("cmd+nosuchkey") == nil)
        #expect(KeyBinding("hyper+left") == nil)
        #expect(KeyBinding([.alt], "f4").chord != nil)
        #expect(KeyBinding.tap(.cmd).chord == nil)
    }

    @Test func turningAShortcutOffIsStored() throws {
        let store = SettingsStore(url: nil)
        try store.set(Shortcut.fullScreen.setting, nil)
        #expect(store[Shortcut.fullScreen.setting] == nil)
        #expect(!store.isDefault(Shortcut.fullScreen.setting))
    }

    @Test func conflictsAreFound() throws {
        let store = SettingsStore(url: nil)
        #expect(ShortcutConflicts.check(store, macOS: [:]).isEmpty) // the shipped defaults collide with nothing
        try store.set(Shortcut.snapLeft.setting, KeyBinding([.cmd], "left"))
        try store.set(Shortcut.snapRight.setting, KeyBinding([.ctrl, .cmd], "f"))
        let conflicts = ShortcutConflicts.check(store, macOS: [:])
        #expect(conflicts.contains { $0.shortcut == .snapLeft && $0.systemMeaning == "Line start in text" })
        #expect(conflicts.contains { $0.shortcut == .snapRight && $0.other == .fullScreen })
    }

    @Test func catalogIsConsistent() {
        let ids = PaneSettings.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate setting ids")
        for s in PaneSettings.all { #expect(s.accepts(s.defaultJSON), "\(s.id) default fails its own validation") }
        let legacy = PaneSettings.all.compactMap(\.info.legacyKey)
        #expect(Set(legacy).count == legacy.count)
        #expect(!PaneSettings.settings(in: .taskbar).isEmpty)
        #expect(PaneSettings.settings(in: .taskbar).allSatisfy { $0.info.status != .planned })
    }

    @Test func fileEditsReachObservers() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        try store.set(PaneSettings.clickThrough, false) // creates the file
        store.watchFile()
        defer { store.stopWatching() }
        var heard: [String] = []
        let token = store.observe(PaneSettings.combineButtons) { heard.append($0) }
        try #"{"version": 2, "settings": {"taskbar.combineButtons": "never"}}"#.data(using: .utf8)!.write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(3)
        while heard.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(heard == ["never"])
        #expect(store[PaneSettings.clickThrough] == true) // the edit dropped it: back to the default
        _ = token
    }
}

@Suite("Settings by id")
@MainActor
struct SettingsByIDTests {
    @Test func everySettingRoundTripsByID() throws {
        let store = SettingsStore(url: nil)
        for s in PaneSettings.all {
            #expect(store.json(s.id) == s.defaultJSON, "\(s.id) default")
            try store.set(id: s.id, json: s.defaultJSON) // the default: nothing stored
            #expect(store.isDefault(id: s.id))
        }
        try store.set(id: PaneSettings.combineButtons.id, json: .string("never"))
        #expect(store[PaneSettings.combineButtons] == "never")
        #expect(throws: SettingsError.invalid(id: PaneSettings.combineButtons.id)) { try store.set(id: PaneSettings.combineButtons.id, json: .string("sometimes")) }
        #expect(throws: SettingsError.invalid(id: "no.such")) { try store.set(id: "no.such", json: .bool(true)) }
        store.reset(id: PaneSettings.combineButtons.id)
        #expect(store.isDefault(id: PaneSettings.combineButtons.id))
    }

    @Test func perAppByID() throws {
        let store = SettingsStore(url: nil)
        var heard: [String] = []
        let token = store.observeAll { heard.append($0) }
        try store.setOverride(id: PaneSettings.hideFromTaskbar.id, json: .bool(true), for: "com.x")
        #expect(store.json(PaneSettings.hideFromTaskbar.id, for: "com.x") == .bool(true))
        #expect(store.appsWithOverrides().contains("com.x") && store.appsWithOverrides().contains("com.vmware.fusion"))
        #expect(store.overrides(for: "com.x").keys.contains(PaneSettings.hideFromTaskbar.id))
        #expect(throws: SettingsError.notPerApp(id: PaneSettings.alignment.id)) { try store.setOverride(id: PaneSettings.alignment.id, json: .string("left"), for: "com.x") }
        store.removeOverrides(for: "com.x")
        #expect(store.overrides(for: "com.x").isEmpty && !store.appsWithOverrides().contains("com.x"))
        #expect(store.json(PaneSettings.ignoreShortcuts.id, for: "com.vmware.fusion") == .string("always")) // built in
        #expect(heard.count == 2)
        _ = token
    }

    @Test func dependenciesAndSearch() {
        for (child, parent) in PaneSettings.dependsOn {
            #expect(PaneSettings.setting(id: child) != nil && PaneSettings.setting(id: parent.id) != nil, "\(child) → \(parent.id)")
        }
        #expect(PaneSettings.search("hide taskbar").map(\.id) == [PaneSettings.autoHide.id])
        #expect(PaneSettings.search("win+i").contains { $0.id == Shortcut.settings.setting.id })
        #expect(PaneSettings.search("taskbar").count > 5)
        #expect(PaneSettings.search("").isEmpty)
    }
}

@Suite("Shortcut conflicts by keyboard")
@MainActor
struct ShortcutConflictModeTests {
    @Test func theUsersMacOSShortcutsCount() throws {
        let store = SettingsStore(url: nil)
        try store.set(Shortcut.snapLeft.setting, KeyBinding([.ctrl, .alt], "left"))
        let mine = [KeyBinding([.ctrl, .alt], "left"): "Move left a space"]
        #expect(ShortcutConflicts.check(store, macOS: mine).contains { $0.shortcut == .snapLeft && $0.systemMeaning == "macOS: Move left a space" })
        _ = ShortcutConflicts.macOSShortcuts() // reads this Mac's settings without crashing
    }
}

@Suite("What pane changes")
@MainActor
struct SystemChangesTests {
}

@Suite("Entry points and onboarding settings")
@MainActor
struct EntryPointSettingsTests {
    @Test func onboardingVersion() throws {
        let store = SettingsStore(url: nil)
        #expect(Onboarding.isNeeded(store))
        try Onboarding.markDone(store)
        #expect(!Onboarding.isNeeded(store))
        try store.reset(id: PaneSettings.onboardingDone.id) // "Show welcome again"
        #expect(Onboarding.isNeeded(store))
    }
}


@Suite("Settings window pages")
struct SettingsPagesTests {
    @Test func everySettingIsOnOnePage() {
        var count: [String: Int] = [:]
        for page in SettingsPages.all { for group in page.groups { for id in group.ids { count[id, default: 0] += 1 } } }
        let unknown = count.keys.filter { PaneSettings.setting(id: $0) == nil }
        #expect(unknown.isEmpty, "\(unknown)")
        #expect(count.filter { $0.value > 1 }.isEmpty)
        let missing = PaneSettings.all.map(\.id).filter { id in
            count[id] == nil && !SettingsPages.exceptionColumns.contains(id) && !SettingsPages.internalIDs.contains(id)
        }
        #expect(missing.isEmpty, "not on any page: \(missing)")
        #expect(SettingsPages.exceptionColumns.allSatisfy { PaneSettings.setting(id: $0)?.info.perApp == true })
        #expect(SettingsPages.page("Taskbar")?.title == "Taskbar" && SettingsPages.page("shortcuts")?.id == "keyboard")
        #expect(SettingsPages.page(containing: PaneSettings.takeOverTiling.id)?.id == "multitasking")
    }
}
