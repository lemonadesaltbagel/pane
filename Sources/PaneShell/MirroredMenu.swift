// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Pops up one of a window's menus (mirrored through AX) as a native NSMenu — used by the strip and by Alt
/// mode when no strip is shown. Items run against `window` (focused first).
@MainActor
public enum MirroredMenu {
    public static func popUp(_ entry: MenuEntry, for window: AXUIElement, atAX point: CGPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in MenuMirror.items(of: entry) {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: item.title + (item.shortcut.map { "\t\($0)" } ?? ""), action: #selector(Runner.run(_:)), keyEquivalent: "")
            menuItem.target = Runner.shared
            menuItem.representedObject = Runner.Payload(entry: item, window: window)
            menuItem.isEnabled = item.isEnabled && !item.hasSubmenu
            menu.addItem(menuItem)
        }
        let cocoa = Geometry.axToCocoa(CGRect(origin: point, size: .zero), primaryHeight: Geometry.primaryHeight).origin
        menu.popUp(positioning: nil, at: cocoa, in: nil)
    }

    /// Alt + letter without a strip: the menu at index `index`, at the window's top-left under the title bar.
    public static func popUpFocusedWindowMenu(_ index: Int) {
        guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid), let frame = AX.frame(window) else { return }
        let menus = MenuMirror.topLevel(of: pid)
        guard menus.indices.contains(index) else { return }
        popUp(menus[index], for: window, atAX: CGPoint(x: frame.minX + 8, y: frame.minY + MouseTap.titleBarHeight))
    }

    public static func focusedWindowMnemonics() -> [Character?] {
        guard let pid = AX.frontmostPID() else { return [] }
        return Mnemonics.assign(MenuMirror.topLevel(of: pid).map(\.title))
    }

    final class Runner: NSObject {
        static let shared = Runner()
        struct Payload { let entry: MenuEntry; let window: AXUIElement }

        @objc func run(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? Payload else { return }
            MenuMirror.perform(payload.entry, for: payload.window)
        }
    }
}
