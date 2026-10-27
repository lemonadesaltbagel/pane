// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// pane as an app (`scripts/make-app.sh`), launched through LaunchServices so macOS treats it as the app, not as a
/// child of Terminal. The test isolation is passed in the environment (`open --env`): a copy of your config, the test
/// agents' own defaults, faked power and screenshots.
public enum AppUnderTest {
    /// `<package>/.build/app/<name>.app` (the runner lives in `<package>/.build/…`).
    public static func url(named name: String) -> URL {
        var dir = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.lastPathComponent != ".build" && dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("app/\(name).app")
    }

    public static func exists(named name: String) -> Bool { FileManager.default.fileExists(atPath: url(named: name).path) }

    static let config = FileManager.default.temporaryDirectory.appendingPathComponent("pane-app-test-config.json")
    public static let powerLog = FileManager.default.temporaryDirectory.appendingPathComponent("pane-app-test-power.log")
    /// Until you grant the app Accessibility, an app agent would ask macOS for it, a system prompt on your screen: test
    /// launches say it's missing instead (the report reads the real state).
    static let permissions = FileManager.default.temporaryDirectory.appendingPathComponent("pane-app-test-permissions.txt")

    /// The app's log (its stderr goes nowhere): the test config turns on the diagnostic log, written here.
    public static let log = FileManager.default.temporaryDirectory.appendingPathComponent("pane-app-test.log")
    public static func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// The isolation every launch gets. `fakeMissing`: Accessibility reported missing (no prompt).
    static func environment(fakeMissing: Bool = false) -> [String] {
        if !FileManager.default.fileExists(atPath: config.path) {
            try? FileManager.default.copyItem(at: SettingsStore.defaultURL, to: config)
            MainActor.assumeIsolatedOrSync { try? SettingsStore(url: config).set(PaneSettings.debugLog, true) }
        }
        var env = ["PANE_CONFIG=\(config.path)", "PANE_DEFAULTS_SUITE=pane-test-agent", "PANE_FAKE_POWER=\(powerLog.path)",
                   "PANE_FAKE_SCREENSHOT=1", "PANE_LOG_FILE=\(log.path)"]
        if fakeMissing {
            try? "accessibility=missing".write(to: permissions, atomically: true, encoding: .utf8)
            env.append("PANE_FAKE_PERMISSIONS_FILE=\(permissions.path)")
        }
        return env
    }

    /// `open -n [-W] -a app --env … --args …`; returns `open`'s exit status.
    @discardableResult
    public static func open(_ app: URL, wait: Bool, arguments: [String], fakeMissing: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n"] + (wait ? ["-W"] : []) + ["-a", app.path] + environment(fakeMissing: fakeMissing).flatMap { ["--env", $0] } + ["--args"] + arguments
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The app's own `--report` (as the app), or a bare run of its binary (`fromTerminal`: as this process's child,
    /// which macOS checks against Terminal's grants).
    public static func report(_ app: URL, fromTerminal: Bool = false) -> [String: String] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pane-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        if fromTerminal {
            let p = Process()
            let executable = (Bundle(url: app)?.executableURL) ?? app.appendingPathComponent("Contents/MacOS/pane")
            p.executableURL = executable
            p.arguments = ["--report", file.path]
            try? p.run()
            p.waitUntilExit()
        } else {
            open(app, wait: true, arguments: ["--report", file.path])
        }
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return json
    }

    /// Starts the app's agent (scoped to the fixture app, as test agents are). Returns its process once it runs.
    public static func launch(_ app: URL, arguments: [String] = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID,
                                                               "--desktop-scope", FixtureBundle.bundleID]) async -> NSRunningApplication? {
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: log)
        // Not granted yet: say so instead of letting it ask macOS (a prompt on your screen).
        let granted = report(app)["accessibility"] == "granted"
        open(app, wait: false, arguments: arguments, fakeMissing: !granted)
        return await running(app)
    }

    /// The app's running agent, if any.
    public static func running(_ app: URL, timeout: TimeInterval = 8) async -> NSRunningApplication? {
        var found: NSRunningApplication?
        _ = await eventually(timeout: timeout) {
            found = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL && !$0.isTerminated }
            return found != nil
        }
        return found
    }

    /// Quits it the way a logout would (SIGTERM: pane restores what it changed), waiting for the process to go
    /// (`isTerminated` didn't update for an app `open` started).
    public static func quit(_ running: NSRunningApplication) async -> Bool {
        let pid = running.processIdentifier
        kill(pid, SIGTERM)
        return await eventually(timeout: 8) { kill(pid, 0) != 0 }
    }
}
