// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// The app in front, cached for event taps (they run on their own threads, per keystroke).
public final class FrontmostApp {
    public static let shared = FrontmostApp()
    private let lock = NSLock()
    private var current: String?
    private var observer: NSObjectProtocol?

    private init() {
        current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.lock.withLock { self?.current = id }
        }
    }

    public var bundleID: String? { lock.withLock { current } }
}
