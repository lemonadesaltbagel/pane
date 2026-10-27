// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import CoreServices

/// The Start menu's app index: every installed app with its category, kept current
/// by watching the app folders (FSEvents), with launch counts and first-seen dates from `StartStore`.
@MainActor
public final class AppIndex {
    public struct App: Equatable, Identifiable, Sendable {
        /// Bundle ID, or the path for an app without one (the id pins and stats use).
        public let id: String
        public let name: String
        public let bundleID: String?
        public let url: URL
        /// Windows-style group for the All ▸ Category view.
        public let category: String
        /// In /System (Apple's own apps: never shown as recently added — OS updates touch them).
        public let isSystem: Bool
    }

    public static let categories = ["Productivity", "Creativity", "Information & reading", "Social", "Entertainment",
                                    "Games", "Utilities & tools", "Developer tools", "Other"]

    public private(set) var apps: [App] = []
    public var onChange: (() -> Void)?
    public let roots: [String]
    public let store: StartStore
    private var stream: FSEventStreamRef?
    private var launchObserver: NSObjectProtocol?
    private var icons: [URL: NSImage] = [:]
    private var categoryCache: [String: (Date, String)] = [:]
    private var pendingReload = false

    public static let defaultRoots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                      NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Finder.app"]

    /// `PANE_START_APP_ROOTS` (colon-separated) adds folders: tests index the fixture app, so launching from Start
    /// never opens one of your apps.
    public init(roots: [String] = AppIndex.defaultRoots, store: StartStore) {
        let extra = (ProcessInfo.processInfo.environment["PANE_START_APP_ROOTS"] ?? "").split(separator: ":").map(String.init)
        self.roots = roots + extra
        self.store = store
    }

    // MARK: Scanning

    /// Scans the roots (one level of subfolders). Returns true when the list changed.
    @discardableResult
    public func reload() -> Bool {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [App] = []
        func add(_ url: URL) {
            guard url.pathExtension == "app", seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary
            let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleDisplayName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let id = bundle?.bundleIdentifier ?? url.path
            found.append(App(id: id, name: name, bundleID: bundle?.bundleIdentifier, url: url,
                             category: category(url, info), isSystem: url.path.hasPrefix("/System/")))
        }
        for root in roots {
            let url = URL(fileURLWithPath: root)
            if url.pathExtension == "app" { if fm.fileExists(atPath: root) { add(url) }; continue }
            for item in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if item.pathExtension == "app" { add(item) }
                else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !item.lastPathComponent.hasPrefix(".") {
                    for sub in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] { add(sub) }
                }
            }
        }
        // One entry per bundle ID (an app in two places: the first root wins).
        var ids = Set<String>()
        found = found.filter { ids.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        store.noteSeen(found.map(\.id)) { [found] id in found.first { $0.id == id }.flatMap { Self.spotlightUseCount($0.url) } }
        guard found != apps else { return false }
        apps = found
        onChange?()
        return true
    }

    /// Watches the roots; a change reloads (coalesced, ~0.3 s), so an installed or removed app shows within a second.
    public func startWatching() {
        guard stream == nil else { return }
        reload()
        observeLaunches()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let index = Unmanaged<AppIndex>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { index.scheduleReload() } }
        }
        let paths = roots.map { $0.hasSuffix(".app") ? ($0 as NSString).deletingLastPathComponent : $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    public func stopWatching() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }

    private func scheduleReload() {
        guard !pendingReload else { return }
        pendingReload = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingReload = false
                self?.reload()
            }
        }
    }

    /// Every app launch counts (Most used, the Category view's order, search ranking) — however it was started.
    private func observeLaunches() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular,
                  let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.store.recordLaunch(id) }
        }
    }

    static func spotlightUseCount(_ url: URL) -> Int? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
    }

    // MARK: Lookups

    public func app(_ id: String) -> App? { apps.first { $0.id == id } }

    public func icon(_ app: App) -> NSImage {
        if let cached = icons[app.url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        icons[app.url] = image
        return image
    }

    public func launches(_ id: String) -> Int { store.data.launches[id] ?? 0 }

    /// Most launched first (ties: most recently launched), only apps launched at least once.
    public func mostUsed(limit: Int = 6) -> [App] {
        apps.filter { launches($0.id) > 0 }.sorted {
            launches($0.id) != launches($1.id) ? launches($0.id) > launches($1.id)
                : (store.data.lastLaunch[$0.id] ?? .distantPast) > (store.data.lastLaunch[$1.id] ?? .distantPast)
        }.prefix(limit).map { $0 }
    }

    /// Apps first seen in the last `days` days (not Apple's own: OS updates touch them), newest first.
    public func recentlyAdded(days: Double = 7, now: Date = Date()) -> [App] {
        apps.filter { app in
            guard !app.isSystem, let seen = store.data.firstSeen[app.id] else { return false }
            return now.timeIntervalSince(seen) < days * 86_400
        }.sorted { (store.data.firstSeen[$0.id] ?? .distantPast) > (store.data.firstSeen[$1.id] ?? .distantPast) }
    }

    /// The Category view: Windows folds a category with fewer than 3 apps into Other; most-used apps first.
    public func byCategory() -> [(name: String, apps: [App])] {
        var groups: [String: [App]] = [:]
        for app in apps { groups[app.category, default: []].append(app) }
        var other = groups.removeValue(forKey: "Other") ?? []
        for (name, list) in groups where list.count < 3 { other += list; groups[name] = nil }
        if !other.isEmpty { groups["Other"] = other }
        func order(_ list: [App]) -> [App] {
            list.sorted { launches($0.id) != launches($1.id) ? launches($0.id) > launches($1.id)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Self.categories.compactMap { name in groups[name].map { (name: name, apps: order($0)) } }
    }

    /// The Grid and List views: A–Z under letter headers ("#" for digits and symbols, first).
    public func byLetter() -> [(letter: String, apps: [App])] {
        var groups: [String: [App]] = [:]
        for app in apps { groups[Self.letter(app.name), default: []].append(app) }
        return groups.keys.sorted { a, b in a == "#" ? b != "#" : (b == "#" ? false : a < b) }.map { (letter: $0, apps: groups[$0]!) }
    }

    nonisolated public static func letter(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first, first.isLetter, first.isASCII else { return "#" }
        return String(first).uppercased()
    }

    // MARK: Categories

    private func category(_ url: URL, _ info: [String: Any]?) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let (date, cached) = categoryCache[url.path], date == modified { return cached }
        let value = Self.category(appStore: info?["LSApplicationCategoryType"] as? String, path: url.path)
        categoryCache[url.path] = (modified, value)
        return value
    }

    /// Apple's App Store categories (`LSApplicationCategoryType`) → Windows 11's Start categories.
    nonisolated public static func category(appStore: String?, path: String) -> String {
        let c = (appStore ?? "").replacingOccurrences(of: "public.app-category.", with: "")
        switch c {
        case "productivity", "business", "finance": return "Productivity"
        case "graphics-design", "photography", "video": return "Creativity"
        case "news", "reference", "books", "weather", "travel", "education", "medical", "healthcare-fitness", "sports", "navigation", "lifestyle":
            return "Information & reading"
        case "social-networking": return "Social"
        case "entertainment", "music": return "Entertainment"
        case "developer-tools": return "Developer tools"
        case "utilities": return "Utilities & tools"
        default:
            if c == "games" || c.hasSuffix("-games") { return "Games" }
            if path.contains("/Utilities/") || path.hasPrefix("/System/Library/CoreServices") { return "Utilities & tools" }
            return "Other"
        }
    }
}
