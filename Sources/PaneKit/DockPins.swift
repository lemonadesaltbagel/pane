// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// The macOS Dock's pinned apps (`com.apple.dock` `persistent-apps`), for the setting "Sync pinned apps with the Dock"
/// (`taskbar.syncDockPins`). The Dock reads this list only when it starts, so a change restarts it
/// (`SystemSettings.restartOwner`, which keeps minimized windows minimized through the restart).
public enum DockPins {
    static let domain = "com.apple.dock"
    static let key = "persistent-apps"

    /// Bundle IDs pinned in the Dock, in Dock order.
    public static func read() -> [String] {
        bundleIDs(in: entries())
    }

    static func entries() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain as CFString)
        return (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]]) ?? []
    }

    static func bundleIDs(in entries: [[String: Any]]) -> [String] {
        entries.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
    }

    /// The Dock's entries after making its apps `pinned`: entries for apps still pinned keep their place (and all their
    /// data), entries for apps no longer pinned go, new apps are added at the end in `pinned` order. Entries without a
    /// bundle ID (not apps) are kept.
    public static func updated(_ entries: [[String: Any]], pinned: [String], url: (String) -> URL?, name: (String) -> String?) -> [[String: Any]] {
        let wanted = Set(pinned)
        var result = entries.filter { entry in
            guard let id = (entry["tile-data"] as? [String: Any])?["bundle-identifier"] as? String else { return true }
            return wanted.contains(id)
        }
        let present = Set(bundleIDs(in: result))
        for id in pinned where !present.contains(id) {
            guard let appURL = url(id) else { continue } // the Dock needs the app's location
            result.append(entry(bundleID: id, url: appURL, label: name(id) ?? appURL.deletingPathExtension().lastPathComponent))
        }
        return result
    }

    /// A Dock app tile (the fields `dockutil` writes; the Dock fills in the rest).
    static func entry(bundleID: String, url: URL, label: String) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["bundle-identifier": bundleID, "file-label": label, "file-type": 41,
                       "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]]]
    }

    /// Makes the Dock's pinned apps `pinned` and restarts the Dock when anything changed. Returns whether it changed.
    @discardableResult
    public static func write(_ pinned: [String]) -> Bool {
        let current = entries()
        // Where the app is: Launch Services, else the running copy (apps outside the usual folders).
        func location(_ id: String) -> URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL
        }
        let name: (String) -> String? = { id in location(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } }
        let wanted = bundleIDs(in: updated(current, pinned: pinned, url: location, name: name))
        guard wanted != bundleIDs(in: current) else { return false }
        for _ in 0..<3 {
            if apply(updated(entries(), pinned: pinned, url: location, name: name), until: { bundleIDs(in: entries()) == wanted }) { return true }
        }
        TrayLog.write("dock-pins: the Dock kept overwriting its pinned apps")
        return true
    }

    /// Puts back an exact copy of the Dock's pinned apps (tests restore your list with it).
    @discardableResult
    public static func restore(_ original: [[String: Any]]) -> Bool {
        let wanted = bundleIDs(in: original)
        for _ in 0..<3 where apply(original, until: { bundleIDs(in: entries()) == wanted }) { return true }
        return false
    }

    /// Writes the list and restarts the Dock without letting it save its own copy on the way out (it saves its pinned
    /// apps when stopped normally, which undid an unpin written right after a pin — measured). Done when `holds` stays
    /// true for 2 s after the restart.
    static func apply(_ list: [[String: Any]], until holds: () -> Bool) -> Bool {
        CFPreferencesSetAppValue(key as CFString, list as CFArray, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        SystemSettings.restartOwner(domain, force: true)
        var heldSince: Date?
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if holds() {
                if heldSince == nil { heldSince = Date() }
                if Date().timeIntervalSince(heldSince!) >= 2 { return true }
            } else { heldSince = nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
