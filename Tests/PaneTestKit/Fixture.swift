// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Builds `PaneFixture.app` around the PaneFixture binary that SwiftPM built next to the test bundle.
public enum FixtureBundle {
    public static let bundleID = "dev.pane.fixture"

    public static let url: URL = {
        // pane-tests and PaneFixture are built into the same products directory.
        let products = Bundle.main.executableURL!.deletingLastPathComponent()
        let binary = products.appendingPathComponent("PaneFixture")
        precondition(FileManager.default.isExecutableFile(atPath: binary.path), "PaneFixture not built at \(binary.path); run `swift build` first")

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("pane-tests/PaneFixture.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.removeItem(at: app)
        try! FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try! FileManager.default.copyItem(at: binary, to: macOS.appendingPathComponent("PaneFixture"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "PaneFixture",
            "CFBundleExecutable": "PaneFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardError = FileHandle.nullDevice
        try? sign.run()
        sign.waitUntilExit()
        return app
    }()

    /// Leftovers from a crashed or interrupted run would confuse z-order and pid assertions.
    public static func killStrays() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.forceTerminate() }
    }
}

/// One running PaneFixture process. Windows are titled "<label> <name>".
public final class Fixture {
    public static let defaultFrame = CGRect(x: 160, y: 160, width: 640, height: 420)

    public let app: NSRunningApplication
    public let label: String
    public var pid: pid_t { app.processIdentifier }
    /// Window IDs by name, remembered once seen, so steps keep working while AX can't see the windows.
    private var knownWids: [String: CGWindowID] = [:]

    private init(app: NSRunningApplication, label: String) {
        self.app = app
        self.label = label
    }

    public static func launch(label: String, windows: [String], panel: Bool = false, tabs: Bool = false, statusItem: Bool = false, statusAction: Bool = false, extraArguments: [String] = [], frame: CGRect = defaultFrame,
                       activate: Bool = true, newInstance: Bool = true, requireVisibleInAX: Bool = true) async throws -> Fixture {
        var arguments = ["--label", label, "--windows", windows.joined(separator: ","),
                         "--frame", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"]
        if panel { arguments.append("--panel") }
        if tabs { arguments.append("--tabs") }
        if statusItem { arguments.append("--status-item") }
        if statusAction { arguments.append("--status-action") }
        arguments += extraArguments
        let app = try await Launcher.open(FixtureBundle.url, arguments: arguments, newInstance: newInstance, activate: activate)
        let fixture = Fixture(app: app, label: label)
        let expected = windows.map { "\(label) \($0)" } + (panel ? ["\(label) Palette"] : [])
        guard requireVisibleInAX else {
            // Windows on a Space that isn't shown are invisible to AX; wait for the WindowServer instead.
            _ = await eventually(timeout: 5) { WindowServer.windows(onScreenOnly: false).filter { $0.pid == app.processIdentifier && $0.layer == 0 && !PrivateAPI.spaces(of: $0.id).isEmpty }.count >= windows.count }
            return fixture
        }
        if activate {
            // NSWorkspace's `activates` is only a request on macOS 14+ (cooperative activation) and is often
            // refused because the test runner isn't the active app; SkyLight fronting by wid is not.
            _ = await eventually(timeout: 5) { fixture.firstWindowServerWindow() != nil }
            if let wid = fixture.firstWindowServerWindow() { Focus.focus(wid: wid, pid: fixture.pid) }
        }
        let ready = await fixture.waitUntilVisibleInAX(expected)
        for name in windows + (panel ? ["Palette"] : []) { _ = fixture.wid(name) }
        guard ready else {
            fixture.quit()
            throw FixtureError.windowsNeverAppeared(expected)
        }
        return fixture
    }

    /// Waits for `titles` to show up in kAXWindows. If the windows exist but sit on a Space that isn't shown
    /// (the run started from a fullscreen Terminal, or macOS switched back to it), focuses one by its
    /// WindowServer id, which makes macOS switch to that Space.
    public func waitUntilVisibleInAX(_ titles: [String], timeout: TimeInterval = 5) async -> Bool {
        let visible = { () -> Bool in
            let live = Set(AX.windows(of: self.pid).compactMap(AX.title))
            return titles.isEmpty ? !live.isEmpty : live.isSuperset(of: titles)
        }
        if await eventually(timeout: 1.5, visible) { return true }
        guard let hidden = firstWindowServerWindow() else { return await eventually(timeout: timeout, visible) }
        let switched = Focus.focus(wid: hidden, pid: pid)
        let ok = await eventually(timeout: timeout, visible)
        Report.record("Spaces · fixture on a hidden Space", "SkyLight focus by wid (no AX) returned \(switched); visible to AX afterwards=\(ok)")
        return ok
    }

    /// A normal-layer window of this app that's assigned to a Space (i.e. shown somewhere).
    public func firstWindowServerWindow() -> CGWindowID? {
        WindowServer.windows(onScreenOnly: false).first {
            $0.pid == self.pid && $0.layer == 0 && !PrivateAPI.spaces(of: $0.id).isEmpty
        }?.id
    }

    /// Makes sure this fixture's windows are on the shown Space before a test step relies on AX.
    public func ensureVisible() async throws {
        guard await waitUntilVisibleInAX([]) else { throw FixtureError.windowsNeverAppeared([label]) }
    }

    public func window(_ name: String) -> AXUIElement? {
        AX.windows(of: pid).first { AX.title($0) == "\(label) \(name)" }
    }

    public func wid(_ name: String) -> CGWindowID? {
        if let wid = window(name).flatMap(PrivateAPI.windowID) {
            knownWids[name] = wid
            return wid
        }
        return knownWids[name]
    }

    public func requireWindow(_ name: String) throws -> AXUIElement {
        guard let window = window(name) else { throw FixtureError.noWindow(name) }
        return window
    }

    /// Presses the window's close button, like a user click (the app runs its normal close path).
    @discardableResult
    public func close(_ name: String) throws -> AXError {
        guard let button = AX.button(try requireWindow(name), kAXCloseButtonAttribute) else { throw FixtureError.noWindow(name) }
        return AX.perform(button, kAXPressAction)
    }

    public var standardWindows: [AXUIElement] {
        AX.windows(of: pid).filter { AX.subrole($0) == kAXStandardWindowSubrole }
    }

    /// Synchronous so tests can `defer` it.
    public func quit() {
        guard !app.isTerminated else { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(2)
        while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if !app.isTerminated { app.forceTerminate() }
    }
}

public enum FixtureError: Error {
    case windowsNeverAppeared([String])
    case noWindow(String)
}
