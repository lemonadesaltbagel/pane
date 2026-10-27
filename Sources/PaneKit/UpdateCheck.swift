// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// "Check for updates automatically" (`general.checkForUpdates`): asks a release feed, the latest GitHub Release of a
/// repository, whether a version newer than this build's is out. It only tells: pane's menu offers the release page.
/// Nothing is downloaded or installed. A development build (no version in its bundle) never checks.
public enum UpdateCheck {
    public struct Release: Equatable, Sendable {
        public let version: String
        public let page: URL
        public init(version: String, page: URL) { self.version = version; self.page = page }
    }

    /// GitHub's latest-release API for the public repository. An extension (a build published elsewhere) sets its own
    /// feed, or nil for none.
    nonisolated(unsafe) public static var feed: URL? = URL(string: "https://api.github.com/repos/lemonadesaltbagel/pane/releases/latest")

    /// This build's version (`CFBundleShortVersionString`); nil for a development build.
    public static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// A release from GitHub's JSON: its tag ("v1.2.0" or "1.2.0") and page. Drafts and pre-releases don't count.
    public static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard !numbers(version).isEmpty else { return nil }
        return Release(version: version, page: page)
    }

    /// `a` is newer than `b`, comparing numbers left to right (1.10 > 1.9; a missing number counts as 0, so 1.2 = 1.2.0).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// "1.2.0" → [1, 2, 0]; stops at the first part that isn't a number ("1.3-beta" → [1]).
    static func numbers(_ version: String) -> [Int] {
        var result: [Int] = []
        for part in version.split(separator: ".") {
            guard let n = Int(part) else { break }
            result.append(n)
        }
        return result
    }

    /// The feed's release when it's newer than `current`; nil when it isn't, or the feed can't be read (offline).
    public static func check(feed: URL, current: String, session: URLSession = .shared) async -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard let release = release(from: data), isNewer(release.version, than: current) else { return nil }
        return release
    }
}
