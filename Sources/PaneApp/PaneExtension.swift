// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit
import PaneShell

/// A part of pane built outside the engine: pane Pro's features. The official build
/// passes its extensions to `PaneMain.run(extensions:)`; the Free build passes none, and works without them.
///
/// The agent calls these at fixed points, on the main thread. Every hook has a default that does nothing, so an
/// extension implements only what it needs. New hooks are added here as features move out of the engine.
@MainActor
public protocol PaneExtension: AnyObject {
    /// For logs ("menu strips").
    var name: String { get }
    /// pane is launching, before anything reads the settings (pane Pro's licensing sets the edition here). Only the
    /// settings, the log and `setEdition` are ready.
    func launch(_ host: PaneHost)
    /// The taskbar was just made, before it shows (the tray attaches here). Shortcuts and Start don't exist yet.
    func prepare(_ host: PaneHost)
    /// pane's services are starting (Accessibility is granted). Launch-time settings are read here.
    func start(_ host: PaneHost)
    /// pane is quitting or restarting: undo everything visible (close panels, bring windows back).
    func stop()
    /// Accessibility was revoked: stop every event tap at once (otherwise clicks and keys freeze). Default: `stop()`.
    /// pane restarts when it's granted again.
    func suspend()
    /// The window inventory changed (every update, all windows).
    func windowsChanged(_ windows: [ManagedWindow])
    /// Alt mode (⌥ tap): the focused window's menu mnemonics if this extension shows that window's menus (nil:
    /// pane's own, the app's menu bar).
    func menuMnemonics() -> [Character?]?
    /// Alt mode: opens the focused window's menu `index`; false when this extension doesn't show it.
    func openMenu(_ index: Int) -> Bool
    /// An agent-link message (another pane process, tests) the engine doesn't know; true when handled.
    func handle(_ message: String) -> Bool
    /// The Settings window's model was made: add page sections, hooks.
    func configureSettings(_ model: SettingsModel)
    /// The welcome (onboarding) was made: add its keyboard step, a note.
    func configureOnboarding(_ model: OnboardingModel)
    /// Entries for `pane --report` (no window titles, no other apps' names). Runs without the agent started.
    func diagnostics() async -> [String: String]
}

public extension PaneExtension {
    func launch(_ host: PaneHost) {}
    func prepare(_ host: PaneHost) {}
    func stop() {}
    func suspend() { stop() }
    func windowsChanged(_ windows: [ManagedWindow]) {}
    func menuMnemonics() -> [Character?]? { nil }
    func openMenu(_ index: Int) -> Bool { false }
    func handle(_ message: String) -> Bool { false }
    func configureSettings(_ model: SettingsModel) {}
    func configureOnboarding(_ model: OnboardingModel) {}
    func diagnostics() async -> [String: String] { [:] }
}

/// Which windows are on the virtual desktop shown now (pane Pro's virtual desktops answer; without them, all are).
/// Thread-safe: Alt+Tab's filter asks on its key tap's thread.
public final class DesktopMembership: @unchecked Sendable {
    /// Who asks: the taskbar and Alt+Tab can each be set to show every desktop.
    public enum Use: Sendable { case taskbar, switcher, other }
    private let lock = NSLock()
    private var test: (@Sendable (CGWindowID) -> Bool)?
    private var everyDesktop: Set<Use> = []
    public init() {}
    public func set(_ test: (@Sendable (CGWindowID) -> Bool)?) { lock.withLock { self.test = test } }
    /// The taskbar or Alt+Tab shows windows from every desktop (pane Pro's settings).
    public func showEveryDesktop(_ use: Use, _ on: Bool) {
        lock.withLock {
            if on { everyDesktop.insert(use) } else { everyDesktop.remove(use) }
        }
    }
    public func isOnCurrent(_ wid: CGWindowID, for use: Use = .other) -> Bool {
        lock.lock()
        let current = test, all = everyDesktop.contains(use)
        lock.unlock()
        if all { return true }
        return current?(wid) ?? true
    }
}

/// What an extension may use: the engine's shared objects.
@MainActor
public final class PaneHost {
    /// Settings (with the edition's locks applied).
    public let prefs: SettingsStore
    public let inventory: WindowInventory
    /// The taskbar, once it exists.
    public internal(set) var taskbar: TaskbarPanel?
    /// Windows-style full screen (⌃⌘F).
    public let fullScreen: FullScreenService
    /// Snapping and maximizing.
    public let snap: SnapService
    /// Windows in most-recently-focused order.
    public let history: FocusHistory
    /// Virtual desktops (Pro) set the test; the taskbar, Alt+Tab, show desktop and shake use it.
    public let desktops: DesktopMembership
    public func isOnCurrentDesktop(_ wid: CGWindowID) -> Bool { desktops.isOnCurrent(wid) }
    /// Apps pane leaves alone (pane Pro's App exceptions, set in `launch`): hidden, not snapped, never quit, pane's
    /// keys stand down.
    public var leftAlone: Set<String> = []
    /// Apps hidden from the taskbar, Alt+Tab and Task View (setting `apps.hideFromTaskbar`).
    public var isHidden: (String) -> Bool = { _ in false }
    /// Tests: the apps pane may act on (`--desktop-scope`); nil = every app.
    public let scope: Set<String>?
    /// The keyboard shortcuts (for an extension's own: `onQuickLink`, …).
    public internal(set) var hotkeys: HotkeyService?
    /// Alt+Tab's panel, once it exists (before `start`).
    public internal(set) var switcherPanel: SwitcherPanel?
    /// Start, once it exists.
    public internal(set) var startMenu: StartMenuController?
    /// Pro (a license or its trial) is on: the features follow it. The Free build is
    /// never Pro.
    public internal(set) var isPro: () -> Bool = { false }
    /// pane Pro's licensing: the edition is now `isPro` (`summary` for the log: "Pro trial: 3 days left"), with the
    /// settings it locks (and whether your per-app overrides are). The locks apply at once. True when pane restarts for
    /// launch-time settings (Settings reopens on `reopenSettings`).
    @discardableResult
    public func setEdition(isPro: Bool, locks: [String: JSONValue], lockingOverrides: Bool, summary: String, reopenSettings: String?) -> Bool {
        editionChanged(EditionChange(isPro: isPro, locks: locks, lockingOverrides: lockingOverrides), summary, reopenSettings)
    }
    struct EditionChange { let isPro: Bool; let locks: [String: JSONValue]; let lockingOverrides: Bool }
    var editionChanged: (EditionChange, String, String?) -> Bool = { _, _, _ in false }
    /// A purchase item in pane's menu, while not Pro: its title and action (nil: none).
    public var purchase: (title: String, action: () -> Void)?
    public var openSettings: (String?) -> Void = { _ in }
    public var toggleShowDesktop: () -> Void = {}
    /// pane's menu (Settings, Pause, Quit) for a status item.
    public var menuBarMenu: () -> NSMenu = { NSMenu() }
    /// An extension's chevron in the menu bar stands in for pane's own icon (`general.showMenuBarIcon`).
    public var menuBarChevron = false
    public let log: (String) -> Void
    /// A macOS setting an extension changes while pane runs: saved first and put back when pane quits, or at the next
    /// start after a crash, as pane's own are. Nothing changes in a dry run.
    public func changeSystem(_ changes: [SystemSettings.Change]) { systemChange(changes, true) }
    /// Puts these back now (the setting that needed them was turned off).
    public func restoreSystem(_ changes: [SystemSettings.Change]) { systemChange(changes, false) }
    var systemChange: ([SystemSettings.Change], Bool) -> Void = { _, _ in }

    init(prefs: SettingsStore, inventory: WindowInventory, taskbar: TaskbarPanel?, fullScreen: FullScreenService, snap: SnapService,
         history: FocusHistory, scope: Set<String>?, desktops: DesktopMembership, log: @escaping (String) -> Void) {
        self.desktops = desktops
        self.prefs = prefs
        self.inventory = inventory
        self.taskbar = taskbar
        self.fullScreen = fullScreen
        self.snap = snap
        self.history = history
        self.scope = scope
        self.log = log
    }
}
