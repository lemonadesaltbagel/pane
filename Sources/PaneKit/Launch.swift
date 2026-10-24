// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

public enum Launcher {
    /// `createsNewApplicationInstance` is the public equivalent of `open -n` (Windows "launch again").
    public static func open(_ bundle: URL, arguments: [String] = [], newInstance: Bool, activate: Bool) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = newInstance
        configuration.activates = activate
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    }

    /// The macOS-faithful version of "launch again": a new window in the running process, via the app's own
    /// menu item found through AX (works without the app being frontmost).
    @discardableResult
    public static func pressNewWindow(pid: pid_t, path: [String] = ["File", "New Window"]) -> Bool {
        guard let item = AX.menuItem(of: pid, path: path) else { return false }
        return AX.perform(item, kAXPressAction) == .success
    }
}
