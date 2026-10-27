// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

/// The Start menu's state, shared by its SwiftUI views.
@MainActor
public final class StartMenuModel: ObservableObject {
    public let index: AppIndex
    public let store: StartStore
    public let prefs: SettingsStore
    public let search: StartSearch

    @Published public var query = "" { didSet { if query != oldValue { runSearch() } } }
    @Published public private(set) var results: [StartResult] = []
    @Published public private(set) var fileResults: [StartResult] = []
    @Published public var selection: String?
    @Published public var showAllPins = false
    /// The pinned folder shown open (its index in the pinned list).
    @Published public var openFolder: Int?
    /// An overlay over Start (an extension's: e.g. an expanded category). Esc closes it.
    @Published public var overlay: AnyView?
    @Published public var jumpGrid = false
    @Published public var scrollTarget: String?
    @Published public private(set) var revision = 0

    public var onClose: (() -> Void)?
    /// Extensions (pane Pro): making folders, recent files, more All views.
    public var canMakeFolders: () -> Bool = { false }
    public var recentFiles: () -> [RecentFiles.Item] = { [] }
    /// Called as Start opens (an extension refreshes what it shows).
    public var onWillShow: (() -> Void)?
    public struct AllView {
        public let id: String
        public let title: String
        public let isAvailable: () -> Bool
        public let view: () -> AnyView
        public init(id: String, title: String, isAvailable: @escaping () -> Bool, view: @escaping () -> AnyView) {
            self.id = id; self.title = title; self.isAvailable = isAvailable; self.view = view
        }
    }
    /// All views besides Grid and List (Category, from pane Pro).
    public var extraAllViews: [AllView] = []
    /// The All view in effect: the setting's, if it's available here, else the Grid.
    public var allView: String {
        let view = prefs[PaneSettings.startAllView]
        if view == "grid" || view == "list" { return view }
        return extraAllViews.contains { $0.id == view && $0.isAvailable() } ? view : "grid"
    }
    /// Something an extension shows changed: redraw.
    public func changed() { revision += 1 }
    public var isPinnedToTaskbar: (String) -> Bool = { _ in false }
    public var setPinnedToTaskbar: (String, Bool) -> Void = { _, _ in }
    /// A pane setting found by search: open pane's Settings on that page.
    public var onOpenPaneSettings: ((String) -> Void)?
    /// For tests: what was opened ("app:<id>", "file:<path>", "setting:<id>", "place:<name>", "power:<action>").
    public var onOpened: ((String) -> Void)?

    private var observations: [SettingsObservation] = []

    public init(index: AppIndex, store: StartStore, prefs: SettingsStore) {
        self.index = index
        self.store = store
        self.prefs = prefs
        search = StartSearch(index: index)
        let bump: () -> Void = { [weak self] in self?.revision += 1 }
        index.onChange = bump
        store.onChange = bump
        observations.append(prefs.observeAll { [weak self] id in if id.hasPrefix("start.") || id.hasPrefix("taskbar.") { self?.revision += 1 } })
    }

    // MARK: Layout

    /// Windows' sizes: 8 pinned columns on large screens, 6 on small (Automatic picks by screen width).
    public var isLarge: Bool {
        switch prefs[PaneSettings.startSize] {
        case "large": return true
        case "small": return false
        default: return (NSScreen.screens.first?.frame.width ?? 1440) >= 1600
        }
    }
    public var columns: Int { isLarge ? 8 : 6 }
    public var recentLimit: Int { isLarge ? 6 : 4 }
    public var categoryColumns: Int { isLarge ? 4 : 3 }
    public var size: CGSize { isLarge ? CGSize(width: 800, height: 760) : CGSize(width: 650, height: 700) }

    public var pinned: [PinnedItem] {
        store.pinned.filter { item in item.apps.contains { index.app($0) != nil } }
    }

    public var recentItems: [RecentFiles.Item] {
        RecentFiles.items(index: index, store: store, files: recentFiles(),
                          includeApps: prefs[PaneSettings.startRecentlyAdded], limit: recentLimit)
    }

    // MARK: Search

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        results = search.instant(q)
        fileResults = []
        selection = StartSearch.bestMatch(results, query: q)?.id
        guard !q.isEmpty else { search.cancelFiles(); return }
        search.files(q) { [weak self] found in
            guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
            self.fileResults = found
            if self.selection == nil { self.selection = found.first?.id }
        }
    }

    public var allResults: [StartResult] { results + fileResults }

    public func moveSelection(_ delta: Int) {
        let all = allResults
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == selection } ?? -1
        selection = all[max(0, min(all.count - 1, i + delta))].id
    }

    public func openSelection() {
        guard let result = allResults.first(where: { $0.id == selection }) ?? allResults.first else { return }
        open(result)
    }

    // MARK: Actions (each closes Start, as on Windows)

    public func launch(_ app: AppIndex.App) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        finish("app:\(app.id)")
    }

    public func launch(id: String) { if let app = index.app(id) { launch(app) } }

    public func open(_ result: StartResult) {
        switch result.kind {
        case .app: launch(id: result.target)
        case .systemSetting: if let url = result.url { NSWorkspace.shared.open(url) }; finish(result.id)
        case .paneSetting: onOpenPaneSettings?(result.target); finish(result.id)
        case .file, .folder: if let url = result.url { NSWorkspace.shared.open(url) }; finish(result.id)
        }
    }

    public func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
        finish("file:\(url.path)")
    }

    public func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        finish("finder:\(url.path)")
    }

    public func open(_ place: StartPlace) {
        place.open()
        finish("place:\(place.rawValue)")
    }

    public func power(_ action: PowerAction) {
        finish("power:\(action.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = Power.perform(action) }
    }

    public func openAccountSettings() {
        Account.openSettings()
        finish("account:settings")
    }

    private func finish(_ what: String) {
        onOpened?(what)
        onClose?()
    }

    /// Back to the start view (a new open, or Esc in search).
    public func reset() {
        query = ""
        openFolder = nil
        overlay = nil
        jumpGrid = false
        showAllPins = prefs[PaneSettings.startShowAllPins]
        scrollTarget = nil
    }
}

/// The Start panel: glass, centred above the taskbar (or above the Start button with left alignment). It takes the
/// keyboard without activating pane (so the app you were in stays the active one), and closes on Esc, a click
/// elsewhere, launching something, or Start again.
@MainActor
public final class StartMenuController: NSObject {
    public let model: StartMenuModel
    public let panel: NSPanel
    private let hosting: NSHostingView<StartRootView>
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Where Start opens: the taskbar's top edge and the Start button (AppKit coordinates).
    public var anchor: () -> (barTop: CGFloat, startButton: NSRect?, leftAligned: Bool) = { (48, nil, false) }
    public private(set) var lastOpenMilliseconds: Double = 0

    final class StartPanel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    public init(model: StartMenuModel) {
        self.model = model
        let panel = StartPanel(contentRect: NSRect(origin: .zero, size: model.size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = "Start"
        panel.setAccessibilityIdentifier("pane.start")
        panel.setAccessibilityTitle("Start")
        GlassSurface.configure(panel, shadow: true)
        hosting = NSHostingView(rootView: StartRootView(model: model))
        let surface = GlassSurface(role: .popup, cornerRadius: 12, content: hosting)
        panel.contentView = surface
        self.panel = panel
        super.init()
        panel.onCancel = { [weak self] in self?.cancel() }
        model.onClose = { [weak self] in self?.hide() }
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open }
            }
        }
    }

    public var isShown: Bool { panel.isVisible }

    public func toggle() { isShown ? hide() : show() }

    /// Opens Start; `search` opens it searching (Win+S, and tests).
    public func show(search: String? = nil) {
        let start = Date()
        model.reset()
        model.onWillShow?()
        if let search { model.query = search }
        let size = model.size
        let (barTop, button, left) = anchor()
        let screen = NSScreen.screens.first?.frame ?? .zero
        let x = left ? max(screen.minX + 12, (button?.minX ?? screen.minX + 12)) : screen.midX - size.width / 2
        let height = min(size.height, screen.height - barTop - 48)
        panel.setFrame(NSRect(x: x, y: screen.minY + barTop + 12, width: size.width, height: height), display: false)
        panel.makeKeyAndOrderFront(nil)
        lastOpenMilliseconds = Date().timeIntervalSince(start) * 1000
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // A menu of Start's own (account, power, a context menu) takes key for a moment: only close when focus
            // went to another window.
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let self, self.isShown, !self.panel.isKeyWindow, NSApp.keyWindow !== self.panel, NSApp.modalWindow == nil,
                          !self.menuOpen else { return }
                    self.hide()
                }
            }
        }
    }

    /// Esc: out of search, out of an open folder or the letter grid, else closed.
    func cancel() {
        if model.openFolder != nil { model.openFolder = nil; return }
        if model.jumpGrid { model.jumpGrid = false; return }
        if model.overlay != nil { model.overlay = nil; return }
        if !model.query.isEmpty { model.query = ""; return }
        hide()
    }

    /// True while one of Start's menus is open (tracked by NSMenu notifications).
    var menuOpen = false

    public func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        model.search.cancelFiles()
    }
}
