// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// Tray diagnostics on stderr (`PANE_DEBUG_TRAY=1`), each line stamped with the time (UTC, as `PaneLog`) to the millisecond so a
/// run can be matched against what the user did.
public enum TrayLog {
    /// On with PANE_DEBUG_TRAY, or the setting `advanced.debugLog` (which also writes `file`).
    public static var enabled: Bool { fromEnvironment || lock.withLock { forced } }
    private static let fromEnvironment = ProcessInfo.processInfo.environment["PANE_DEBUG_TRAY"] != nil
    nonisolated(unsafe) private static var forced = false
    nonisolated(unsafe) private static var handle: FileHandle?
    /// `advanced.debugLog`: diagnostics on, and appended to `url` (~/Library/Logs/Pane/pane.log).
    public static func setFile(_ url: URL?) {
        lock.withLock {
            try? handle?.close()
            handle = nil
            forced = url != nil
            guard let url else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
    }
    /// Lines that always go to the log file when there is one (pane's own `log`).
    public static func file(_ line: String) { lock.withLock { handle?.write(line.data(using: .utf8)!) } }
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let lock = NSLock()

    public static func write(_ message: String) {
        guard enabled else { return }
        let stamp = lock.withLock { formatter.string(from: Date()) }
        let line = "[pane \(stamp)] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        file(line)
    }
}
