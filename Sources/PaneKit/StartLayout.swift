// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// The Start menu's own state: the pinned layout with folders, and what the app
/// index learns over time — launch counts, when each app was first seen, recent items you removed. Saved in
/// `~/Library/Application Support/Pane/start.json` (like tray.json); PANE_START_FILE points tests elsewhere.
public enum PinnedItem: Codable, Equatable, Sendable {
    /// An app by bundle ID (or path, for apps without one).
    case app(String)
    case folder(name: String, apps: [String])

    public var apps: [String] {
        switch self {
        case .app(let id): return [id]
        case .folder(_, let apps): return apps
        }
    }
}

public struct StartData: Codable, Equatable, Sendable {
    /// nil until first use: then the defaults (D5) are written.
    public var pinned: [PinnedItem]?
    public var firstSeen: [String: Date] = [:]
    public var launches: [String: Int] = [:]
    public var lastLaunch: [String: Date] = [:]
    /// Recent items removed with "Remove from list" (file paths, or app ids).
    public var hiddenRecent: [String] = []
    /// The index has run once (so apps found later count as recently added).
    public var indexed = false
    public init() {}
}

@MainActor
public final class StartStore {
    nonisolated public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["PANE_START_FILE"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pane/start.json")
    }

    public let url: URL?
    public private(set) var data: StartData
    /// Called after every change (the Start menu redraws).
    public var onChange: (() -> Void)?

    /// `url: nil` = in memory (tests).
    public init(url: URL? = StartStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        data = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(StartData.self, from: $0) } ?? StartData()
    }

    func save() {
        if let url {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let bytes = try? encoder.encode(data) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: url, options: .atomic)
            }
        }
        onChange?()
    }

    /// Replaces everything (a backup's "start" section).
    public func replace(_ new: StartData) { data = new; save() }

    // MARK: Pinned

    /// The first-run pins (D5): macOS's counterparts of Windows' defaults, where installed, then the taskbar's pins.
    public static func defaultPins(installed: Set<String>, browser: String?, taskbar: [String]) -> [PinnedItem] {
        var ids = ["com.apple.finder", browser ?? "com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Photos",
                   "com.apple.MobileSMS", "com.apple.Notes", "com.apple.AppStore", "com.apple.systempreferences", "com.apple.calculator"]
        ids += taskbar
        var seen = Set<String>()
        return ids.filter { installed.contains($0) && seen.insert($0).inserted }.map(PinnedItem.app)
    }

    public var pinned: [PinnedItem] { data.pinned ?? [] }

    /// Writes the defaults if nothing is pinned yet.
    public func ensurePinned(_ defaults: @autoclosure () -> [PinnedItem]) {
        guard data.pinned == nil else { return }
        data.pinned = defaults()
        save()
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains { $0.apps.contains(id) } }

    public func pin(_ id: String, at index: Int? = nil) {
        guard !isPinned(id) else { return }
        var list = pinned
        list.insert(.app(id), at: min(index ?? list.count, list.count))
        data.pinned = list
        save()
    }

    /// Unpins an app wherever it is (also out of a folder; an emptied folder goes).
    public func unpin(_ id: String) {
        data.pinned = pinned.compactMap { item in
            switch item {
            case .app(let a): return a == id ? nil : item
            case .folder(let name, let apps):
                let rest = apps.filter { $0 != id }
                return rest.isEmpty ? nil : .folder(name: name, apps: rest)
            }
        }
        save()
    }

    /// Moves the item at `from` so it ends up at `to` (indices in the pinned list).
    public func move(from: Int, to: Int) {
        var list = pinned
        guard list.indices.contains(from) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: max(0, min(to, list.count)))
        data.pinned = list
        save()
    }

    public func moveToFront(_ id: String) {
        guard let i = pinned.firstIndex(where: { $0 == .app(id) }) else { return }
        move(from: i, to: 0)
    }

    /// Drops the pinned item at `dragged` onto the one at `target`: a new folder of both, or into the target folder.
    public func drop(_ dragged: Int, onto target: Int) {
        var list = pinned
        guard list.indices.contains(dragged), list.indices.contains(target), dragged != target else { return }
        let moving = list[dragged].apps
        switch list[target] {
        case .app(let a): list[target] = .folder(name: "Folder", apps: [a] + moving)
        case .folder(let name, let apps): list[target] = .folder(name: name, apps: apps + moving.filter { !apps.contains($0) })
        }
        list.remove(at: dragged)
        data.pinned = list
        save()
    }

    /// Takes an app out of the folder at `folder`; it goes right after the folder. An emptied folder goes.
    public func removeFromFolder(_ id: String, folder: Int) {
        var list = pinned
        guard list.indices.contains(folder), case .folder(let name, let apps) = list[folder], apps.contains(id) else { return }
        let rest = apps.filter { $0 != id }
        list.insert(.app(id), at: folder + 1)
        if rest.isEmpty { list.remove(at: folder) } else { list[folder] = .folder(name: name, apps: rest) }
        data.pinned = list
        save()
    }

    public func renameFolder(_ folder: Int, to name: String) {
        var list = pinned
        guard list.indices.contains(folder), case .folder(_, let apps) = list[folder] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        list[folder] = .folder(name: trimmed.isEmpty ? "Folder" : trimmed, apps: apps)
        data.pinned = list
        save()
    }

    /// Drops apps that aren't installed any more (pins and folders).
    public func prune(installed: Set<String>) {
        let before = pinned
        let after: [PinnedItem] = before.compactMap { item in
            switch item {
            case .app(let a): return installed.contains(a) ? item : nil
            case .folder(let name, let apps):
                let rest = apps.filter(installed.contains)
                return rest.isEmpty ? nil : .folder(name: name, apps: rest)
            }
        }
        guard after != before, data.pinned != nil else { return }
        data.pinned = after
        save()
    }

    // MARK: What the index learns

    public func recordLaunch(_ id: String, at date: Date = Date()) {
        data.launches[id, default: 0] += 1
        data.lastLaunch[id] = date
        save()
    }

    public func hideRecent(_ key: String) {
        guard !data.hiddenRecent.contains(key) else { return }
        data.hiddenRecent.append(key)
        save()
    }

    /// Notes apps not seen before. The first run marks everything as long known (no wall of "New" apps); later
    /// finds count as recently added. `seed`: launch counts to start from (Spotlight's use counts), first run only.
    public func noteSeen(_ ids: [String], now: Date = Date(), seed: (String) -> Int? = { _ in nil }) {
        var changed = false
        let firstRun = !data.indexed
        for id in ids where data.firstSeen[id] == nil {
            data.firstSeen[id] = firstRun ? .distantPast : now
            if firstRun, let count = seed(id), count > 0, data.launches[id] == nil { data.launches[id] = count }
            changed = true
        }
        if firstRun { data.indexed = true; changed = true }
        if changed { save() }
    }
}

public extension StartStore {
    /// The pinned layout (pins and folders) in a full backup, as "start".
    var backupSection: BackupSection {
        BackupSection(key: "start", export: { [weak self] in
            self.flatMap { JSONValue.encoding($0.pinned) }.map { .object(["pinned": $0]) }
        }, restore: { [weak self] value in
            guard let self, case .object(let section) = value, let layout = section["pinned"]?.decoding([PinnedItem].self) else { return false }
            var data = self.data
            data.pinned = layout
            self.replace(data)
            return true
        })
    }
}
