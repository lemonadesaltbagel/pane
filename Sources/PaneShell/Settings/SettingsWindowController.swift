// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Combine
import SwiftUI
import PaneKit

/// The settings window's state, shared by its SwiftUI views. Every store change (the window's own, a hand edit of
/// config.json, pane changing a setting itself) bumps `revision`, so the views re-read their values.
@MainActor
public final class SettingsModel: ObservableObject {
    public let store: SettingsStore
    @Published public var page: String { didSet { Self.defaults.set(page, forKey: Self.lastPageKey) } }
    @Published public var search = ""
    @Published public var showAdvanced: Bool { didSet { Self.defaults.set(showAdvanced, forKey: Self.advancedKey) } }
    @Published public private(set) var revision = 0
    /// `.restart` settings changed since pane started (the agent knows: it kept their launch values).
    @Published public private(set) var pending: [String] = []
    /// Apps added to App exceptions that have no override yet.
    @Published public var addedApps: [String] = []
    /// A message shown once in the window (import problems, restore results).
    @Published public var notice: String?

    public var pendingRestart: () -> Set<String> = { [] }
    /// "Restart pane" (the agent restarts and reopens Settings on this page).
    public var onRestart: ((String) -> Void)?
    /// Full backups (E12): the named sections besides the settings (Start's layout; the tray's from pane Pro), and
    /// what to do after an import (redraw the tray).
    public var backupSections: [BackupSection] = []
    public var onImported: (() -> Void)?
    /// Sections extensions add to a page, after its settings (page id → the section's view).
    public var pageSections: [String: () -> AnyView] = [:]
    /// Advanced ▸ Show welcome again (onboarding, Phase 3).
    public var onShowWelcome: (() -> Void)?
    /// A locked setting (pane Pro's editions) shows this badge, not editable; clicking it opens `lockPage`.
    public var lockBadge = "Locked"
    public var lockPage: String?
    func isLocked(_ id: String) -> Bool { store.isLocked(id: id) }
    /// An extension shows window thumbnails: Settings ▸ General lists the Screen Recording permission they need.
    public var offersPreviews = false
    /// Rows an extension draws itself (setting id → view), e.g. pane Pro's keyboard choice.
    public var customRows: [String: () -> AnyView] = [:]
    /// Keyboard ▸ the buttons that put a set of shortcuts back (pane Pro adds the Windows keyboard's).
    public var shortcutPresets: [(title: String, id: String, apply: () -> Void)] = []
    /// Pages with content the engine draws itself.
    static let pagesWithSections: Set<String> = ["keyboard", "advanced", "about"]
    /// The pages shown: those with settings or sections (pane Pro's fill some: App exceptions, pane Pro).
    var pages: [SettingsPage] {
        SettingsPages.all.filter { page in
            Self.pagesWithSections.contains(page.id) || pageSections[page.id] != nil || page.groups.contains { !$0.ids.isEmpty }
        }
    }

    private(set) var conflicts: [ShortcutConflict] = []
    private lazy var macOSShortcuts = ShortcutConflicts.macOSShortcuts()
    private var observation: SettingsObservation?

    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static let lastPageKey = "PaneSettingsLastPage", advancedKey = "PaneSettingsShowAdvanced"

    public init(store: SettingsStore) {
        self.store = store
        shortcutPresets = [("Restore Mac shortcuts", "settings.keys.restoreMac", { [store] in store.applyShortcutPreset("mac") })]
        page = SettingsPages.page(Self.defaults.string(forKey: Self.lastPageKey))?.id ?? "general"
        showAdvanced = Self.defaults.bool(forKey: Self.advancedKey)
        observation = store.observeAll { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        conflicts = ShortcutConflicts.check(store, macOS: macOSShortcuts)
        pending = pendingRestart().sorted()
        revision += 1
    }

    var currentPage: SettingsPage { SettingsPages.page(page).flatMap { p in pages.first { $0.id == p.id } } ?? pages[0] }

    /// Shown in the window: not planned (planned shortcuts excepted: shown greyed), not internal, advanced only when asked.
    func isShown(_ id: String) -> Bool {
        guard let s = PaneSettings.setting(id: id), !SettingsPages.internalIDs.contains(id) else { return false }
        if s.info.status == .planned && s.info.kind != .shortcut { return false }
        return showAdvanced || !s.info.advanced
    }

    /// Greyed out while the setting it depends on is off (e.g. the snap switches without "Snap windows").
    func isEnabled(_ id: String) -> Bool {
        if PaneSettings.setting(id: id)?.info.status == .planned { return false }
        guard let dep = PaneSettings.dependsOn[id] else { return true }
        return store.json(dep.id) == dep.value
    }

    func conflicts(for id: String) -> [ShortcutConflict] { conflicts.filter { $0.shortcut.setting.id == id } }

    func title(_ id: String) -> String { PaneSettings.setting(id: id)?.info.title ?? id }
}

/// The settings window (D1: AppKit hosting SwiftUI; D3: no taskbar button, no Alt+Tab entry — the inventory leaves
/// pane's own windows out). One window, reused: closing hides it.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let model: SettingsModel
    private var pageWatch: AnyCancellable?

    public init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("pane.settings")
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        // A test agent keeps its own frame (StatusItems.namePrefix: "PaneTest").
        let frameName = "\(StatusItems.namePrefix)SettingsWindow"
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) { window.center() }
        super.init(window: window)
        window.delegate = self
        // Minimize and zoom off: a settings window, like macOS's own.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.title = model.currentPage.title
        pageWatch = model.$page.sink { [weak window] id in window?.title = SettingsPages.page(id)?.title ?? "pane Settings" }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public var isShown: Bool { window?.isVisible == true }

    /// Shows the window in front, on `page` if given (else the last page). `search:<words>` opens it searching.
    public func show(page: String?) {
        if let page, page.hasPrefix("search:") { model.search = String(page.dropFirst("search:".count)) }
        else if let page, let p = SettingsPages.page(page) { model.page = p.id; model.search = "" }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // A recorder left focused must not keep pane's keys off.
        window?.makeFirstResponder(nil)
        ShortcutRecording.end()
    }
}
