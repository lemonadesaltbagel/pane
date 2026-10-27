// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import Testing
import PaneKit
import PaneTestKit

/// Uses a throwaway preferences domain, never the user's real ones.
@Suite("System settings (backup/apply/restore)", .serialized)
struct SystemSettingsTests {
    let domain = "dev.pane.tests.settings"

    func make() -> (SystemSettings, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-settings-\(UUID().uuidString).plist")
        let settings = SystemSettings(backupURL: url)
        settings.restartHandler = { _ in }
        return (settings, url)
    }

    func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value.map { $0 as CFPropertyList }, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    @Test func applyThenRestoreReturnsOriginalValuesAndRemovesNewKeys() throws {
        let (settings, url) = make()
        defer { try? FileManager.default.removeItem(at: url); set("existing", nil); set("absent", nil) }
        set("existing", 68)
        set("absent", nil)

        try settings.apply([.init(domain, "existing", .int(28)), .init(domain, "absent", .bool(false))])
        #expect(SystemSettings.read(domain, "existing") as? Int == 28)
        #expect(SystemSettings.read(domain, "absent") as? Bool == false)
        #expect(settings.hasPendingBackup)

        #expect(settings.restore())
        #expect(SystemSettings.read(domain, "existing") as? Int == 68)
        #expect(SystemSettings.read(domain, "absent") == nil)
        #expect(!settings.hasPendingBackup)
    }

    @Test func aSecondApplyKeepsTheUsersOriginalNotPanesValue() throws {
        // Simulates: pane applied, crashed, relaunched and applied again before restoring.
        let (settings, url) = make()
        defer { try? FileManager.default.removeItem(at: url); set("size", nil) }
        set("size", 68)
        try settings.apply([.init(domain, "size", .int(28))])
        try SystemSettings(backupURL: url).apply([.init(domain, "size", .int(30))])
        let relaunched = SystemSettings(backupURL: url)
        relaunched.restartHandler = { _ in }
        #expect(relaunched.hasPendingBackup)
        relaunched.restore()
        #expect(SystemSettings.read(domain, "size") as? Int == 68)
    }

    @Test func restoringSomeKeysKeepsTheOthersAndTheirBackup() throws {
        // A live setting turned off (an extension's change), while pane's own changes stay.
        let (settings, url) = make()
        defer { try? FileManager.default.removeItem(at: url); set("kept", nil); set("live", nil) }
        set("kept", 68)
        set("live", true)
        try settings.apply([.init(domain, "kept", .int(28)), .init(domain, "live", .bool(false))])
        settings.restore([.init(domain, "live", .bool(false))])
        #expect(SystemSettings.read(domain, "live") as? Bool == true)
        #expect(SystemSettings.read(domain, "kept") as? Int == 28)
        #expect(settings.hasPendingBackup)
        // Turned on again: backed up afresh; the full restore still puts everything back.
        try settings.apply([.init(domain, "live", .bool(false))])
        #expect(settings.restore())
        #expect(SystemSettings.read(domain, "kept") as? Int == 68)
        #expect(SystemSettings.read(domain, "live") as? Bool == true)
        // The last key restored removes the backup.
        try settings.apply([.init(domain, "live", .bool(false))])
        settings.restore([.init(domain, "live", .bool(false))])
        #expect(!settings.hasPendingBackup)
    }

    @Test func restartHandlerRunsOncePerDomain() throws {
        let (settings, url) = make()
        defer { try? FileManager.default.removeItem(at: url); set("a", nil); set("b", nil) }
        var restarted: [String] = []
        settings.restartHandler = { restarted.append($0) }
        try settings.apply([.init(domain, "a", .int(1)), .init(domain, "b", .int(2))])
        #expect(restarted == [domain])
        settings.restore()
    }
}
