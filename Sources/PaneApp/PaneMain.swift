// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Starts pane: one agent at a time (a second start hands its request to the running one and exits), an Edit menu
/// for text fields, then the run loop. The `pane` executable is just `PaneMain.run()`.
public enum PaneMain {
    /// The single-instance lock: an flock the kernel releases on exit or crash (a restart releases it first).
    nonisolated(unsafe) static var instanceLock: Int32 = -1

    /// `extensions`: pane Pro's features (the official build); none for the Free build.
    public static func run(extensions: @escaping @MainActor () -> [PaneExtension] = { [] }) -> Never {
        // Test runs (any --…-scope argument) keep what pane learns in their own settings domain, never in yours.
        if CommandLine.arguments.contains(where: { $0.hasSuffix("-scope") }) && ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] == nil {
            setenv("PANE_DEFAULTS_SUITE", "pane-test-agent", 1)
        }
        // `--report <file>`: diagnostics, then exit; runs beside a running pane (no lock).
        if let i = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in await Diagnostics.write(to: path, extensions: extensions()) }
            app.run()
        }
        instanceLock = takeLockOrHandOver()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        let delegate = MainActor.assumeIsolated { PaneAgent(extensions: extensions()) }
        app.delegate = delegate
        app.run()
        exit(0)
    }

    /// One pane at a time: two agents each back up and restore the Dock and tiling settings, and the second one's
    /// restore pulls them out from under the first (happened when two test runs overlapped: the Dock was left on
    /// auto-hide with no backup). Starting pane again while it runs opens its Settings (D2), like other Mac apps.
    static func takeLockOrHandOver() -> Int32 {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pane")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("agent.lock").path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let arguments = CommandLine.arguments
        let message: String
        if arguments.contains("--restart") { message = "restart" }
        else if let i = arguments.firstIndex(of: "--open-settings") { message = "open-settings:" + (arguments.indices.contains(i + 1) ? arguments[i + 1] : "") }
        else { message = "open-settings:" }
        if AgentLink.send(message) {
            log(message == "restart" ? "asked the running pane to restart" : "pane is already running: opened its Settings")
            exit(0)
        }
        log("another pane agent is already running; quit it first")
        exit(2)
    }

    /// pane shows no menu bar, but its text fields (Settings, Start's search, the license key) get ⌘X/⌘C/⌘V/⌘A/⌘Z only
    /// through the main menu's key equivalents.
    static func editMenu() -> NSMenu {
        let main = NSMenu(title: "pane")
        let edit: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]), ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]), ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]), ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, entries) in [("pane", []), ("Edit", edit)] {
            let submenu = NSMenu(title: title)
            for (name, action, key, modifiers) in entries {
                let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                submenu.addItem(item)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }
}
