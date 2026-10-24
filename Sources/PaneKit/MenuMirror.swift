// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Decision 5 (per-window menus): the app's menu bar, read through AX, so it can be shown inside each window
/// (Menu-Bar-Search / menuffy technique). Submenus are read when opened, never cached, because apps update
/// their menus lazily (validation runs as the menu opens).
public struct MenuEntry {
    public let title: String
    public let isEnabled: Bool
    public let isSeparator: Bool
    public let hasSubmenu: Bool
    /// e.g. "⌘N", from AXMenuItemCmdChar / AXMenuItemCmdModifiers.
    public let shortcut: String?
    public let element: AXUIElement

    public init(title: String, isEnabled: Bool, isSeparator: Bool, hasSubmenu: Bool, shortcut: String?, element: AXUIElement) {
        self.title = title
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.hasSubmenu = hasSubmenu
        self.shortcut = shortcut
        self.element = element
    }
}

public enum MenuMirror {
    /// Top-level menus (File, Edit, …), without the Apple menu.
    public static func topLevel(of pid: pid_t) -> [MenuEntry] {
        AX.menuBarItems(of: pid).dropFirst(firstIsApple(pid) ? 1 : 0).map { title, element in
            MenuEntry(title: title, isEnabled: AX.get(element, kAXEnabledAttribute) ?? true, isSeparator: false, hasSubmenu: true,
                      shortcut: nil, element: element)
        }
    }

    private static func firstIsApple(_ pid: pid_t) -> Bool {
        AX.menuBarItems(of: pid).first?.0 == "Apple"
    }

    /// Items of a menu-bar item or of a submenu item, read fresh.
    public static func items(of entry: MenuEntry) -> [MenuEntry] {
        guard let menus: [AXUIElement] = AX.get(entry.element, kAXChildrenAttribute), let menu = menus.first,
              let children: [AXUIElement] = AX.get(menu, kAXChildrenAttribute) else { return [] }
        return children.map { element in
            let title = AX.title(element) ?? ""
            let sub: [AXUIElement] = AX.get(element, kAXChildrenAttribute) ?? []
            return MenuEntry(title: title, isEnabled: AX.get(element, kAXEnabledAttribute) ?? false, isSeparator: title.isEmpty && sub.isEmpty,
                             hasSubmenu: !sub.isEmpty, shortcut: shortcut(of: element), element: element)
        }
    }

    static func shortcut(of element: AXUIElement) -> String? {
        guard let char: String = AX.get(element, kAXMenuItemCmdCharAttribute), !char.isEmpty else { return nil }
        let mods: Int = AX.get(element, kAXMenuItemCmdModifiersAttribute) ?? 0
        // kAXMenuItemModifier*: 1 shift, 2 option, 4 control, 8 = no command.
        var text = ""
        if mods & 4 != 0 { text += "⌃" }
        if mods & 2 != 0 { text += "⌥" }
        if mods & 1 != 0 { text += "⇧" }
        if mods & 8 == 0 { text += "⌘" }
        return text + char
    }

    /// Runs a menu item for `window`: menus act on the key window, so the window comes forward first.
    @discardableResult
    public static func perform(_ entry: MenuEntry, for window: AXUIElement?) -> Bool {
        if let window, let pid = AX.pid(of: window), AX.frontmostPID() != pid || AX.focusedWindow(of: pid).map({ !CFEqual($0, window) }) ?? true {
            Focus.focusBest(window)
        }
        return AX.perform(entry.element, kAXPressAction) == .success
    }
}

/// Windows-style menu accelerators (the underlined letters): first letter not taken yet, else any later letter.
public enum Mnemonics {
    public static func assign(_ titles: [String]) -> [Character?] {
        var used = Set<Character>()
        return titles.map { title in
            let letters = title.lowercased().filter(\.isLetter)
            guard let pick = letters.first(where: { !used.contains($0) }) else { return nil }
            used.insert(pick)
            return pick
        }
    }
}

/// Follows one window's frame: SkyLight moved/resized events (needs NSApp running) plus a slow AX poll.
public final class WindowTracker {
    public let wid: CGWindowID
    public let element: AXUIElement
    /// Called on the main queue with the window's AX frame.
    public var onFrame: ((CGRect) -> Void)?
    /// Called on the main queue when the window comes forward (to re-order attached UI above it).
    public var onFocused: (() -> Void)?

    private var token: UUID?
    private var timer: Timer?
    private var last: CGRect?

    public init?(element: AXUIElement) {
        guard let wid = PrivateAPI.windowID(of: element) else { return nil }
        self.wid = wid
        self.element = element
    }

    /// The poll catches the occasional missed move event (measured: 1 in 5 programmatic moves).
    public func start(poll: TimeInterval = 0.25) {
        let events = WindowServerEvents.shared
        events.start()
        events.watch([wid])
        token = events.addSubscriber { [weak self] kind, wid in
            guard let self, wid == self.wid else { return }
            switch kind {
            case .moved, .resized: DispatchQueue.main.async { self.check() }
            case .focused, .orderedIn: DispatchQueue.main.async { self.onFocused?(); self.check() }
            default: break
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: poll, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    public func stop() {
        if let token { WindowServerEvents.shared.removeSubscriber(token) }
        token = nil
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard let frame = AX.frame(element), frame != last else { return }
        last = frame
        onFrame?(frame)
    }
}
