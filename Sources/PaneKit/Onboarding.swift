// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// Apps and macOS features that do what pane does (onboarding's conflict step, E6). Two window managers or two
/// menu-bar managers fight over the same windows and icons.
public enum Conflicts {
    public enum Kind: String, Sendable { case windowManager = "window manager", menuBarManager = "menu-bar manager", switcher, dock = "Dock replacement" }

    public struct App: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public let kind: Kind
        public let pid: pid_t
        /// What overlaps with pane, in a sentence.
        public let overlap: String
    }

    static let known: [String: (Kind, String)] = [
        "com.knollsoft.Rectangle": (.windowManager, "snaps windows with its own shortcuts and edge drags"),
        "com.knollsoft.Hookshot": (.windowManager, "snaps windows"),
        "com.crowdcafe.windowmagnet": (.windowManager, "snaps windows"),
        "com.hegenberg.BetterSnapTool": (.windowManager, "snaps windows"),
        "com.manytricks.Moom": (.windowManager, "moves and resizes windows"),
        "com.MrKai77.Loop": (.windowManager, "snaps windows"),
        "com.amethyst.Amethyst": (.windowManager, "tiles windows"),
        "com.lwouis.alt-tab-macos": (.switcher, "has its own Alt+Tab (pane's ⌥Tab takes precedence)"),
        "com.surteesstudios.Bartender": (.menuBarManager, "hides menu-bar icons too"),
        "com.jordanbaird.Ice": (.menuBarManager, "hides menu-bar icons too"),
        "com.sanebar.app": (.menuBarManager, "hides menu-bar icons too"),
        "com.ethanbills.DockDoor": (.dock, "shows window previews from the Dock"),
        "ca.ghostty.uBar": (.dock, "replaces the Dock"),
        "com.brawersoftware.uBar": (.dock, "replaces the Dock"),
    ]

    /// Known conflicting apps that are running now. Tests add bundle IDs with PANE_EXTRA_CONFLICTS (comma-separated).
    public static func runningApps() -> [App] {
        var table = known
        for id in (ProcessInfo.processInfo.environment["PANE_EXTRA_CONFLICTS"] ?? "").split(separator: ",").map(String.init) where !id.isEmpty {
            table[id] = (.windowManager, "a test stand-in")
        }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let (kind, overlap) = table[id], !app.isTerminated else { return nil }
            return App(bundleID: id, name: app.localizedName ?? id, kind: kind, pid: app.processIdentifier, overlap: overlap)
        }.sorted { $0.name < $1.name }
    }

    /// "Quit it": asks the app to quit (as ⌘Q would).
    @discardableResult
    public static func quit(_ app: App) -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.terminate() ?? false
    }

    /// macOS features that overlap, when they're on: edge tiling (pane switches it off while running if it takes over
    /// tiling), and Stage Manager (it regroups windows pane manages).
    public static func macOSFeatures() -> [String] {
        func on(_ domain: String, _ key: String) -> Bool { (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool) == true }
        var result: [String] = []
        if on("com.apple.WindowManager", "EnableTilingByEdgeDrag") || on("com.apple.WindowManager", "EnableTopTilingByEdgeDrag") {
            result.append("macOS window tiling (edge drag)")
        }
        if on("com.apple.WindowManager", "GloballyEnabled") { result.append("Stage Manager") }
        return result
    }
}

/// What pane changes on the Mac while it runs (onboarding's "What pane changes" step, E7), each with the setting that
/// turns it off. Every value is saved first and put back when pane quits, or at the next start after a crash
/// (`SystemSettings`).
public enum SystemChanges {
    public struct Change: Equatable {
        public let title: String
        public let detail: String
        /// The setting that turns this change off.
        public let setting: String
        /// For a change that isn't a plain switch (pane Pro's keyboard): whether it's on, and turning it on or off.
        public let isOn: (@MainActor (SettingsStore) -> Bool)?
        public let set: (@MainActor (SettingsStore, Bool) -> Void)?

        public init(title: String, detail: String, setting: String,
                    isOn: (@MainActor (SettingsStore) -> Bool)? = nil, set: (@MainActor (SettingsStore, Bool) -> Void)? = nil) {
            self.title = title; self.detail = detail; self.setting = setting; self.isOn = isOn; self.set = set
        }
        public static func == (a: Change, b: Change) -> Bool { a.title == b.title && a.detail == b.detail && a.setting == b.setting }

        @MainActor public func isOn(in store: SettingsStore) -> Bool { isOn?(store) ?? (store.json(setting) == .bool(true)) }
        @MainActor public func turn(_ on: Bool, in store: SettingsStore) {
            if let set { set(store, on) } else { try? store.set(id: setting, json: .bool(on)) }
        }
    }

    /// Changes extensions make (pane Pro's tray and keyboard), listed after the engine's.
    @MainActor public static var extra: [(SettingsStore) -> [Change]] = []

    @MainActor public static func describe(_ store: SettingsStore) -> [Change] {
        var result: [Change] = []
        if store[PaneSettings.replaceDock] {
            if store[PaneSettings.autoHide] {
                result.append(Change(title: "The Dock hides", detail: "It's set to hide automatically; pane's taskbar takes its place.", setting: PaneSettings.replaceDock.id))
            } else {
                result.append(Change(title: "The Dock shrinks under the taskbar",
                                     detail: "Small icons, no magnification, at the bottom: it keeps the taskbar's space free for windows.",
                                     setting: PaneSettings.replaceDock.id))
            }
            if store[PaneSettings.syncDockPins] {
                result.append(Change(title: "Your Dock's apps follow the taskbar", detail: "Pinning in pane pins in the Dock too.", setting: PaneSettings.syncDockPins.id))
            }
        }
        if store[PaneSettings.takeOverTiling] {
            result.append(Change(title: "macOS window tiling is off", detail: "Edge-drag tiling is switched off so pane's snapping works.", setting: PaneSettings.takeOverTiling.id))
        }
        let others = extra.flatMap { $0(store) }
        if store[PaneSettings.replaceCommandTab], !others.contains(where: { $0.title == commandTab }) {
            result.append(Change(title: commandTab, detail: "macOS's app switcher is off while pane runs.", setting: PaneSettings.replaceCommandTab.id))
        }
        return result + others
    }

    /// The title of the ⌘Tab row (one row, whoever takes ⌘Tab).
    public static let commandTab = "⌘Tab is pane's"

    /// *Restore now*: turns every change off (the settings each row's switch sets). Live ones revert at once; the Dock
    /// and tiling come back with a restart of pane (`--restart`), which then restores instead of handing over.
    @MainActor public static func restoreAll(_ store: SettingsStore) throws {
        for change in describe(store) { change.turn(false, in: store) }
    }

    /// The promise, word for word, for the onboarding screen.
    public static let promise = "pane saves each of these settings before changing it and puts it back when pane quits — or the next time it starts, if it ever stops unexpectedly."
}

/// First-run onboarding (Phase 3): shown while the finished version (`general.onboardingDone`) is below `version`.
/// Raise `version` when a new step needs everyone to see it; "Show welcome again" sets the setting back to 0.
public enum Onboarding {
    public static let version = 1
    @MainActor public static func isNeeded(_ store: SettingsStore) -> Bool { store[PaneSettings.onboardingDone] < version }
    @MainActor public static func markDone(_ store: SettingsStore) throws { try store.set(PaneSettings.onboardingDone, version) }
}
