// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit

@Suite("Update check")
struct UpdateCheckTests {
    func json(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/lemonadesaltbagel/pane/releases/tag/\#(tag)", "draft": \#(draft), "prerelease": \#(prerelease)}"#.utf8)
    }

    @Test func versionsCompareByNumber() {
        #expect(UpdateCheck.isNewer("1.10", than: "1.9"))
        #expect(UpdateCheck.isNewer("2.0", than: "1.99.9"))
        #expect(UpdateCheck.isNewer("1.2.1", than: "1.2"))
        #expect(!UpdateCheck.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateCheck.isNewer("1.2.0", than: "1.2.0"))
        #expect(!UpdateCheck.isNewer("1.1", than: "1.2"))
    }

    @Test func releasesFromGitHubJSON() {
        #expect(UpdateCheck.release(from: json("v1.3.0"))?.version == "1.3.0")
        #expect(UpdateCheck.release(from: json("1.3"))?.page.absoluteString == "https://github.com/lemonadesaltbagel/pane/releases/tag/1.3")
        #expect(UpdateCheck.release(from: json("v1.4.0", draft: true)) == nil)
        #expect(UpdateCheck.release(from: json("v1.4.0-beta", prerelease: true)) == nil)
        #expect(UpdateCheck.release(from: json("nightly")) == nil)
        #expect(UpdateCheck.release(from: Data("not json".utf8)) == nil)
    }

    @Test func checkAgainstAFeed() async throws {
        let feed = FileManager.default.temporaryDirectory.appendingPathComponent("pane-release-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: feed) }
        try json("v1.3.0").write(to: feed)
        #expect(await UpdateCheck.check(feed: feed, current: "1.2.5")?.version == "1.3.0")
        #expect(await UpdateCheck.check(feed: feed, current: "1.3.0") == nil)
        #expect(await UpdateCheck.check(feed: feed.appendingPathExtension("missing"), current: "1.0") == nil)
    }

    @MainActor @Test func menuOffersANewerRelease() throws {
        let icon = MenuBarIcon()
        func item() -> NSMenuItem? {
            let menu = icon.makeMenu()
            icon.menuNeedsUpdate(menu)
            return menu.items.first { $0.identifier?.rawValue == "update" }
        }
        #expect(item()?.isHidden == true)
        icon.update = UpdateCheck.Release(version: "1.3.0", page: try #require(URL(string: "https://github.com/lemonadesaltbagel/pane/releases/tag/v1.3.0")))
        #expect(item()?.isHidden == false)
        #expect(item()?.title == "Update available: pane 1.3.0…")
    }
}
