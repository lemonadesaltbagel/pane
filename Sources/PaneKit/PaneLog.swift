// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// pane's log on stderr: `[pane HH:mm:ss.SSS] message`, in UTC like the soak's record, so the two line up.
public enum PaneLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ message: String) {
        let stamp = lock.withLock { time.string(from: Date()) }
        FileHandle.standardError.write("[pane \(stamp)] \(message)\n".data(using: .utf8)!)
    }
}
