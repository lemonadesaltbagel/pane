// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// pane's own menu-bar icon (setting `general.showMenuBarIcon`, D2: optional, as in Bartender and AltTab): Settings…,
/// Pause, Quit. It sits at the rightmost movable slot, right of the tray's divider, so hiding other apps' icons never
/// hides it. With the tray in the menu bar, pane's chevron is the icon instead (right-click it for the same menu).
@MainActor
public final class MenuBarIcon: NSObject {
    public static let autosaveName = "\(StatusItems.namePrefix)MenuIcon"
    public private(set) var item: NSStatusItem?
    public var onSettings: (() -> Void)?
    public var onTogglePause: (() -> Void)?
    public var isPaused: () -> Bool = { false }
    /// An extension's purchase item (its title), shown while `isPro` is false.
    public var isPro: () -> Bool = { true }
    public var onBuy: (() -> Void)?
    public var buyTitle = "Buy…"
    /// A newer release (`UpdateCheck`): "Update available" opens its page.
    public var update: UpdateCheck.Release?

    public func install() {
        guard item == nil else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSStatusItem Visible \(Self.autosaveName)")
        if defaults.object(forKey: "NSStatusItem Preferred Position \(Self.autosaveName)") == nil {
            defaults.set(0, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        item.behavior = []
        item.button?.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "pane")
        item.button?.setAccessibilityTitle("Pane")
        item.menu = makeMenu()
        self.item = item
    }

    public func uninstall() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// The menu (also the menu-bar chevron's right-click menu).
    public func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let settings = NSMenuItem(title: "pane Settings…", action: #selector(settingsChosen), keyEquivalent: "")
        let pause = NSMenuItem(title: "Pause pane", action: #selector(pauseChosen), keyEquivalent: "")
        pause.identifier = NSUserInterfaceItemIdentifier("pause")
        let quit = NSMenuItem(title: "Quit pane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let buy = NSMenuItem(title: buyTitle, action: #selector(buyChosen), keyEquivalent: "")
        buy.identifier = NSUserInterfaceItemIdentifier("buy")
        let update = NSMenuItem(title: "Update available…", action: #selector(updateChosen), keyEquivalent: "")
        update.identifier = NSUserInterfaceItemIdentifier("update")
        for i in [settings, pause, buy, update] { i.target = self }
        menu.items = [settings, pause, buy, update, .separator(), quit]
        return menu
    }

    @objc private func settingsChosen() { onSettings?() }
    @objc private func pauseChosen() { onTogglePause?() }
    @objc private func buyChosen() { onBuy?() }
    @objc private func updateChosen() { if let page = update?.page { NSWorkspace.shared.open(page) } }
}

extension MenuBarIcon: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first { $0.identifier?.rawValue == "pause" }?.state = isPaused() ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "buy" }?.isHidden = isPro() || onBuy == nil
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "update" }) {
            item.isHidden = update == nil
            item.title = update.map { "Update available: pane \($0.version)…" } ?? "Update available…"
        }
    }
}

/// Names of pane's status items (saved positions live in the process's own defaults): a test agent uses its own names,
/// so it never moves your icons.
public enum StatusItems {
    nonisolated public static var namePrefix: String { ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] == nil ? "Pane" : "PaneTest" }
}
