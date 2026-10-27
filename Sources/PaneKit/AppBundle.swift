// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// pane running as an app (`scripts/make-app.sh`) or as a bare binary from Terminal. macOS checks privacy grants
/// against the app itself, starts it at login with `SMAppService`, and the app carries its preview helper.
public enum AppBundle {
    /// Running from an app bundle.
    public static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// The app's version (`CFBundleShortVersionString`); nil for a development build.
    public static var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// The app's helpers (`Contents/Helpers`); nil outside an app.
    public static var helpers: URL? { isApp ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") : nil }
}
