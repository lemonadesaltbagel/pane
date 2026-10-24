// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Start menu engine: installed apps and search (the UI is separate).
public struct AppEntry: Equatable {
    public let name: String
    public let bundleID: String?
    public let url: URL

    public init(name: String, bundleID: String?, url: URL) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
    }
}

public final class AppCatalog {
    public private(set) var apps: [AppEntry] = []
    public static let defaultRoots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                      NSHomeDirectory() + "/Applications"]

    public init() {}

    /// Scans the app folders (one level of subfolders, e.g. /Applications/Utilities).
    @discardableResult
    public func reload(roots: [String] = AppCatalog.defaultRoots) -> [AppEntry] {
        var seen = Set<String>()
        var found: [AppEntry] = []
        let fm = FileManager.default
        func add(_ url: URL) {
            guard url.pathExtension == "app", seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            let bundle = Bundle(url: url)
            let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            found.append(AppEntry(name: name, bundleID: bundle?.bundleIdentifier, url: url))
        }
        for root in roots {
            for item in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" { add(item) } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for sub in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] { add(sub) }
                }
            }
        }
        apps = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps
    }

    /// Windows-Start-style search: prefix of the name, then prefix of any word, then substring, then
    /// initials ("vsc" → Visual Studio Code).
    public func search(_ query: String, limit: Int = 8) -> [AppEntry] {
        Self.rank(apps, query).prefix(limit).map { $0 }
    }

    public static func rank(_ apps: [AppEntry], _ query: String) -> [AppEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        func score(_ app: AppEntry) -> Int? {
            let name = app.name.lowercased()
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if name.hasPrefix(q) { return 0 }
            if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
            if name.contains(q) { return 2 }
            if String(words.compactMap(\.first)).hasPrefix(q) { return 3 }
            return nil
        }
        return apps.compactMap { app in score(app).map { (app, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name.count < $1.0.name.count }
            .map(\.0)
    }
}
