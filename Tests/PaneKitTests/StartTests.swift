// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

// The Start menu's engine: pure logic on temporary files and folders.

@MainActor
private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-start-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal .app bundle (an Info.plist is all the index reads).
@discardableResult
private func makeApp(_ folder: URL, _ name: String, id: String, category: String? = nil) -> URL {
    let app = folder.appendingPathComponent("\(name).app/Contents")
    try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
    if let category { info["LSApplicationCategoryType"] = category }
    (info as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
    return folder.appendingPathComponent("\(name).app")
}

@Suite("Start · layout")
@MainActor
struct StartLayoutTests {
    @Test func defaultsAndOperations() throws {
        let store = StartStore(url: nil)
        let installed: Set<String> = ["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.example.taskbar"]
        store.ensurePinned(StartStore.defaultPins(installed: installed, browser: nil, taskbar: ["com.example.taskbar", "com.apple.finder"]))
        #expect(store.pinned == [.app("com.apple.finder"), .app("com.apple.Safari"), .app("com.apple.mail"), .app("com.apple.Notes"), .app("com.example.taskbar")])
        store.ensurePinned([]) // only the first time
        #expect(store.pinned.count == 5)

        store.pin("com.example.new")
        store.pin("com.example.new")
        #expect(store.pinned.last == .app("com.example.new") && store.pinned.count == 6)
        store.moveToFront("com.example.new")
        #expect(store.pinned.first == .app("com.example.new"))
        store.move(from: 0, to: 2)
        #expect(store.pinned[2] == .app("com.example.new"))

        // Drop Notes (3) onto Mail (2)… positions after the move: finder, Safari, new, mail, Notes, taskbar.
        store.drop(4, onto: 3)
        #expect(store.pinned[3] == .folder(name: "Folder", apps: ["com.apple.mail", "com.apple.Notes"]))
        store.drop(4, onto: 3) // taskbar into the folder
        #expect(store.pinned[3] == .folder(name: "Folder", apps: ["com.apple.mail", "com.apple.Notes", "com.example.taskbar"]))
        store.renameFolder(3, to: "  Work ")
        #expect(store.pinned[3] == .folder(name: "Work", apps: ["com.apple.mail", "com.apple.Notes", "com.example.taskbar"]))
        store.removeFromFolder("com.apple.mail", folder: 3)
        #expect(store.pinned[4] == .app("com.apple.mail"))
        store.unpin("com.apple.Notes")
        store.unpin("com.example.taskbar")
        #expect(!store.pinned.contains { if case .folder = $0 { return true }; return false }) // emptied folder gone
        #expect(store.isPinned("com.apple.mail") && !store.isPinned("com.apple.Notes"))

        store.prune(installed: ["com.apple.finder", "com.apple.mail"])
        #expect(store.pinned == [.app("com.apple.finder"), .app("com.apple.mail")])
    }

    @Test func savedAndBackedUp() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("start.json")
        let store = StartStore(url: url)
        store.ensurePinned([.app("a"), .folder(name: "F", apps: ["b", "c"])])
        store.recordLaunch("a")
        let reread = StartStore(url: url)
        #expect(reread.pinned == store.pinned && reread.data.launches["a"] == 1)

        let settings = SettingsStore(url: nil)
        let backup = PaneBackup.exportData(settings, sections: [store.backupSection])
        let other = StartStore(url: nil)
        other.ensurePinned([.app("z")])
        #expect(try PaneBackup.importData(backup, store: settings, sections: [other.backupSection]).isEmpty)
        #expect(other.pinned == [.app("a"), .folder(name: "F", apps: ["b", "c"])])
    }

    @Test func firstRunIsNotNew() {
        let store = StartStore(url: nil)
        let now = Date()
        store.noteSeen(["a", "b"], now: now) { $0 == "a" ? 9 : nil }
        #expect(store.data.firstSeen["a"] == .distantPast && store.data.launches["a"] == 9 && store.data.launches["b"] == nil)
        store.noteSeen(["a", "b", "c"], now: now)
        #expect(store.data.firstSeen["c"] == now)
    }
}

@Suite("Start · app index")
@MainActor
struct AppIndexTests {
    @Test func scansCategorizesAndNoticesInstalls() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        makeApp(folder, "Alpha Writer", id: "com.example.alpha", category: "public.app-category.productivity")
        makeApp(folder, "Beta Sheets", id: "com.example.beta", category: "public.app-category.business")
        makeApp(folder, "Gamma Notes", id: "com.example.gamma", category: "public.app-category.productivity")
        makeApp(folder, "Paint", id: "com.example.paint", category: "public.app-category.graphics-design")
        makeApp(folder, "7zip", id: "com.example.7zip")
        let store = StartStore(url: nil)
        let index = AppIndex(roots: [folder.path], store: store)
        index.reload()
        #expect(index.apps.map(\.name) == ["7zip", "Alpha Writer", "Beta Sheets", "Gamma Notes", "Paint"])
        #expect(index.app("com.example.alpha")?.category == "Productivity")
        let groups = index.byCategory()
        // Creativity has one app: folded into Other with 7zip.
        #expect(groups.map(\.name) == ["Productivity", "Other"])
        #expect(Set(groups.last!.apps.map(\.id)) == ["com.example.paint", "com.example.7zip"])
        #expect(index.byLetter().map(\.letter) == ["#", "A", "B", "G", "P"])

        // Most used: launches order the list and the category.
        store.recordLaunch("com.example.gamma"); store.recordLaunch("com.example.gamma"); store.recordLaunch("com.example.beta")
        #expect(index.mostUsed().map(\.id) == ["com.example.gamma", "com.example.beta"])
        #expect(index.byCategory().first?.apps.first?.id == "com.example.gamma")

        // Watching: an installed app shows up, recently added; a removed one goes.
        var changes = 0
        index.onChange = { changes += 1 }
        index.startWatching()
        defer { index.stopWatching() }
        let start = Date()
        let added = makeApp(folder, "Delta", id: "com.example.delta")
        let appeared = await eventually(timeout: 3) { index.app("com.example.delta") != nil }
        let seconds = Date().timeIntervalSince(start)
        #expect(appeared && seconds < 2, "appeared after \(seconds) s")
        #expect(index.recentlyAdded().map(\.id) == ["com.example.delta"])
        try FileManager.default.removeItem(at: added)
        #expect(await eventually(timeout: 3) { index.app("com.example.delta") == nil })
        #expect(changes >= 2)
    }

    @Test func categoryMapping() {
        #expect(AppIndex.category(appStore: "public.app-category.developer-tools", path: "/Applications/X.app") == "Developer tools")
        #expect(AppIndex.category(appStore: "public.app-category.puzzle-games", path: "/Applications/X.app") == "Games")
        #expect(AppIndex.category(appStore: nil, path: "/System/Applications/Utilities/Terminal.app") == "Utilities & tools")
        #expect(AppIndex.category(appStore: nil, path: "/Applications/X.app") == "Other")
        #expect(AppIndex.letter("Éclair") == "E" && AppIndex.letter("1Password") == "#")
    }

    @Test func realAppsIndexQuickly() {
        let store = StartStore(url: nil)
        let index = AppIndex(store: store)
        let start = Date()
        index.reload()
        let ms = Date().timeIntervalSince(start) * 1000
        Report.record("Start · app index", "\(index.apps.count) apps indexed in \(Int(ms)) ms (cold); categories \(index.byCategory().map { "\($0.name) \($0.apps.count)" })")
        #expect(index.app("com.apple.finder") != nil && index.app("com.apple.Safari") != nil)
        #expect(ms < 1500)
    }
}

@Suite("Start · search")
@MainActor
struct StartSearchTests {
    @Test func ranksAppsSettingsAndPaneSettings() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        makeApp(folder, "Safari", id: "com.example.safari")
        makeApp(folder, "Safety Inspector", id: "com.example.safety")
        makeApp(folder, "Visual Studio Code", id: "com.example.vsc")
        let store = StartStore(url: nil)
        let index = AppIndex(roots: [folder.path], store: store)
        index.reload()
        let search = StartSearch(index: index)
        #expect(search.apps("safa").first?.id == "com.example.safari")
        #expect(search.apps("vsc").first?.id == "com.example.vsc")
        store.recordLaunch("com.example.safety")
        #expect(search.apps("saf").first?.id == "com.example.safety") // same rank: more launches first

        #expect(search.systemSettings("wi-fi").first?.name == "Wi-Fi")
        #expect(search.systemSettings("dark mode").first?.name == "Appearance")
        let results = search.instant("hide taskbar")
        #expect(results.contains { $0.kind == .paneSetting && $0.subtitle == "pane Settings ▸ Taskbar" })
        let best = StartSearch.bestMatch(search.instant("saf"), query: "saf")
        #expect(best?.kind == .app)
        let start = Date()
        _ = search.instant("s")
        #expect(Date().timeIntervalSince(start) < 0.03)
    }

    @Test func fileSearchAnswers() async {
        let search = StartSearch(index: AppIndex(roots: [], store: StartStore(url: nil)))
        var answered: [StartResult]?
        search.files("pane-no-such-file-\(UUID().uuidString)") { answered = $0 }
        #expect(await eventually(timeout: 5) { answered != nil })
        #expect(answered?.isEmpty == true)
    }

    @Test func relativeTimes() {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-23T15:00:00Z")!
        func rel(_ seconds: TimeInterval) -> String { RecentFiles.relativeTime(now.addingTimeInterval(-seconds), now: now, locale: locale, calendar: calendar) }
        #expect(rel(20) == "Just now")
        #expect(rel(17 * 60) == "17m ago")
        #expect(rel(3 * 3600) == "3h ago")
        #expect(rel(20 * 3600).hasPrefix("Yesterday at "))
        #expect(rel(10 * 86_400) == "Oct 13")
        #expect(rel(400 * 86_400) == "Sep 18, 2025")
    }
}

@Suite("Start · power, account, settings")
@MainActor
struct StartPowerSettingsTests {
    @Test func fakePowerRecordsOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fake-power-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        for action in PowerAction.allCases { Power.fake(action, to: file.path) }
        #expect(try String(contentsOf: file, encoding: .utf8) == PowerAction.allCases.map { $0.rawValue + "\n" }.joined())
        #expect(!Account.name.isEmpty)
        #expect(StartPlace.downloads.url.lastPathComponent == "Downloads")
    }

}
