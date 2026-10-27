// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ServiceManagement

/// "Pause pane" (setting `general.paused`): every key and mouse handler of pane lets events through untouched and
/// quit-on-last-window stops deciding. pane's own taskbar and tray keep working. Read per event: keep it cheap.
public enum Pause {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false
    public static var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// "Start pane at login" (setting `general.launchAtLogin`): a LaunchAgent for the running binary (`.build/debug/pane`
/// and other unbundled builds); a packaged Pane.app should use `SMAppService.mainApp` instead (yours, with packaging).
/// `directory` is ~/Library/LaunchAgents; tests point PANE_LAUNCH_AGENTS_DIR elsewhere.
public enum LoginItem {
    public static let label = "dev.pane.agent"

    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["PANE_LAUNCH_AGENTS_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }
    public static var plistURL: URL { directory.appendingPathComponent("\(label).plist") }

    /// An app starts at login through `SMAppService` (System Settings ▸ General ▸ Login Items lists it); a bare binary
    /// through a LaunchAgents plist. A test pointing `PANE_LAUNCH_AGENTS_DIR` somewhere always gets the plist.
    static var usesService: Bool { AppBundle.isApp && ProcessInfo.processInfo.environment["PANE_LAUNCH_AGENTS_DIR"] == nil }

    /// On, or waiting for your approval in Login Items.
    public static var isEnabled: Bool {
        if usesService { return [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// For diagnostics: "on", "off", "waiting for approval in Login Items", "plist at …".
    public static var status: String {
        guard usesService else { return isEnabled ? "plist at \(plistURL.path)" : "off (plist)" }
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval in Login Items"
        case .notRegistered: return "off"
        case .notFound: return "not found (the app isn't where macOS expects it)"
        @unknown default: return "unknown"
        }
    }

    /// Turns start at login on or off. `executable`: what the plist starts (default: this process's binary).
    @discardableResult
    public static func set(_ enabled: Bool, executable: String = CommandLine.arguments[0]) -> Bool {
        if usesService {
            // An older pane's plist would start a second copy at login.
            if FileManager.default.fileExists(atPath: plistURL.path) { try? FileManager.default.removeItem(at: plistURL) }
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return true
            } catch { return false }
        }
        if !enabled {
            guard isEnabled else { return true }
            return (try? FileManager.default.removeItem(at: plistURL)) != nil
        }
        let path = URL(fileURLWithPath: executable).standardizedFileURL.path
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [path], "RunAtLoad": true, "KeepAlive": false,
                                    "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch { return false }
    }
}

/// Recording a shortcut in the settings window (E8): pane's own key handling stands down (so ⌥Tab or ⌘Tab can be
/// recorded instead of acting), and macOS's ⌘Tab / ⌘⇧Tab are off for the moment; `end()` puts them back as they were.
public enum ShortcutRecording {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false
    nonisolated(unsafe) private static var saved: [PrivateAPI.SymbolicHotKey: Bool] = [:]
    public static var isOn: Bool { lock.withLock { on } }

    public static func begin() {
        lock.withLock {
            guard !on else { return }
            on = true
            for key in [PrivateAPI.SymbolicHotKey.commandTab, .commandShiftTab] {
                saved[key] = PrivateAPI.isSymbolicHotKeyEnabled(key) ?? true
                PrivateAPI.setSymbolicHotKey(key, enabled: false)
            }
        }
    }

    public static func end() {
        lock.withLock {
            guard on else { return }
            on = false
            for (key, enabled) in saved { PrivateAPI.setSymbolicHotKey(key, enabled: enabled) }
            saved = [:]
        }
    }
}
