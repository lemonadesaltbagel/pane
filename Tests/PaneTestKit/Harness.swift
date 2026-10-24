// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Launching and reading a test agent. A suite conforms to use these unqualified; others call `Harness.…`.
public protocol AgentHarness {}

/// Settings-window helpers over Accessibility (`SettingsUI.…`, or conform).
public protocol SettingsUIHarness {}

public enum Harness: AgentHarness {
    /// The agent the runner tests: `pane` in pane-tests, `pane-dev` (pane Pro) in pane-pro-tests. Set by each main.
    nonisolated(unsafe) public static var agentBinaryName = "pane"
}

public enum SettingsUI: SettingsUIHarness {}

public extension AgentHarness {
    static var buildDirectory: URL { Bundle.main.executableURL!.deletingLastPathComponent() }
    /// The runner's agent (`Harness.agentBinaryName`). The Free build is `freeBinary`.
    static var binary: URL { buildDirectory.appendingPathComponent(Harness.agentBinaryName) }
    static var freeBinary: URL { buildDirectory.appendingPathComponent("pane") }

    static var agentLog: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pane-menubar-tray.log") }
    static var testConfig: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-config.json") }

    /// The test agent's log so far.
    static func agentLogText() -> String { (try? String(contentsOf: agentLog, encoding: .utf8)) ?? "" }

    /// A test agent scoped to the fixture app, with a copy of your config.json (settings it saves land in the copy).
    /// `fresh: false` keeps the test agent's divider state (a relaunch check).
    /// `configure`: edits to the test's config copy before the agent starts (e.g. turn on Dock pin sync).
    /// `binary`: the runner's agent by default; `freeBinary` for the Free one.
    static func launchAgent(fresh: Bool = true, appendLog: Bool = false, binary: URL = Self.binary,
                            configure: (@MainActor (SettingsStore) -> Void)? = nil) throws -> Process {
        // Learned per-icon behaviour persists in the agent's defaults and every fixture shares one item id: start clean.
        if fresh { UserDefaults(suiteName: "pane-test-agent")?.removeObject(forKey: "PaneTrayActivation") }
        // The test agent's own divider/chevron positions (saved in the `pane` domain under PaneTest… names): start
        // from the default layout, not wherever the last run's swaps left the divider.
        if fresh, let domain = UserDefaults(suiteName: "pane") {
            for key in domain.dictionaryRepresentation().keys where key.contains("PaneTestTray") { domain.removeObject(forKey: key) }
        }
        let pane = Process()
        pane.executableURL = binary
        pane.arguments = ["--taskbar-scope", FixtureBundle.bundleID, "--lifecycle-scope", FixtureBundle.bundleID, "--desktop-scope", FixtureBundle.bundleID]
        var env = ProcessInfo.processInfo.environment; env["PANE_DEBUG_TRAY"] = "1"; env["PANE_DEFAULTS_SUITE"] = "pane-test-agent"
        // A copy of your config.json (its opt-outs, e.g. Terminal, still apply): settings the agent saves (pinning)
        // land in the copy, never in yours.
        if fresh || !FileManager.default.fileExists(atPath: testConfig.path) {
            try? FileManager.default.removeItem(at: testConfig)
            try? FileManager.default.copyItem(at: SettingsStore.defaultURL, to: testConfig)
        }
        if let configure { MainActor.assumeIsolatedOrSync { configure(SettingsStore(url: testConfig)) } }
        env["PANE_CONFIG"] = testConfig.path
        if let disable = ProcessInfo.processInfo.environment["PANE_AGENT_DISABLE"] { env["PANE_DISABLE"] = disable }
        pane.environment = env
        if !appendLog || !FileManager.default.fileExists(atPath: agentLog.path) { FileManager.default.createFile(atPath: agentLog.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: agentLog)
        handle.seekToEndOfFile()
        pane.standardError = handle
        try pane.run()
        return pane
    }

    /// Buttons in pane's taskbar, read through AX like any other app's UI.
    static func taskbarButtons(_ pid: pid_t) -> [(String, CGPoint)] {
        guard let bar = AX.windows(of: pid).first(where: { AX.title($0) == "Pane Taskbar" }) else { return [] }
        var result: [(String, CGPoint)] = []
        func walk(_ element: AXUIElement) {
            if AX.role(element) == kAXButtonRole, let frame = AX.frame(element) {
                let title: String = AX.title(element) ?? (AX.get(element, kAXDescriptionAttribute) ?? "")
                result.append((title, CGPoint(x: frame.midX, y: frame.midY)))
            }
            for child in (AX.get(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(child) }
        }
        walk(bar)
        return result
    }

    /// The pid an agent logged at start ("running (pid N)"), the last one in `log`.
    static func agentPID(fromLog log: String) -> pid_t {
        guard let range = log.range(of: "running (pid ", options: .backwards) else { return 0 }
        return pid_t(log[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    /// A key chord once `pid` is frontmost (false when it never got there).
    static func press(_ key: Int, _ flags: CGEventFlags, frontmost pid: pid_t) async -> Bool {
        guard await eventually(timeout: 2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else { return false }
        SyntheticKeyboard.press(key, flags)
        return true
    }

    /// Where a view titled `title` sits on screen (AX coordinates), in one of this process's windows.
    @MainActor static func center(of title: String, in window: NSWindow) -> CGPoint? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityTitle() == title { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let content = window.contentView, let view = find(content) else { return nil }
        let frame = Geometry.cocoaToAX(window.convertToScreen(view.convert(view.bounds, to: nil)), primaryHeight: Geometry.primaryHeight)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The agent's taskbar is up (the Dock reserved its space) and its first scans are done.
    static func agentReady() async {
        _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
        await settle(3)
    }
}

public extension SettingsUIHarness {
    static func log() -> String { Harness.agentLogText() }

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        AX.windows(of: pid).filter { (AX.get($0, "AXIdentifier") as String?) == "pane.settings" }
    }

    static func window(_ pid: pid_t) -> AXUIElement? { windows(pid).first }

    /// The first element with this accessibility identifier under `root`.
    static func element(_ root: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
        if (AX.get(root, "AXIdentifier") as String?) == identifier { return root }
        guard depth < 40 else { return nil }
        for c in (AX.get(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let e = element(c, identifier, depth: depth + 1) { return e }
        }
        return nil
    }

    /// Every identifier under `root`.
    static func identifiers(_ root: AXUIElement, depth: Int = 0, into set: inout Set<String>) {
        if let id: String = AX.get(root, "AXIdentifier"), !id.isEmpty { set.insert(id) }
        guard depth < 40 else { return }
        for c in (AX.get(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { identifiers(c, depth: depth + 1, into: &set) }
    }

    static func find(_ pid: pid_t, _ identifier: String) -> AXUIElement? { window(pid).flatMap { element($0, identifier) } }

    static func open(_ page: String, _ pid: pid_t) async -> Bool {
        _ = AgentLink.send("open-settings:\(page)")
        let title = SettingsPages.page(page)?.title
        return await eventually(timeout: 5) { window(pid).flatMap(AX.title) == title }
    }

    /// A test agent with a desktop window in front (from a full-screen Space the agent's window would open there).
    static func launch(_ configure: (@MainActor (SettingsStore) -> Void)? = nil) async throws -> (Fixture, Process) {
        let f = try await Fixture.launch(label: "S", windows: ["A"], frame: CGRect(x: 120, y: 160, width: 360, height: 260))
        if let defaults = UserDefaults(suiteName: "pane-test-agent") {
            defaults.removeObject(forKey: "PaneSettingsLastPage")
            defaults.removeObject(forKey: "PaneSettingsShowAdvanced")
        }
        let pane = try Harness.launchAgent(configure: configure)
        _ = await eventually(timeout: 10) { log().contains("running (pid") }
        await settle(1)
        return (f, pane)
    }

    /// Opens a pop-up button or menu button and presses the item titled `title`.
    static func choose(_ e: AXUIElement, _ title: String) async -> Bool {
        AX.perform(e, kAXPressAction)
        func item(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if AX.role(root) == kAXMenuItemRole, AX.title(root) == title { return root }
            guard depth < 6 else { return nil }
            for c in (AX.get(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let i = item(c, depth: depth + 1) { return i } }
            return nil
        }
        guard await eventually(timeout: 2, { item(e) != nil }), let found = item(e) else { return false }
        return AX.perform(found, kAXPressAction) == .success
    }

    /// A setting's value in the test agent's config copy (nil: the default).
    static func stored(_ id: String) -> Any? { (config()["settings"] as? [String: Any])?[id] }

    /// The test agent's config copy, as JSON.
    static func config() -> [String: Any] {
        guard let data = try? Data(contentsOf: Harness.testConfig),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }
}

/// Start's panel over Accessibility (the soak opens it too).
public enum StartUI {
    public static func window(_ pid: pid_t) -> AXUIElement? {
        AX.windows(of: pid).first { (AX.get($0, "AXIdentifier") as String?) == "pane.start" || AX.title($0) == "Start" }
    }
    public static func find(_ pid: pid_t, _ id: String) -> AXUIElement? { window(pid).flatMap { SettingsUI.element($0, id) } }
    public static func shown(_ pid: pid_t) -> Bool { window(pid) != nil }
}
