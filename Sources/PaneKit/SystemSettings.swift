// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Changes other apps' preferences (Dock, WindowManager, …) with a crash-safe backup: the original values
/// are written to disk *before* anything is changed, and `restore()` puts them back — on quit, or on the next
/// launch if pane died without restoring.
public final class SystemSettings {
    public struct Change: Equatable {
        public let domain: String
        public let key: String
        public let value: PropertyListValue

        public init(_ domain: String, _ key: String, _ value: PropertyListValue) {
            self.domain = domain
            self.key = key
            self.value = value
        }
    }

    /// The plist types pane writes.
    public enum PropertyListValue: Equatable {
        case bool(Bool), int(Int), double(Double), string(String)

        var object: CFPropertyList {
            switch self {
            case .bool(let v): return v as CFBoolean
            case .int(let v): return v as CFNumber
            case .double(let v): return v as CFNumber
            case .string(let v): return v as CFString
            }
        }
    }

    public static let globalDomain = kCFPreferencesAnyApplication as String

    private let backupURL: URL
    /// Called after writing to a domain whose owner must restart to pick changes up (e.g. "com.apple.dock").
    public var restartHandler: (String) -> Void = { SystemSettings.restartOwner($0) }

    public init(backupURL: URL = SystemSettings.defaultBackupURL) {
        self.backupURL = backupURL
    }

    public static var defaultBackupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pane/system-settings-backup.plist")
    }

    /// True when a previous run applied changes and never restored them (crash, kill -9).
    public var hasPendingBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    public static func read(_ domain: String, _ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    /// Backs up the current values of every key about to change (only the first time — a pending backup
    /// from a crashed run is kept, so the user's *original* values survive), then writes the new values.
    public func apply(_ changes: [Change]) throws {
        var backup = loadBackup() ?? [:]
        for change in changes {
            let id = "\(change.domain)\u{1F}\(change.key)"
            if backup[id] == nil {
                var entry: [String: Any] = ["domain": change.domain, "key": change.key, "existed": false]
                if let current = Self.read(change.domain, change.key) {
                    entry["value"] = current
                    entry["existed"] = true
                }
                backup[id] = entry
            }
        }
        try saveBackup(backup)
        write(changes.map { ($0.domain, $0.key, $0.value.object as Any?) })
    }

    /// Puts every backed-up value back (deleting keys that didn't exist) and removes the backup.
    @discardableResult
    public func restore() -> Bool {
        guard let backup = loadBackup() else { return false }
        let entries = backup.values.compactMap { entry -> (String, String, Any?)? in
            guard let domain = entry["domain"] as? String, let key = entry["key"] as? String else { return nil }
            let existed = entry["existed"] as? Bool ?? false
            return (domain, key, existed ? entry["value"] : nil)
        }
        write(entries)
        try? FileManager.default.removeItem(at: backupURL)
        return true
    }

    private func write(_ entries: [(String, String, Any?)]) {
        var domains = Set<String>()
        for (domain, key, value) in entries {
            CFPreferencesSetAppValue(key as CFString, value.map { $0 as CFPropertyList }, domain as CFString)
            domains.insert(domain)
        }
        for domain in domains {
            CFPreferencesAppSynchronize(domain as CFString)
            restartHandler(domain)
        }
    }

    private func loadBackup() -> [String: [String: Any]]? {
        guard let data = try? Data(contentsOf: backupURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return nil }
        return plist
    }

    private func saveBackup(_ backup: [String: [String: Any]]) throws {
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .xml, options: 0)
        try data.write(to: backupURL, options: .atomic)
    }

    /// Domains whose owning process only reads preferences at launch. `force`: stop it without letting it save its own
    /// copy of its settings on the way out (SIGKILL; launchd starts it again) — the Dock saves its pinned apps when
    /// stopped normally, which undid a change written just before (measured, DockPins).
    public static func restartOwner(_ domain: String, force: Bool = false) {
        let process: String? = switch domain {
        case "com.apple.dock": "Dock"
        default: nil
        }
        guard let process else { return }
        // A restarting Dock gives back every minimized window (the Dock owns them; measured: StartupAdoptionTests).
        // Note which windows are minimized and minimize the ones that come back.
        let minimized = process == "Dock" ? MinimizedWindows.snapshot() : []
        let oldDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = force ? ["-KILL", process] : [process]
        try? kill.run()
        kill.waitUntilExit()
        if !minimized.isEmpty { MinimizedWindows.keepMinimized(minimized, oldDock: oldDock) }
    }
}

/// Minimized windows across apps, kept minimized through a Dock restart.
enum MinimizedWindows {
    static func snapshot() -> [AXUIElement] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.flatMap { app in
            AX.windows(of: app.processIdentifier).filter { AX.get($0, kAXMinimizedAttribute) == true }
        }
    }

    /// Waits for the new Dock, then for about 1.5 s re-minimizes any of `windows` that came back (they return a moment
    /// after the Dock starts). At most ~4 s in all.
    static func keepMinimized(_ windows: [AXUIElement], oldDock: pid_t?) {
        let deadline = Date().addingTimeInterval(4)
        var dockBackAt: Date?
        var reminimized = 0
        while Date() < deadline {
            if dockBackAt == nil, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
               dock.processIdentifier != oldDock, !dock.isTerminated {
                dockBackAt = Date()
            }
            if dockBackAt != nil {
                for window in windows where AX.get(window, kAXMinimizedAttribute) == false {
                    AX.set(window, kAXMinimizedAttribute, kCFBooleanTrue)
                    reminimized += 1
                }
                if let since = dockBackAt, Date().timeIntervalSince(since) > 1.5 { break }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if reminimized > 0 { PaneLog.write("kept \(reminimized) minimized window(s) minimized through the Dock restart") }
    }
}
