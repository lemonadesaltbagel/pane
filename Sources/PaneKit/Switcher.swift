// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox

/// Most-recently-focused order of windows, fed by inventory updates (the focused window is known per refresh)
/// and explicit notes when pane itself focuses a window.
public final class FocusHistory {
    private let lock = NSLock()
    private var order: [CGWindowID] = []

    public init() {}

    public func note(_ wid: CGWindowID) {
        lock.withLock {
            order.removeAll { $0 == wid }
            order.insert(wid, at: 0)
        }
    }

    public func update(_ windows: [ManagedWindow]) {
        if let focused = windows.first(where: \.isFocused) { note(focused.id) }
        let alive = Set(windows.map(\.id))
        lock.withLock { order.removeAll { !alive.contains($0) } }
    }

    /// Window ids most-recent first; never-focused ones keep their given order after them.
    public func mostRecentFirst(_ wids: [CGWindowID]) -> [CGWindowID] {
        let rank = lock.withLock { Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) }) }
        return wids.enumerated().sorted { a, b in
            switch (rank[a.element], rank[b.element]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// `windows` sorted most-recent first; never-focused windows follow in seat order.
    public func sorted(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        let rank = lock.withLock { Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) }) }
        return windows.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.seat < b.seat
            }
        }
    }
}

/// Windows Alt+Tab, per window: hold the trigger modifier (⌥), Tab steps forward, ⇧Tab / ← back, → forward,
/// Esc cancels, releasing the modifier focuses the selection. The UI is a callback surface (`onShow`,
/// `onSelect`, `onHide`); pane's own harness or the real UI renders it.
public final class SwitcherController {
    public struct Options {
        public var modifier: CGEventFlags = .maskAlternate
        /// Windows' default: only the current desktop.
        public var allSpaces = false
        /// Apps whose own Alt+Tab wins while they're in front (a Windows VM, a remote desktop).
        public var ignoredApps: Set<String> = []
        public init() {}
    }

    public let options: Options
    /// Extra filter (Windows: Alt+Tab lists only the current virtual desktop's windows).
    public var windowFilter: ((ManagedWindow) -> Bool)?
    public var onShow: (([ManagedWindow], Int) -> Void)?
    public var onSelect: ((Int) -> Void)?
    public var onHide: ((_ committed: ManagedWindow?) -> Void)?
    public private(set) var isActive = false
    public private(set) var items: [ManagedWindow] = []
    public private(set) var selection = 0

    private let inventory: WindowInventory
    private let history: FocusHistory
    private var keys: KeyTap?
    private let lock = NSLock()

    public init(inventory: WindowInventory, history: FocusHistory, options: Options = Options()) {
        self.inventory = inventory
        self.history = history
        self.options = options
    }

    public func start() throws {
        let keys = try KeyTap()
        let ignored = options.ignoredApps
        if !ignored.isEmpty { keys.isSuppressed = { [weak self] in !(self?.isActive ?? false) && (FrontmostApp.shared.bundleID.map(ignored.contains) ?? false) } }
        keys.interceptor = { [weak self] keyCode, flags in self?.intercept(Int(keyCode), flags) ?? false }
        keys.onFlagsChanged = { [weak self] flags in
            guard let self, self.lock.withLock({ self.isActive }), !flags.contains(self.options.modifier) else { return }
            self.commit()
        }
        self.keys = keys
    }

    public func stop() {
        keys?.stop()
        keys = nil
    }

    private func intercept(_ keyCode: Int, _ flags: CGEventFlags) -> Bool {
        let active = lock.withLock { isActive }
        let held = flags.contains(options.modifier) && flags.intersection([.maskCommand, .maskControl, .maskAlternate]) == options.modifier
        switch keyCode {
        case kVK_Tab where held:
            if active { step(flags.contains(.maskShift) ? -1 : 1) } else { begin(reverse: flags.contains(.maskShift)) }
            return true
        case kVK_Tab where !active && flags.contains(options.modifier):
            // Diagnostics: an Alt+Tab that did nothing (another modifier held too).
            PaneLog.write("switcher: Tab with other modifiers held (flags \(flags.rawValue)), not Alt+Tab")
            return false
        case kVK_Escape where active:
            cancel()
            return true
        case kVK_LeftArrow where active, kVK_UpArrow where active:
            step(-1)
            return true
        case kVK_RightArrow where active, kVK_DownArrow where active:
            step(1)
            return true
        default:
            return false
        }
    }

    private func begin(reverse: Bool) {
        // This desktop's windows, minimized ones, and full-screen apps (Windows lists those too; on macOS they live on
        // their own Space, which commit() reaches).
        let fullScreenSpaces = PrivateAPI.fullscreenSpaces()
        func onFullScreenSpace(_ w: ManagedWindow) -> Bool {
            !fullScreenSpaces.isEmpty && !fullScreenSpaces.isDisjoint(with: PrivateAPI.spaces(of: w.id))
        }
        let windows = inventory.windows.filter {
            (options.allSpaces || $0.isOnVisibleSpace || $0.isMinimized || onFullScreenSpace($0)) && (windowFilter?($0) ?? true)
        }
        let ordered = history.sorted(windows)
        guard !ordered.isEmpty else { PaneLog.write("switcher: no windows to show (\(inventory.windows.count) in the list)"); return }
        let start = ordered.count > 1 ? (reverse ? ordered.count - 1 : 1) : 0
        lock.withLock {
            items = ordered
            selection = start
            isActive = true
        }
        DispatchQueue.main.async { [weak self] in self?.onShow?(ordered, start) }
    }

    private func step(_ delta: Int) {
        let index = lock.withLock { () -> Int in
            guard !items.isEmpty else { return 0 }
            selection = (selection + delta + items.count) % items.count
            return selection
        }
        DispatchQueue.main.async { [weak self] in self?.onSelect?(index) }
    }

    /// The pointer moved onto a tile (Windows: hovering selects).
    public func setSelection(_ index: Int) {
        let changed = lock.withLock { () -> Bool in
            guard isActive, items.indices.contains(index), selection != index else { return false }
            selection = index
            return true
        }
        if changed { DispatchQueue.main.async { [weak self] in self?.onSelect?(index) } }
    }

    /// A tile was clicked: switch to it now (the modifier may still be held).
    public func choose(_ index: Int) {
        let ok = lock.withLock { () -> Bool in
            guard isActive, items.indices.contains(index) else { return false }
            selection = index
            return true
        }
        if ok { commit() }
    }

    private func cancel() {
        lock.withLock { isActive = false; items = [] }
        DispatchQueue.main.async { [weak self] in self?.onHide?(nil) }
    }

    private func commit() {
        let target = lock.withLock { () -> ManagedWindow? in
            defer { isActive = false; items = [] }
            return items.indices.contains(selection) ? items[selection] : nil
        }
        if let target {
            let element = inventory.element(for: target.id)
            if let element, target.isOnVisibleSpace || target.isMinimized { Focus.focusBest(element) }
            else { Focus.focusAnywhere(wid: target.id, pid: target.pid, element: element) }
            history.note(target.id)
            inventory.scheduleRefresh()
        }
        DispatchQueue.main.async { [weak self] in self?.onHide?(target) }
    }
}
