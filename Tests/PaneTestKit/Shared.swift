// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Backup location shared by test runs, so a crashed run's Dock changes are restored by the next run.
public enum TestSystemSettings {
    public static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pane/test-system-settings-backup.plist")
    public static func recoverIfNeeded() {
        let settings = SystemSettings(backupURL: url)
        if settings.hasPendingBackup { DockReservation(settings: settings).restore() }
    }
}

public extension MainActor {
    /// Reads main-actor state from a polling closure on a background task.
    static func assumeIsolatedOrSync<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
