// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Polls `condition` until it holds or `timeout` passes. Window state changes are asynchronous IPC, so
/// every integration assertion goes through this instead of a fixed sleep.
public func eventually(timeout: TimeInterval = 2, poll: TimeInterval = 0.05, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
    } while Date() < deadline
    return condition()
}

/// Seconds until `condition` first holds, or nil on timeout.
public func timeUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> TimeInterval? {
    let start = Date()
    return await eventually(timeout: timeout, poll: 0.01, condition) ? Date().timeIntervalSince(start) : nil
}

public func settle(_ seconds: TimeInterval = 0.3) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

public enum IntegrationGate {
    public static var isEnabled: Bool {
        AX.isTrusted && ProcessInfo.processInfo.environment["PANE_SKIP_INTEGRATION"] == nil
    }
}

/// Collects measured behavior (not just pass/fail) into test-results/findings.md, because several tests
/// are experiments whose outcome is what we want to know about this macOS version.
public enum Report {
    private static let lock = NSLock()
    private static let url: URL = {
        // The package being tested (scripts/test.sh runs from its root; this library may be a dependency's checkout).
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("test-results")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("findings.md")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let header = "# Pane local findings\n\n- Run: \(ISO8601DateFormatter().string(from: Date()))\n- macOS: \(os)\n" +
            "- Accessibility: \(AX.isTrusted) · Screen Recording: \(Capture.hasScreenRecording)\n" +
            "- Started from Space: \(PrivateAPI.activeSpace().map { "\($0.id) \($0.kind)" } ?? "unknown")" +
            " (kAXWindows omits windows on other Spaces; fixtures are activated so their desktop becomes current)\n\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    public static func record(_ topic: String, _ finding: String) {
        lock.withLock {
            let line = "- **\(topic)**: \(finding)\n"
            print("PANE-FINDING \(topic): \(finding)")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            }
        }
    }
}

import PaneShell

@MainActor
public enum ChoicePanelAccess {
    public static var window: NSWindow { ChoicePanel.shared.window }
}

/// Stops an agent process without `waitUntilExit()`, which hung forever once from an async test even though the
/// agent had already exited (its SIGTERM handler restores settings and exits).
public func stopAgent(_ process: Process, timeout: TimeInterval = 8) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
}

/// Stops an agent the test didn't launch itself (the new pane after a restart) and waits until it has gone, so the
/// next test's agent gets the agent link and a clean Dock.
public func stopAgent(pid: pid_t, timeout: TimeInterval = 8) {
    guard pid > 0, kill(pid, 0) == 0 else { return }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(timeout)
    while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
}
