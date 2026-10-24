// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// What Start's search finds (research/plan-start-menu.md E4, D3: local only).
public struct StartResult: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case app, systemSetting, paneSetting, file, folder }
    public let kind: Kind
    /// Unique within a result list: "app:<id>", "setting:<pane id>", "pane:<setting id>", "file:<path>".
    public let id: String
    public let title: String
    /// Under the title: "App", "System Settings", "pane Settings ▸ Multitasking", a folder path.
    public let subtitle: String
    /// Apps and files: where they are. System Settings: the pane's URL.
    public let url: URL?
    /// pane settings: the Settings page to open; apps: the app id.
    public let target: String
}

/// System Settings panes (ids checked on this Mac: /System/Library/ExtensionKit/Extensions), with the names its
/// sidebar shows and words people search for. `available` keeps only the panes this Mac has.
public enum SystemSettingsPanes {
    public struct Pane: Equatable, Sendable {
        public let id: String
        public let name: String
        public let keywords: [String]
        public var url: URL { URL(string: "x-apple.systempreferences:\(id)")! }
    }

    static let table: [Pane] = [
        .init(id: "com.apple.wifi-settings-extension", name: "Wi-Fi", keywords: ["wifi", "wireless", "internet"]),
        .init(id: "com.apple.BluetoothSettings", name: "Bluetooth", keywords: ["headphones", "pair"]),
        .init(id: "com.apple.Network-Settings.extension", name: "Network", keywords: ["ethernet", "proxy", "dns", "ip"]),
        .init(id: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", name: "VPN", keywords: []),
        .init(id: "com.apple.Battery-Settings.extension", name: "Battery", keywords: ["power", "energy", "sleep"]),
        .init(id: "com.apple.SystemProfiler.AboutExtension", name: "About", keywords: ["system information", "serial", "version", "this mac"]),
        .init(id: "com.apple.Software-Update-Settings.extension", name: "Software Update", keywords: ["update", "windows update", "upgrade"]),
        .init(id: "com.apple.settings.Storage", name: "Storage", keywords: ["disk", "space"]),
        .init(id: "com.apple.AirDrop-Handoff-Settings.extension", name: "AirDrop & Handoff", keywords: ["airdrop", "handoff", "nearby sharing"]),
        .init(id: "com.apple.LoginItems-Settings.extension", name: "Login Items & Extensions", keywords: ["startup apps", "login items"]),
        .init(id: "com.apple.Localization-Settings.extension", name: "Language & Region", keywords: ["language", "region", "time format"]),
        .init(id: "com.apple.Date-Time-Settings.extension", name: "Date & Time", keywords: ["clock", "time zone"]),
        .init(id: "com.apple.Sharing-Settings.extension", name: "Sharing", keywords: ["file sharing", "remote", "computer name"]),
        .init(id: "com.apple.Time-Machine-Settings.extension", name: "Time Machine", keywords: ["backup"]),
        .init(id: "com.apple.Transfer-Reset-Settings.extension", name: "Transfer or Reset", keywords: ["erase", "reset this pc"]),
        .init(id: "com.apple.Startup-Disk-Settings.extension", name: "Startup Disk", keywords: []),
        .init(id: "com.apple.Accessibility-Settings.extension", name: "Accessibility", keywords: ["ease of access", "zoom", "voiceover", "contrast"]),
        .init(id: "com.apple.Appearance-Settings.extension", name: "Appearance", keywords: ["dark mode", "light mode", "accent color", "theme"]),
        .init(id: "com.apple.ControlCenter-Settings.extension", name: "Control Center", keywords: ["menu bar", "quick settings"]),
        .init(id: "com.apple.Siri-Settings.extension", name: "Apple Intelligence & Siri", keywords: ["siri", "cortana", "copilot"]),
        .init(id: "com.apple.Spotlight-Settings.extension", name: "Spotlight", keywords: ["search", "indexing"]),
        .init(id: "com.apple.settings.PrivacySecurity.extension", name: "Privacy & Security", keywords: ["permissions", "accessibility permission", "screen recording", "firewall", "filevault"]),
        .init(id: "com.apple.Desktop-Settings.extension", name: "Desktop & Dock", keywords: ["dock", "stage manager", "mission control", "hot corners", "tiling"]),
        .init(id: "com.apple.Displays-Settings.extension", name: "Displays", keywords: ["resolution", "brightness", "night shift", "monitor", "scale"]),
        .init(id: "com.apple.Wallpaper-Settings.extension", name: "Wallpaper", keywords: ["background", "desktop picture"]),
        .init(id: "com.apple.Screen-Saver-Settings.extension", name: "Screen Saver", keywords: []),
        .init(id: "com.apple.Notifications-Settings.extension", name: "Notifications", keywords: ["alerts", "banners"]),
        .init(id: "com.apple.Sound-Settings.extension", name: "Sound", keywords: ["volume", "audio", "speakers", "microphone", "output"]),
        .init(id: "com.apple.Focus-Settings.extension", name: "Focus", keywords: ["do not disturb"]),
        .init(id: "com.apple.Screen-Time-Settings.extension", name: "Screen Time", keywords: ["parental controls"]),
        .init(id: "com.apple.Lock-Screen-Settings.extension", name: "Lock Screen", keywords: ["screen saver", "password after sleep"]),
        .init(id: "com.apple.Touch-ID-Settings.extension", name: "Touch ID & Password", keywords: ["fingerprint", "password", "sign-in options"]),
        .init(id: "com.apple.Users-Groups-Settings.extension", name: "Users & Groups", keywords: ["accounts", "users", "family & other users"]),
        .init(id: "com.apple.Internet-Accounts-Settings.extension", name: "Internet Accounts", keywords: ["email accounts", "google"]),
        .init(id: "com.apple.Game-Center-Settings.extension", name: "Game Center", keywords: []),
        .init(id: "com.apple.Keyboard-Settings.extension", name: "Keyboard", keywords: ["shortcuts", "input sources", "typing"]),
        .init(id: "com.apple.Mouse-Settings.extension", name: "Mouse", keywords: ["pointer", "scroll"]),
        .init(id: "com.apple.Trackpad-Settings.extension", name: "Trackpad", keywords: ["touchpad", "gestures", "tap to click"]),
        .init(id: "com.apple.Print-Scan-Settings.extension", name: "Printers & Scanners", keywords: ["printer", "scanner"]),
        .init(id: "com.apple.systempreferences.AppleIDSettings", name: "Apple Account", keywords: ["icloud", "account"]),
        .init(id: "com.apple.Family-Settings.extension", name: "Family", keywords: []),
        .init(id: "com.apple.WalletSettingsExtension", name: "Wallet & Apple Pay", keywords: []),
    ]

    /// The panes present on this Mac (cached after the first look).
    public static var available: [Pane] {
        if let cached = cache.withLock({ $0 }) { return cached }
        let dir = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
        let ids = Set(((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap {
            Bundle(url: $0)?.bundleIdentifier
        })
        // Keep a pane when it's installed, or when the folder couldn't be read (the URL still opens System Settings).
        let panes = ids.isEmpty ? table : table.filter { ids.contains($0.id) }
        cache.withLock { $0 = panes }
        return panes
    }
    private static let cache = Mutex<[Pane]?>(nil)
}

/// A minimal lock-protected value (Swift 5 mode, no Synchronization import needed).
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Start's search: apps, System Settings panes and pane's own settings answer at once (`instant`); files and folders
/// come from Spotlight a moment later (`files`), the previous query cancelled at each keystroke.
@MainActor
public final class StartSearch {
    public let index: AppIndex
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    public init(index: AppIndex) { self.index = index }

    /// Ranked: name prefix, then word prefix, then substring, then initials; ties → more launches, shorter name.
    public func apps(_ q: String) -> [AppIndex.App] {
        let query = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func score(_ app: AppIndex.App) -> Int? {
            let name = app.name.lowercased()
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if name.hasPrefix(query) { return 0 }
            if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if name.contains(query) { return 2 }
            if String(words.compactMap(\.first)).hasPrefix(query) { return 3 }
            return nil
        }
        return index.apps.compactMap { app in score(app).map { (app, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let la = index.launches(a.0.id), lb = index.launches(b.0.id)
                return la != lb ? la > lb : a.0.name.count < b.0.name.count
            }.map(\.0)
    }

    public func systemSettings(_ q: String) -> [SystemSettingsPanes.Pane] {
        let query = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        let panes = SystemSettingsPanes.available
        let byName = panes.filter { $0.name.lowercased().hasPrefix(query) || $0.name.lowercased().split(separator: " ").contains { $0.hasPrefix(query) } }
        let byWord = panes.filter { pane in !byName.contains(pane) && (pane.name.lowercased().contains(query) || pane.keywords.contains { $0.contains(query) }) }
        return byName + byWord
    }

    /// Apps, then System Settings, then pane's settings (each opening its page in pane's Settings).
    public func instant(_ q: String, limit: Int = 12) -> [StartResult] {
        let apps = self.apps(q).prefix(8).map {
            StartResult(kind: .app, id: "app:\($0.id)", title: $0.name, subtitle: "App", url: $0.url, target: $0.id)
        }
        let panes = systemSettings(q).prefix(5).map {
            StartResult(kind: .systemSetting, id: "setting:\($0.id)", title: $0.name, subtitle: "System Settings", url: $0.url, target: $0.id)
        }
        let mine = q.trimmingCharacters(in: .whitespaces).count < 3 ? [] : PaneSettings.search(q).prefix(4).compactMap { s -> StartResult? in
            guard let page = SettingsPages.page(containing: s.id), !SettingsPages.internalIDs.contains(s.id) else { return nil }
            return StartResult(kind: .paneSetting, id: "pane:\(s.id)", title: s.info.title, subtitle: "pane Settings ▸ \(page.title)", url: nil, target: page.id)
        }
        return Array((apps + panes + mine).prefix(limit))
    }

    /// Files and folders whose name matches, from Spotlight (your home folder; Library and hidden files left out).
    /// `completion` runs on the main thread once, unless a newer search replaced this one.
    public func files(_ q: String, limit: Int = 8, completion: @escaping ([StartResult]) -> Void) {
        cancelFiles()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { completion([]); return }
        let md = NSMetadataQuery()
        md.predicate = NSPredicate(format: "%K CONTAINS[cd] %@ AND %K != %@", NSMetadataItemFSNameKey, text,
                                   NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        md.searchScopes = [NSMetadataQueryUserHomeScope]
        md.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: md, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                md.disableUpdates()
                let home = NSHomeDirectory()
                var results: [StartResult] = []
                for i in 0..<md.resultCount {
                    guard results.count < limit, let item = md.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          !path.hasPrefix(home + "/Library/"), !StartSearch.isNoise(path) else { continue }
                    let url = URL(fileURLWithPath: path)
                    let isFolder = (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) == "public.folder"
                    let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
                    results.append(StartResult(kind: isFolder ? .folder : .file, id: "file:\(path)", title: url.lastPathComponent,
                                               subtitle: parent, url: url, target: path))
                }
                self?.cancelFiles()
                completion(results)
            }
        }
        query = md
        md.start()
    }

    public func cancelFiles() {
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query = nil
    }

    /// Folders people don't mean when they search documents: hidden ones, and build output and dependencies.
    nonisolated static let noiseFolders: Set<String> = ["node_modules", "build", "target", "DerivedData", "Pods", "vendor", "dist", "__pycache__", "venv"]
    nonisolated public static func isNoise(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || noiseFolders.contains(String($0)) }
    }

    /// The best match: an app that starts with the query, else the first result.
    public static func bestMatch(_ results: [StartResult], query: String) -> StartResult? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return results.first { $0.kind == .app && $0.title.lowercased().hasPrefix(q) } ?? results.first
    }
}

/// Start's Recent section (E3): apps installed in the last week (the engine), and the files you opened recently (pane
/// Pro's, from Spotlight). "Remove from list" is remembered (`StartStore.hideRecent`).
public enum RecentFiles {
    public struct Item: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable { case file, app }
        public let kind: Kind
        public let id: String
        public let name: String
        public let url: URL
        public let date: Date
        public init(kind: Kind, id: String, name: String, url: URL, date: Date) {
            self.kind = kind; self.id = id; self.name = name; self.url = url; self.date = date
        }
    }

    /// Recent files (pane Pro's) and recently added apps, newest first (`limit`: 6 on large screens, 4 on small — Windows').
    @MainActor public static func items(index: AppIndex, store: StartStore, files: [Item], includeApps: Bool, limit: Int) -> [Item] {
        let hidden = Set(store.data.hiddenRecent)
        let apps = includeApps ? index.recentlyAdded().filter { !hidden.contains($0.id) }.map {
            Item(kind: .app, id: $0.id, name: $0.name, url: $0.url, date: store.data.firstSeen[$0.id] ?? Date())
        } : []
        let all = files.filter { !hidden.contains($0.id) } + apps
        return Array(all.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Windows' times: "Just now", "17m ago", "3h ago", "Yesterday at 4:02 PM", then "Oct 12" (or "Oct 12, 2025").
    nonisolated public static func relativeTime(_ date: Date, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h ago" }
        let time = DateFormatter()
        time.locale = locale
        time.timeStyle = .short
        time.dateStyle = .none
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.locale = locale
        day.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd")
        return day.string(from: date)
    }
}
