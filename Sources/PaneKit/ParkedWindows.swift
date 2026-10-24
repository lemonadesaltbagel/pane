// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Windows parked off-screen by virtual desktops (pane Pro), as saved for crash recovery. Restoring them is never
/// gated: every pane (Free too) puts them back at launch and on a signal, and `--restore-only` does.
public enum ParkedWindows {
    /// One parked window: its app and where it was before parking.
    public struct Entry: Codable, Sendable {
        public let pid: pid_t
        public let x: Double
        public let y: Double
        public init(pid: pid_t, x: Double, y: Double) { self.pid = pid; self.x = x; self.y = y }
    }

    public static var defaultStateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pane/parked-windows.json")
    }

    /// After a crash: windows listed in the state file that still exist are put back. Returns how many.
    public static func recoverIfNeeded(stateURL: URL = defaultStateURL) -> Int {
        guard let data = try? Data(contentsOf: stateURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return 0 }
        var restored = 0
        for (key, entry) in entries {
            guard let wid = CGWindowID(key), NSRunningApplication(processIdentifier: entry.pid) != nil,
                  let element = AX.windows(of: entry.pid).first(where: { PrivateAPI.windowID(of: $0) == wid })
                    ?? PrivateAPI.windowElement(pid: entry.pid, wid: wid) else { continue }
            AX.setPosition(element, CGPoint(x: entry.x, y: entry.y))
            restored += 1
        }
        try? FileManager.default.removeItem(at: stateURL)
        return restored
    }
}
