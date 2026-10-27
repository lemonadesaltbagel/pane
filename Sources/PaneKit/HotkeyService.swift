// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox

/// Windows keyboard behaviors on top of `KeyTap`. ⌘ = Win, ⌥ = Alt.
///
/// By default pane uses chords macOS doesn't (snap on ⌃⌥ arrows). The ⌘ chords that collide with macOS text navigation
/// and app shortcuts (⌘←/→/↑/↓, ⌘1…9) are behind their own switches, off by default (a Windows-style keyboard turns
/// them on).
public final class HotkeyService {
    public struct Options {
        /// ⌥F4 → close the focused window (quitting the app is then up to LifecycleService).
        public var altF4 = true
        /// ⌘←/→/↑/↓ snap instead of ⌃⌥ arrows. Off by default.
        public var winArrows = false
        /// ⌘1…9 → taskbar item. Off by default.
        public var winNumbers = false
        /// ⌘ tapped alone → Start.
        public var winTap = true
        /// ⌥ tapped alone → menu navigation.
        public var altTap = true
        /// ⌃⌘F (macOS's full-screen shortcut) → Windows-style full screen on the current desktop.
        public var fullScreenKey = true
        /// Rebinds actions (settings `keys.*`): a value replaces the built-in chord, nil turns the action off. Actions
        /// not listed keep their built-in chord; each group switch above still gates its actions.
        public var bindings: [Shortcut: KeyBinding?] = [:]
        /// Bundle IDs whose own keys win: pane's chords stand down while they're in front (`apps.ignoreShortcuts`).
        public var ignoredApps: Set<String> = []
        public init() {}

        /// The chord in effect for an action (nil = off): yours, else ⌘ arrows / ⌘ digits when `winArrows` /
        /// `winNumbers` ask for them, else the default (snap on ⌃⌥ arrows, no taskbar digits).
        public func binding(_ action: Shortcut) -> KeyBinding? {
            if let override = bindings[action] { return override }
            switch action {
            case .snapLeft where winArrows: return KeyBinding([.cmd], "left")
            case .snapRight where winArrows: return KeyBinding([.cmd], "right")
            case .maximize where winArrows: return KeyBinding([.cmd], "up")
            case .minimizeOrRestore where winArrows: return KeyBinding([.cmd], "down")
            default:
                if winNumbers, action.rawValue.hasPrefix("taskbarItem"), let d = action.rawValue.last { return KeyBinding([.cmd], String(d)) }
                return action.defaultBinding
            }
        }
    }

    /// Extensions may adjust these before `start` (pane Pro's Windows keyboard: its preset, ⌘ arrows and digits).
    public var options: Options
    public var onStart: (() -> Void)?
    public var onMenuKey: (() -> Void)?
    public var onTaskbarIndex: ((Int) -> Void)?
    /// ⌃⌘F pressed (main queue).
    public var onFullScreenKey: (() -> Void)?
    /// Show desktop / open Finder (Windows mode's ⌘D / ⌘E), main queue.
    public var onShowDesktop: (() -> Void)?
    public var onFileExplorer: (() -> Void)?
    public var onSettings: (() -> Void)?
    /// Extensions' shortcuts (pane Pro's Task View, desktops, Quick Link): bound at `start`, handled on the main queue.
    private var extra: [(Shortcut, () -> Void)] = []
    /// Alt-key menu mode: after a lone ⌥ tap, the next plain letter picks a menu by its underlined letter.
    /// Provider: mnemonics of the focused window's menus; handler: open menu at index (main queue).
    public var menuMnemonics: (() -> [Character?])?
    public var onMenuMnemonic: ((Int) -> Void)?
    private var armedUntil: Date?
    private var armedMnemonics: [Character?] = []
    private let armLock = NSLock()
    /// keyCode → character for the current layout, built on the main thread (TIS must run there).
    private var letters: [Int: Character] = [:]

    private let snap: SnapService?
    private var keys: KeyTap?

    public init(options: Options = Options(), snap: SnapService?) {
        self.options = options
        self.snap = snap
    }

    /// An extension's shortcut (before `start`). Only shortcuts someone answers are bound: without pane Pro, its
    /// chords reach the apps.
    public func bind(_ shortcut: Shortcut, _ handler: @escaping () -> Void) {
        extra.append((shortcut, handler))
    }

    /// An extension's shortcut is on this chord (⌘Tab: macOS's app switcher must then be switched off).
    public func binds(_ chord: KeyBinding) -> Bool {
        extra.contains { options.binding($0.0) == chord }
    }

    /// Call on the main thread.
    public func start() throws {
        letters = Self.layoutTable()
        let keys = try KeyTap()
        let ignored = options.ignoredApps
        if !ignored.isEmpty { keys.isSuppressed = { FrontmostApp.shared.bundleID.map(ignored.contains) ?? false } }
        func bind(_ action: Shortcut, _ handler: @escaping () -> Void) {
            if let chord = options.binding(action)?.chord { keys.bind(chord, handler) }
        }
        if options.fullScreenKey {
            bind(.fullScreen) { [weak self] in DispatchQueue.main.async { self?.onFullScreenKey?() } }
        }
        // Virtual desktops and Task View are pane Pro's: their keys only when an extension answers them.
        if options.altF4 {
            bind(.closeWindow) { Self.closeFocusedWindow() }
        }
        // Snap and taskbar-digit chords (`Options.binding`): yours, else ⌘ ones behind their switches, else the defaults.
        if let snap {
            let arrows: [(Shortcut, SnapTransitions.Arrow)] = [(.snapLeft, .left), (.snapRight, .right), (.maximize, .up), (.minimizeOrRestore, .down)]
            for (action, arrow) in arrows { bind(action) { snap.arrowOnFocusedWindow(arrow) } }
        }
        let items: [Shortcut] = [.taskbarItem1, .taskbarItem2, .taskbarItem3, .taskbarItem4, .taskbarItem5, .taskbarItem6, .taskbarItem7, .taskbarItem8, .taskbarItem9]
        for (index, action) in items.enumerated() {
            bind(action) { [weak self] in DispatchQueue.main.async { self?.onTaskbarIndex?(index) } }
        }
        // Bound only when the user (or the Windows keyboard preset) gave them a chord.
        bind(.showDesktop) { [weak self] in DispatchQueue.main.async { self?.onShowDesktop?() } }
        bind(.fileExplorer) { [weak self] in DispatchQueue.main.async { self?.onFileExplorer?() } }
        bind(.settings) { [weak self] in DispatchQueue.main.async { self?.onSettings?() } }
        for (shortcut, handler) in extra { bind(shortcut) { DispatchQueue.main.async(execute: handler) } }
        // Lone-modifier taps: which modifier opens Start / menu mode (settings `keys.start`, `keys.menuMode`).
        func tapped(_ action: Shortcut) -> KeyTap.Modifier? {
            guard let b = options.binding(action), b.key == nil, let m = b.modifiers.first else { return nil }
            switch m { case .cmd: return .command; case .alt: return .option; case .ctrl: return .control; case .shift: return nil }
        }
        let startTap = options.winTap ? tapped(.start) : nil, menuTap = options.altTap ? tapped(.menuMode) : nil
        keys.onModifierTap = { [weak self] modifier in
            guard let self else { return }
            switch modifier {
            case startTap: DispatchQueue.main.async { self.onStart?() }
            case menuTap:
                // Mnemonics come from main-thread UI state; fetch there, then arm (the next key is ≥ tens of ms away).
                DispatchQueue.main.async {
                    if let provider = self.menuMnemonics {
                        let marks = provider()
                        self.armLock.withLock { self.armedMnemonics = marks; self.armedUntil = Date().addingTimeInterval(2) }
                    }
                    self.onMenuKey?()
                }
            default: break
            }
        }
        keys.interceptor = { [weak self] keyCode, flags in self?.interceptMnemonic(Int(keyCode), flags) ?? false }
        self.keys = keys
    }

    /// While armed: a plain letter matching a menu mnemonic opens it (swallowed); Esc disarms (swallowed);
    /// anything else disarms and passes through.
    private func interceptMnemonic(_ keyCode: Int, _ flags: CGEventFlags) -> Bool {
        guard armLock.withLock({ armedUntil.map { $0 > Date() } ?? false }) else { return false }
        let marks = armLock.withLock { () -> [Character?] in armedUntil = nil; return armedMnemonics }
        if keyCode == kVK_Escape { return true }
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              let letter = letters[keyCode], let index = marks.firstIndex(of: letter) else { return false }
        DispatchQueue.main.async { [weak self] in self?.onMenuMnemonic?(index) }
        return true
    }

    static func layoutTable() -> [Int: Character] {
        var table: [Int: Character] = [:]
        for code in 0..<64 { if let c = character(for: code), c.isLetter { table[code] = c } }
        return table
    }

    /// Layout-aware: the character this key produces with no modifiers (UCKeyTranslate, as SlowQuitApps does).
    static func character(for keyCode: Int) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(pointer, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased().first
    }

    public func stop() {
        keys?.stop()
        keys = nil
    }

    public static func closeFocusedWindow() {
        guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid),
              let close = AX.button(window, kAXCloseButtonAttribute) else { return }
        AX.perform(close, kAXPressAction)
    }
}
