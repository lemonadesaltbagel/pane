// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// Win+Shift+S: macOS's capture toolbar, starting on a selection, with the picture going to the clipboard (as
/// Windows' Snipping Tool does).
public enum Screenshot {
    /// Tests: PANE_FAKE_SCREENSHOT=<file> appends "screenshot" to the file instead. A test agent never opens the real
    /// tool (it would wait on screen for a selection).
    nonisolated(unsafe) public static var perform: () -> Bool = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PANE_FAKE_SCREENSHOT"] {
            let line = "screenshot\n"
            if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close() }
            else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
            return true
        }
        if env["PANE_DEFAULTS_SUITE"] != nil {
            PaneLog.write("screenshot: refused in a test agent")
            return false
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-i", "-U", "-c", "-J", "selection"]
        do { try capture.run(); return true } catch { PaneLog.write("screenshot: \(error)"); return false }
    }
}
