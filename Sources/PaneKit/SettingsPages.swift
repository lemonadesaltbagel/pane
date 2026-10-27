// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// The settings window's pages (Windows 11 names), as data: which settings sit
/// on which page, in which group. A test checks that every setting a user can change is on exactly one page.
public struct SettingsPage: Identifiable, Sendable {
    public init(id: String, title: String, symbol: String, category: String?, groups: [Group]) {
        self.id = id; self.title = title; self.symbol = symbol; self.category = category; self.groups = groups
    }
    public struct Group: Sendable {
        public let title: String?
        public let ids: [String]
        public init(_ title: String?, _ ids: [String]) { self.title = title; self.ids = ids }
    }
    /// "general", "taskbar"… (`pane --open-settings <id>`).
    public let id: String
    public let title: String
    /// SF Symbol for the sidebar.
    public let symbol: String
    /// The sidebar header it sits under (nil: none).
    public let category: String?
    public let groups: [Group]
}

public enum SettingsPages {
    private static func keys(_ actions: [Shortcut]) -> [String] { actions.map(\.setting.id) }

    /// Where `add` puts settings in a group.
    public enum Position: Sendable { case start, end, after(String), before(String) }

    static let engine: [SettingsPage] = [
        SettingsPage(id: "general", title: "General", symbol: "gearshape", category: nil, groups: [
            .init("Startup", [PaneSettings.launchAtLogin.id, PaneSettings.showMenuBarIcon.id, PaneSettings.paused.id, PaneSettings.checkForUpdates.id]),
            .init("Apps", [PaneSettings.quitOnLastWindow.id]),
        ]),
        SettingsPage(id: "colors", title: "Colors", symbol: "paintpalette", category: "Personalization", groups: [
            .init(nil, [PaneSettings.theme.id, PaneSettings.material.id]),
        ]),
        SettingsPage(id: "start", title: "Start", symbol: "square.grid.3x3", category: "Personalization", groups: [
            .init(nil, [PaneSettings.startMenu.id, PaneSettings.startSize.id]),
            .init("Sections", [PaneSettings.startShowPinned.id, PaneSettings.startShowAllPins.id, PaneSettings.startShowRecent.id,
                               PaneSettings.startRecentlyAdded.id, PaneSettings.startMostUsed.id,
                               PaneSettings.startShowAll.id, PaneSettings.startAllView.id]),
            .init("Account and folders", [PaneSettings.startHideAccount.id, PaneSettings.startFolders.id]),
        ]),
        SettingsPage(id: "taskbar", title: "Taskbar", symbol: "dock.rectangle", category: "Personalization", groups: [
            .init("Taskbar items", [PaneSettings.replaceDock.id, PaneSettings.pinned.id, PaneSettings.syncDockPins.id]),
            .init("Taskbar behaviors", [PaneSettings.alignment.id, PaneSettings.autoHide.id, PaneSettings.combineButtons.id,
                                        PaneSettings.badges.id, PaneSettings.flashing.id,
                                        PaneSettings.farCornerShowsDesktop.id, PaneSettings.barHeight.id, PaneSettings.allDisplays.id]),
        ]),
        SettingsPage(id: "multitasking", title: "Multitasking", symbol: "rectangle.split.2x1", category: "System", groups: [
            .init("Snap windows", [PaneSettings.takeOverTiling.id]),
            .init("Alt + Tab", [PaneSettings.replaceCommandTab.id]),
            .init("Windows", [PaneSettings.clickThrough.id]),
        ]),
        SettingsPage(id: "keyboard", title: "Keyboard", symbol: "keyboard", category: "System", groups: [
            .init("Start and menus", keys([.start, .menuMode, .settings])),
            .init("Windows and snap", keys([.closeWindow, .fullScreen, .snapLeft, .snapRight, .maximize, .minimizeOrRestore, .nextDisplay])),
            .init("Taskbar", keys(Shortcut.taskbarItems + [.showDesktop, .fileExplorer])),
            .init("Switching", keys([.switcher])),
        ]),
        SettingsPage(id: "apps", title: "App exceptions", symbol: "square.grid.2x2", category: "Apps", groups: []),
        SettingsPage(id: "advanced", title: "Advanced", symbol: "wrench.and.screwdriver", category: nil, groups: [
            .init("Troubleshooting", [PaneSettings.debugLog.id]),
        ]),
        SettingsPage(id: "about", title: "About", symbol: "info.circle", category: nil, groups: []),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [SettingsPage] = engine
    nonisolated(unsafe) private static var columns: [String] = [
        PaneSettings.hideFromTaskbar.id, PaneSettings.ignoreShortcuts.id, PaneSettings.snap.id, PaneSettings.quitOnLastWindow.id,
    ]

    /// Every page, with what pane Pro added (`add`). A page with nothing to show is left out of the window.
    public static var all: [SettingsPage] { lock.withLock { pages } }

    /// The App exceptions table's columns: per-app settings, in order. (Some are also global settings on their page.)
    public static var exceptionColumns: [String] { lock.withLock { columns } }

    /// Adds a page (pane Pro's tray page) after another one.
    public static func add(page: SettingsPage, after other: String) {
        lock.withLock {
            guard !pages.contains(where: { $0.id == page.id }) else { return }
            let index = pages.firstIndex { $0.id == other }.map { $0 + 1 } ?? pages.count
            pages.insert(page, at: index)
        }
    }

    /// Adds settings to a page's group (made, after `groupAfter` or at the end, when the page has no such group).
    public static func add(_ ids: [String], page id: String, group title: String?, at position: Position = .end,
                           groupAfter: String? = nil, groupFirst: Bool = false) {
        lock.withLock {
            guard let p = pages.firstIndex(where: { $0.id == id }) else { return }
            var groups = pages[p].groups
            if let g = groups.firstIndex(where: { $0.title == title }) {
                var list = groups[g].ids.filter { !ids.contains($0) }
                let index: Int = switch position {
                case .start: 0
                case .end: list.count
                case .after(let other): list.firstIndex(of: other).map { $0 + 1 } ?? list.count
                case .before(let other): list.firstIndex(of: other) ?? list.count
                }
                list.insert(contentsOf: ids, at: index)
                groups[g] = .init(title, list)
            } else {
                let index = groupFirst ? 0 : (groupAfter.flatMap { t in groups.firstIndex { $0.title == t } }.map { $0 + 1 } ?? groups.count)
                groups.insert(.init(title, ids), at: index)
            }
            let old = pages[p]
            pages[p] = SettingsPage(id: old.id, title: old.title, symbol: old.symbol, category: old.category, groups: groups)
        }
    }

    public static func addExceptionColumns(_ ids: [String]) {
        lock.withLock { columns += ids.filter { !columns.contains($0) } }
    }

    /// Kept out of the window: pane's own state, changed by actions (Advanced ▸ Show welcome again).
    public static let internalIDs: Set<String> = [PaneSettings.onboardingDone.id]

    public static func page(_ id: String?) -> SettingsPage? {
        guard let id else { return nil }
        let alias = ["personalization": "colors", "system": "multitasking", "exceptions": "apps", "shortcuts": "keyboard", "keys": "keyboard", "license": "pro"]
        return all.first { $0.id == (alias[id.lowercased()] ?? id.lowercased()) }
    }

    /// The page a setting is on.
    public static func page(containing settingID: String) -> SettingsPage? {
        all.first { $0.groups.contains { $0.ids.contains(settingID) } }
            ?? (exceptionColumns.contains(settingID) ? page("apps") : nil)
    }
}
