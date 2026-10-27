// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import Carbon.HIToolbox

// Settings API (ENGINE-API.md §Settings): one typed catalog (`PaneSettings`) that a settings window can render
// without knowing each setting, one store (`SettingsStore`) with live observation, per-app overrides, import/export,
// reset, validation and the v1 config.json migration, and key bindings (`KeyBinding`, `Shortcut`) with conflict checks.
//
// File: ~/Library/Application Support/Pane/config.json
//   { "version": 2,
//     "settings": { "taskbar.combineButtons": "whenFull", "keys.snapLeft": "cmd+left" },
//     "apps": { "com.apple.Safari": { "lifecycle.quitOnLastWindow": false } } }
// Only values that differ from their defaults are written, so a later release can change a default.
// A v1 file (flat keys, no "version") is read as is and rewritten as v2 on the first change.

// MARK: - Values

/// A JSON value (settings are stored as JSON; any Codable value converts through it).
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    static func from<V: Encodable>(_ value: V) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decode<V: Decodable>(_ type: V.Type) -> V? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }
}

public protocol SettingValue: Codable, Equatable, Sendable {}
extension Bool: SettingValue {}
extension Int: SettingValue {}
extension Double: SettingValue {}
extension String: SettingValue {}
extension Array: SettingValue where Element: SettingValue {}
extension Optional: SettingValue where Wrapped: SettingValue {}

// MARK: - Describing a setting

/// Where a setting appears in a settings window.
public enum SettingSection: String, CaseIterable, Codable, Sendable {
    case general, appearance, start, taskbar, tray, windows, keyboard, switcher, desktops, fullScreen, apps, advanced
}

/// How a settings window should present the value.
public enum SettingKind: Equatable, Sendable {
    case toggle
    /// Fixed choices: stored value → label.
    case choice([Choice])
    case number(min: Double, max: Double, step: Double, unit: String)
    case text
    /// A list of bundle IDs (app pickers).
    case appList
    case shortcut
    /// Several of fixed choices ([String] of values), e.g. the folders next to Start's power button.
    case multiChoice([Choice])
    public struct Choice: Equatable, Sendable {
        public let value: String, label: String
        public init(_ value: String, _ label: String) { self.value = value; self.label = label }
    }
}

/// When a change takes effect.
public enum SettingStatus: String, Sendable {
    /// Applied immediately (pane observes it).
    case live
    /// Read at launch: pane must restart (a settings window offers "Restart pane").
    case restart
    /// Reserved for a feature that isn't built yet: stored and validated, hidden from settings windows.
    case planned
}

public struct SettingInfo: Sendable {
    public let section: SettingSection
    public let title: String
    public let help: String
    public let kind: SettingKind
    public let status: SettingStatus
    /// Can be overridden per app (`SettingsStore.setOverride`).
    public let perApp: Bool
    /// Shown only under "Advanced" / experiments.
    public let advanced: Bool
    /// The v1 config.json key, for migration.
    public let legacyKey: String?
}

/// A typed setting. `id` is stable forever (it's the stored key): rename the title, never the id.
public struct Setting<Value: SettingValue>: Sendable {
    public let id: String
    public let defaultValue: Value
    public let info: SettingInfo

    public init(_ id: String, _ defaultValue: Value, _ section: SettingSection, _ title: String, help: String = "",
                kind: SettingKind? = nil, status: SettingStatus = .restart, perApp: Bool = false, advanced: Bool = false, legacy: String? = nil) {
        self.id = id
        self.defaultValue = defaultValue
        let inferred: SettingKind = kind ?? {
            switch defaultValue {
            case is Bool: return .toggle
            case is [String], is [String]?: return .appList
            case is KeyBinding?: return .shortcut
            case is Double, is Int: return .number(min: 0, max: 1_000, step: 1, unit: "")
            default: return .text
            }
        }()
        info = SettingInfo(section: section, title: title, help: help, kind: inferred, status: status, perApp: perApp, advanced: advanced, legacyKey: legacy)
    }

    public var erased: AnySetting {
        AnySetting(id: id, info: info, defaultJSON: JSONValue.from(defaultValue) ?? .null) { json in
            guard let value = json.decode(Value.self) else { return false }
            return Self.valid(value, info.kind)
        }
    }

    static func valid(_ value: Value, _ kind: SettingKind) -> Bool {
        switch kind {
        case .choice(let choices): return (value as? String).map { v in choices.contains { $0.value == v } } ?? false
        case .multiChoice(let choices): return (value as? [String]).map { $0.allSatisfy { v in choices.contains { $0.value == v } } } ?? false
        case .number(let min, let max, _, _):
            let n = (value as? Double) ?? (value as? Int).map(Double.init)
            return n.map { $0 >= min && $0 <= max } ?? false
        default: return true
        }
    }
}

/// A setting with its type erased, for enumerating the catalog (settings windows, export, validation).
public struct AnySetting: Sendable {
    public let id: String
    public let info: SettingInfo
    public let defaultJSON: JSONValue
    public let accepts: @Sendable (JSONValue) -> Bool
}

// MARK: - Key bindings

/// A key chord ("ctrl+cmd+left") or a lone modifier tap ("tap:cmd"). Stored as that text; shown as "⌃⌘←".
public struct KeyBinding: SettingValue, Hashable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Codable, Sendable { case ctrl, alt, shift, cmd }
    public let modifiers: Set<Modifier>
    /// A key name from `KeyBinding.keyCodes` ("left", "d", "f4", "1"); nil for a lone-modifier tap.
    public let key: String?

    public init(_ modifiers: Set<Modifier>, _ key: String) { self.modifiers = modifiers; self.key = key.lowercased() }
    public static func tap(_ modifier: Modifier) -> KeyBinding { KeyBinding(modifiers: [modifier], key: nil) }
    private init(modifiers: Set<Modifier>, key: String?) { self.modifiers = modifiers; self.key = key }

    public init?(_ text: String) {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("tap:") {
            guard let m = Modifier(rawValue: Self.alias(String(t.dropFirst(4)))) else { return nil }
            self.init(modifiers: [m], key: nil)
            return
        }
        var parts = t.split(separator: "+").map { Self.alias(String($0)) }
        guard let key = parts.popLast(), Self.keyCodes[key] != nil else { return nil }
        var mods: Set<Modifier> = []
        for p in parts { guard let m = Modifier(rawValue: p) else { return nil }; mods.insert(m) }
        self.init(modifiers: mods, key: key)
    }

    static func alias(_ s: String) -> String {
        switch s {
        case "control", "⌃": return "ctrl"
        case "option", "opt", "⌥": return "alt"
        case "command", "⌘", "win": return "cmd"
        case "⇧": return "shift"
        case "←": return "left"
        case "→": return "right"
        case "↑": return "up"
        case "↓": return "down"
        default: return s
        }
    }

    public var text: String {
        let mods = Modifier.allCases.filter(modifiers.contains).map(\.rawValue)
        guard let key else { return "tap:\(mods.first ?? "cmd")" }
        return (mods + [key]).joined(separator: "+")
    }
    public var description: String { text }

    /// macOS order and glyphs: ⌃⌥⇧⌘ then the key.
    public var display: String {
        let glyph: [Modifier: String] = [.ctrl: "⌃", .alt: "⌥", .shift: "⇧", .cmd: "⌘"]
        let mods = Modifier.allCases.filter(modifiers.contains).map { glyph[$0]! }.joined()
        guard let key else { return "\(mods) (tap)" }
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥", "space": "Space", "return": "↩", "escape": "⎋", "delete": "⌫"]
        return mods + (names[key] ?? key.uppercased())
    }

    public var keyCode: Int? { key.flatMap { Self.keyCodes[$0] } }
    public var flags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers.contains(.ctrl) { f.insert(.maskControl) }
        if modifiers.contains(.alt) { f.insert(.maskAlternate) }
        if modifiers.contains(.shift) { f.insert(.maskShift) }
        if modifiers.contains(.cmd) { f.insert(.maskCommand) }
        return f
    }
    public var chord: KeyTap.Chord? { keyCode.map { KeyTap.Chord($0, flags) } }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let b = KeyBinding(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad key binding \(s)")) }
        self = b
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }

    public static let keyCodes: [String: Int] = {
        var t: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "tab": kVK_Tab, "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape, "delete": kVK_Delete,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in f.enumerated() { t["f\(i + 1)"] = code }
        return t
    }()
}

/// Every action pane can bind. The setting id is "keys.<rawValue>"; nil binding = off.
/// A keyboard shortcut pane binds (setting `keys.<rawValue>`). The engine's are below; pane Pro registers its own
/// (Task View, desktops, Quick Link) with `register` before the settings are read.
public struct Shortcut: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let title: String
    /// The binding pane uses when nothing is stored. The ⌘ arrows and ⌘ digits are nil (off) until the ⌘ = Win chord
    /// set is decided (PLAN.md: deferred decision); the keyboard presets (`ShortcutPresets`) offer complete sets.
    public let defaultBinding: KeyBinding?
    /// Rebinding is honoured by HotkeyService (the rest are reserved: stored, shown greyed out).
    public let isImplemented: Bool

    public init(_ rawValue: String, _ title: String, default binding: KeyBinding? = nil, implemented: Bool = true) {
        self.rawValue = rawValue; self.title = title; defaultBinding = binding; isImplemented = implemented
    }

    public init?(rawValue: String) {
        guard let found = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = found
    }

    public static func == (a: Shortcut, b: Shortcut) -> Bool { a.rawValue == b.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
    public var description: String { rawValue }

    public var setting: Setting<KeyBinding?> {
        Setting("keys.\(rawValue)", defaultBinding, .keyboard, title, kind: .shortcut, status: isImplemented ? .restart : .planned)
    }

    public static let start = Shortcut("start", "Open Start", default: .tap(.cmd))
    public static let menuMode = Shortcut("menuMode", "Menu mode (underlined letters)", default: .tap(.alt))
    public static let closeWindow = Shortcut("closeWindow", "Close window", default: KeyBinding([.alt], "f4"))
    public static let fullScreen = Shortcut("fullScreen", "Full screen", default: KeyBinding([.ctrl, .cmd], "f"))
    public static let snapLeft = Shortcut("snapLeft", "Snap left")
    public static let snapRight = Shortcut("snapRight", "Snap right")
    public static let maximize = Shortcut("maximize", "Maximize")
    public static let minimizeOrRestore = Shortcut("minimizeOrRestore", "Restore / minimize")
    public static let taskbarItem1 = item(1), taskbarItem2 = item(2), taskbarItem3 = item(3), taskbarItem4 = item(4), taskbarItem5 = item(5),
                      taskbarItem6 = item(6), taskbarItem7 = item(7), taskbarItem8 = item(8), taskbarItem9 = item(9)
    /// The switcher works on ⌥Tab, but its key isn't rebindable yet.
    public static let switcher = Shortcut("switcher", "Switch windows", default: KeyBinding([.alt], "tab"), implemented: false)
    public static let showDesktop = Shortcut("showDesktop", "Show desktop")
    public static let fileExplorer = Shortcut("fileExplorer", "Open a Finder window")
    public static let nextDisplay = Shortcut("nextDisplay", "Move window to next display", implemented: false)
    // Win+I (D5): ⌃⌘I here (⌘I is Italic / Get Info in Mac apps); the Windows keyboard uses ⌘I.
    public static let settings = Shortcut("settings", "Open pane Settings", default: KeyBinding([.ctrl, .cmd], "i"))

    private static func item(_ n: Int) -> Shortcut { Shortcut("taskbarItem\(n)", "Taskbar item \(n)") }
    public static let taskbarItems: [Shortcut] = [taskbarItem1, taskbarItem2, taskbarItem3, taskbarItem4, taskbarItem5,
                                                  taskbarItem6, taskbarItem7, taskbarItem8, taskbarItem9]

    static let engine: [Shortcut] = [start, menuMode, closeWindow, fullScreen, snapLeft, snapRight, maximize, minimizeOrRestore]
        + taskbarItems + [switcher, showDesktop, fileExplorer, nextDisplay, settings]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [Shortcut] = []

    /// The engine's shortcuts, then the registered ones.
    public static var allCases: [Shortcut] { engine + lock.withLock { registered } }

    /// pane Pro's shortcuts (at launch, before the settings are read). Their settings join the catalog.
    public static func register(_ shortcuts: [Shortcut]) {
        lock.withLock { registered += shortcuts.filter { s in !registered.contains(s) && !engine.contains(s) } }
        PaneSettings.register(shortcuts.map(\.setting.erased))
    }
}

/// Complete sets of shortcuts, by name. The engine has "mac" (only chords macOS doesn't use: snap on ⌃⌥ arrows,
/// Rectangle/Magnet's, next display ⌃⌥⌘←/→, no ⌘ digits); pane Pro adds its shortcuts to it and the "windows" set.
/// `SettingsStore.applyShortcutPreset` writes one.
public enum ShortcutPresets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var presets: [String: [Shortcut: KeyBinding?]] = {
        var mac: [Shortcut: KeyBinding?] = [:]
        mac[.snapLeft] = KeyBinding([.ctrl, .alt], "left"); mac[.snapRight] = KeyBinding([.ctrl, .alt], "right")
        mac[.maximize] = KeyBinding([.ctrl, .alt], "up"); mac[.minimizeOrRestore] = KeyBinding([.ctrl, .alt], "down")
        mac[.nextDisplay] = KeyBinding([.ctrl, .alt, .cmd], "right")
        for d in Shortcut.taskbarItems { mac[d] = .some(nil) }
        mac[.showDesktop] = .some(nil) // macOS has its own (F11)
        mac[.fileExplorer] = .some(nil)
        mac[.settings] = KeyBinding([.ctrl, .cmd], "i")
        return ["mac": mac]
    }()

    public static func bindings(_ name: String) -> [Shortcut: KeyBinding?] { lock.withLock { presets[name] ?? [:] } }

    /// Adds to (or makes) a preset.
    public static func register(_ name: String, _ bindings: [Shortcut: KeyBinding?]) {
        lock.withLock { presets[name, default: [:]].merge(bindings) { _, new in new } }
    }
}

/// A shortcut that collides with another pane binding or with a macOS/app shortcut people rely on.
public struct ShortcutConflict: Equatable, Sendable {
    public let shortcut: Shortcut
    public let binding: KeyBinding
    /// The other pane action, or nil when it collides with a system shortcut.
    public let other: Shortcut?
    public let systemMeaning: String?
}

public enum ShortcutConflicts {
    /// macOS and near-universal app shortcuts that a binding should not take (it would be swallowed everywhere).
    public static let system: [KeyBinding: String] = {
        var t: [KeyBinding: String] = [:]
        func add(_ m: Set<KeyBinding.Modifier>, _ k: String, _ meaning: String) { t[KeyBinding(m, k)] = meaning }
        add([.cmd], "q", "Quit app"); add([.cmd], "w", "Close window/tab"); add([.cmd], "tab", "macOS app switcher")
        add([.cmd], "space", "Spotlight"); add([.cmd], "c", "Copy"); add([.cmd], "v", "Paste"); add([.cmd], "x", "Cut")
        add([.cmd], "z", "Undo"); add([.cmd], "a", "Select all"); add([.cmd], "s", "Save"); add([.cmd], "f", "Find")
        add([.cmd], "h", "Hide app"); add([.cmd], "m", "Minimize (macOS)"); add([.cmd], "n", "New window"); add([.cmd], "t", "New tab")
        add([.cmd], "l", "Address bar"); add([.cmd], "e", "Use selection for find"); add([.cmd], "d", "Bookmark / duplicate")
        add([.cmd], "left", "Line start in text"); add([.cmd], "right", "Line end in text")
        add([.cmd], "up", "Document start in text"); add([.cmd], "down", "Document end in text")
        for d in 1...9 { add([.cmd], "\(d)", "Tab \(d) in browsers") }
        add([.cmd, .shift], "3", "Screenshot"); add([.cmd, .shift], "4", "Screenshot area"); add([.cmd, .shift], "5", "Screenshot tools")
        add([.ctrl], "up", "Mission Control"); add([.ctrl], "down", "App windows"); add([.ctrl], "left", "Previous Space")
        add([.ctrl], "right", "Next Space"); add([.ctrl, .cmd], "q", "Lock screen"); add([.alt, .cmd], "escape", "Force Quit")
        add([.ctrl, .cmd], "space", "Emoji & Symbols"); add([.ctrl], "space", "Input source")
        return t
    }()

    /// System-wide macOS shortcuts (not app shortcuts): they conflict in either keyboard. The rest of `system` are app
    /// and text shortcuts, which the Windows keyboard moves to Ctrl — so ⌘ is free there.
    public static let global: Set<KeyBinding> = {
        var t: Set<KeyBinding> = []
        func add(_ m: Set<KeyBinding.Modifier>, _ k: String) { t.insert(KeyBinding(m, k)) }
        add([.cmd], "space"); add([.cmd, .shift], "3"); add([.cmd, .shift], "4"); add([.cmd, .shift], "5")
        add([.ctrl], "up"); add([.ctrl], "down"); add([.ctrl], "left"); add([.ctrl], "right")
        add([.ctrl, .cmd], "q"); add([.alt, .cmd], "escape"); add([.ctrl, .cmd], "space"); add([.ctrl], "space")
        add([.cmd], "tab")
        return t
    }()

    /// The user's own macOS keyboard shortcuts that are on (System Settings ▸ Keyboard ▸ Keyboard Shortcuts; stored in
    /// `com.apple.symbolichotkeys`), with names for the common ones.
    public static func macOSShortcuts() -> [KeyBinding: String] {
        let names: [Int: String] = [
            7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to the window", 10: "Move focus to the toolbar",
            27: "Move focus to the next window", 32: "Mission Control", 33: "Application windows", 36: "Show desktop", 52: "Turn Dock hiding on/off",
            60: "Select the previous input source", 61: "Select the next input source", 64: "Show Spotlight search",
            65: "Show Finder search window", 79: "Move left a space", 81: "Move right a space", 118: "Switch to Desktop 1", 119: "Switch to Desktop 2",
            162: "Show Notification Center", 175: "Do Not Disturb", 184: "Screenshot and recording options",
        ]
        let reverse = Dictionary(KeyBinding.keyCodes.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return [:] }
        var result: [KeyBinding: String] = [:]
        for (key, entry) in all {
            guard let id = Int(key), let entry = entry as? [String: Any], (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int], parameters.count >= 3,
                  let name = reverse[parameters[1]] else { continue }
            let flags = parameters[2]
            var mods: Set<KeyBinding.Modifier> = []
            if flags & 0x40000 != 0 { mods.insert(.ctrl) }
            if flags & 0x80000 != 0 { mods.insert(.alt) }
            if flags & 0x20000 != 0 { mods.insert(.shift) }
            if flags & 0x100000 != 0 { mods.insert(.cmd) }
            result[KeyBinding(mods, name)] = names[id] ?? "macOS shortcut #\(id)"
        }
        return result
    }

    /// App and text shortcuts on ⌘ have moved to Ctrl (pane Pro's Windows keyboard): they don't conflict, and ⌘Tab is
    /// pane's (it switches macOS's off).
    @MainActor public static var appShortcutsOnCtrl: (SettingsStore) -> Bool = { _ in false }

    /// Every conflict among the bindings in effect (store values, defaults otherwise). Shortcuts that are off are skipped.
    @MainActor public static func check(_ store: SettingsStore, macOS: [KeyBinding: String]? = nil) -> [ShortcutConflict] {
        let windows = appShortcutsOnCtrl(store)
        let userShortcuts = macOS ?? macOSShortcuts()
        func systemMeaning(_ b: KeyBinding) -> String? {
            if windows && b == KeyBinding([.cmd], "tab") { return nil }
            if let meaning = system[b], !windows || global.contains(b) { return meaning }
            return userShortcuts[b].map { "macOS: \($0)" }
        }
        var seen: [KeyBinding: Shortcut] = [:]
        var result: [ShortcutConflict] = []
        for s in Shortcut.allCases {
            guard let b = store[s.setting] else { continue }
            if let other = seen[b] {
                // Both sides: a settings window shows the conflict next to each action.
                result.append(ShortcutConflict(shortcut: other, binding: b, other: s, systemMeaning: nil))
                result.append(ShortcutConflict(shortcut: s, binding: b, other: other, systemMeaning: nil))
            } else { seen[b] = s }
            if let meaning = systemMeaning(b) { result.append(ShortcutConflict(shortcut: s, binding: b, other: nil, systemMeaning: meaning)) }
        }
        return result
    }
}

// MARK: - The catalog

/// Every setting pane has, in display order per section (docs/research/settings-and-keys.md §3b: Windows-named panes). A
/// settings window renders `PaneSettings.settings(in:)`; `.planned` ones are reserved for features not built yet.
public enum PaneSettings {
    // General
    public static let launchAtLogin = Setting("general.launchAtLogin", false, .general, "Start pane at login", status: .live)
    public static let showMenuBarIcon = Setting("general.showMenuBarIcon", true, .general, "Show pane's icon in the menu bar",
        help: "Settings, Pause and Quit. Starting pane again also opens Settings. With the tray in the menu bar, its chevron is pane's icon (right-click it).", status: .live)
    /// The onboarding version the user finished (0: never). Onboarding shows when it's below `Onboarding.version`.
    public static let onboardingDone = Setting("general.onboardingDone", 0, .general, "Welcome finished (version)", status: .live, advanced: true)
    public static let paused = Setting("general.paused", false, .general, "Pause pane",
        help: "pane's shortcuts, snapping, click-through and quit-on-last-window stand down until resumed; the taskbar stays.", status: .live)
    public static let checkForUpdates = Setting("general.checkForUpdates", true, .general, "Check for updates automatically", status: .planned)
    public static let quitOnLastWindow = Setting("lifecycle.quitOnLastWindow", true, .general, "Quit apps when their last window closes",
        help: "Windows behaviour. Turn it off for an app to keep it running with no windows.", perApp: true, legacy: "quitOnLastWindow")
    // Start (Windows: Personalization ▸ Start)
    public static let startMenu = Setting("start.menu", "pane", .start, "Start opens",
        help: "pane's Start is Windows 11's; macOS Apps is the system's app grid.",
        kind: .choice([.init("pane", "pane's Start"), .init("apps", "macOS Apps")]), status: .live)
    public static let startSize = Setting("start.size", "automatic", .start, "Start size",
        help: "Automatic fits the screen: 8 pinned columns on large screens, 6 on small ones.",
        kind: .choice([.init("automatic", "Automatic"), .init("small", "Small"), .init("large", "Large")]), status: .live)
    public static let startShowPinned = Setting("start.showPinned", true, .start, "Show Pinned", status: .live)
    public static let startShowAllPins = Setting("start.showAllPins", false, .start, "Show all pins by default", status: .live)
    public static let startShowRecent = Setting("start.showRecent", true, .start, "Show Recent", status: .live)
    public static let startRecentlyAdded = Setting("start.recentlyAdded", true, .start, "Show recently added apps", status: .live)
    public static let startMostUsed = Setting("start.mostUsed", true, .start, "Show most used apps", status: .live)
    public static let startShowAll = Setting("start.showAll", true, .start, "Show All", status: .live)
    public static let startAllView = Setting("start.allView", "category", .start, "All apps view",
        kind: .choice([.init("category", "Category"), .init("grid", "Grid"), .init("list", "List")]), status: .live)
    public static let startHideAccount = Setting("start.hideAccount", false, .start, "Hide your name and picture", status: .live)
    public static let startFolders = Setting<[String]>("start.folders", ["settings", "finder"], .start, "Folders next to the power button",
        kind: .multiChoice(StartPlace.allCases.map { .init($0.rawValue, $0.title) }), status: .live)

    // Appearance (the look is the UI's; pane stores the choice)
    public static let theme = Setting("appearance.theme", "system", .appearance, "Theme",
        kind: .choice([.init("system", "Match macOS"), .init("light", "Light"), .init("dark", "Dark")]), status: .live)
    public static let material = Setting("appearance.material", "glass", .appearance, "Taskbar background",
        help: "Glass shows the wallpaper like the menu bar. Reduce Transparency always gets a solid background.",
        kind: .choice([.init("glass", "Glass (like the menu bar)"), .init("solid", "Solid")]), status: .live)

    // Taskbar
    public static let replaceDock = Setting("taskbar.replaceDock", true, .taskbar, "Replace the Dock", legacy: "replaceDock")
    public static let barHeight = Setting("taskbar.height", 48.0, .taskbar, "Taskbar height",
        kind: .number(min: 32, max: 72, step: 4, unit: "pt"), advanced: true, legacy: "barHeight")
    public static let alignment = Setting("taskbar.alignment", "center", .taskbar, "Taskbar alignment",
        kind: .choice([.init("center", "Center"), .init("left", "Left")]), status: .live)
    public static let combineButtons = Setting("taskbar.combineButtons", "always", .taskbar, "Combine taskbar buttons",
        kind: .choice([.init("always", "Always, hide labels"), .init("whenFull", "When taskbar is full"), .init("never", "Never")]), legacy: "combineButtons")
    public static let pinned = Setting<[String]?>("taskbar.pinned", nil, .taskbar, "Pinned apps",
        help: "The apps kept on the taskbar when they aren't running.", legacy: "pinned")
    public static let syncDockPins = Setting("taskbar.syncDockPins", false, .taskbar, "Sync pinned apps with the macOS Dock",
        help: "Pinning or unpinning in pane changes the Dock's apps too (the Dock restarts once), and the Dock's changes show in pane.",
        status: .live)
    public static let badges = Setting("taskbar.badges", true, .taskbar, "Show badges on taskbar apps", status: .live)
    public static let flashing = Setting("taskbar.flashing", true, .taskbar, "Show flashing on taskbar apps", status: .live)
    public static let farCornerShowsDesktop = Setting("taskbar.farCornerShowsDesktop", true, .taskbar, "Select the far corner to show the desktop", status: .live)
    public static let autoHide = Setting("taskbar.autoHide", false, .taskbar, "Automatically hide the taskbar",
        help: "Windows use the whole screen; the taskbar comes back when the pointer reaches the bottom edge.")
    public static let allDisplays = Setting("taskbar.allDisplays", true, .taskbar, "Show the taskbar on all displays", status: .planned)


    // Snap & windows
    public static let takeOverTiling = Setting("windows.takeOverTiling", true, .windows, "Snap windows the Windows way",
        help: "Replaces macOS tiling (edge drag, green button).", legacy: "takeOverTiling")
    public static let snap = Setting("windows.snap", true, .windows, "Snap this app's windows", status: .live, perApp: true)
    public static let clickThrough = Setting("windows.clickThrough", true, .windows, "First click on an inactive window also acts",
        legacy: "clickThrough")

    // Keyboard
    /// Per app: "never" | "always" | "fullScreen" — pane's shortcuts stand down while the app is in front.
    public static let ignoreShortcuts = Setting("apps.ignoreShortcuts", "never", .apps, "Ignore pane's shortcuts",
        kind: .choice([.init("never", "Never"), .init("always", "Always"), .init("fullScreen", "When full screen")]), perApp: true)

    // Alt+Tab
    public static let replaceCommandTab = Setting("switcher.replaceCommandTab", false, .switcher, "⌘⇥ opens pane's switcher too",
        help: "Hold ⌘ and press Tab to switch windows; macOS's app switcher is off while pane runs.")


    // Apps (exceptions): per-app rows of the perApp settings above
    public static let hideFromTaskbar = Setting("apps.hideFromTaskbar", false, .apps, "Hide from the taskbar, Alt+Tab and Task View", status: .live, perApp: true)

    // Advanced
    public static let debugLog = Setting("advanced.debugLog", false, .advanced, "Write a diagnostic log",
        help: "~/Library/Logs/Pane/pane.log", status: .live, advanced: true)

    /// Apps whose own keyboard handling must win (VMs, remote desktops): pane's shortcuts stand down while they're in
    /// front unless the user overrides it (AltTab and Karabiner ship the same list).
    /// Terminal apps: Ctrl+C must stay Ctrl+C there (the Windows keyboard never rewrites keys in them).
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "com.termius-dmg.mac",
    ]

    public static var builtInOverrides: [String: [String: JSONValue]] { registryLock.withLock { overrides } }

    static let engine: [AnySetting] = [
        launchAtLogin.erased, showMenuBarIcon.erased, onboardingDone.erased, paused.erased, checkForUpdates.erased, quitOnLastWindow.erased,
        startMenu.erased, startSize.erased, startShowPinned.erased, startShowAllPins.erased, startShowRecent.erased, startRecentlyAdded.erased,
        startMostUsed.erased, startShowAll.erased, startAllView.erased, startHideAccount.erased, startFolders.erased,
        theme.erased, material.erased,
        replaceDock.erased, barHeight.erased, alignment.erased, combineButtons.erased, pinned.erased, syncDockPins.erased, badges.erased, flashing.erased,
        farCornerShowsDesktop.erased, autoHide.erased, allDisplays.erased,
        takeOverTiling.erased, snap.erased, clickThrough.erased,
        ignoreShortcuts.erased, replaceCommandTab.erased,
        hideFromTaskbar.erased, debugLog.erased,
    ] + Shortcut.engine.map(\.setting.erased)

    // The catalog: the engine's settings, then pane Pro's (`register`, at launch before the settings are read).
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var catalog: [AnySetting] = engine
    nonisolated(unsafe) private static var byID: [String: AnySetting] = Dictionary(engine.map { ($0.id, $0) }) { a, _ in a }
    nonisolated(unsafe) private static var depends: [String: (id: String, value: JSONValue)] = [
        syncDockPins.id: (replaceDock.id, .bool(true)), autoHide.id: (replaceDock.id, .bool(true)),
        startShowAllPins.id: (startShowPinned.id, .bool(true)), startRecentlyAdded.id: (startShowRecent.id, .bool(true)),
        startMostUsed.id: (startShowRecent.id, .bool(true)), startAllView.id: (startShowAll.id, .bool(true)),
    ]
    nonisolated(unsafe) private static var words: [String: [String]] = [
        Shortcut.start.setting.id: ["win key", "start menu"], Shortcut.settings.setting.id: ["win+i"],
        alignment.id: ["center", "left"], combineButtons.id: ["group", "labels"], autoHide.id: ["hide taskbar"],
        replaceCommandTab.id: ["alt tab", "app switcher"], quitOnLastWindow.id: ["close", "quit"], launchAtLogin.id: ["startup", "login items"],
    ]
    /// VMs and remote desktops: their own keyboard handling must win.
    public static let virtualMachines: Set<String> = [
        "com.parallels.desktop.console", "com.vmware.fusion", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.utmapp.UTM",
        "org.virtualbox.app.VirtualBox", "com.citrix.receiver.icaviewer.mac", "com.teamviewer.TeamViewer", "com.realvnc.vncviewer",
    ]
    nonisolated(unsafe) private static var overrides: [String: [String: JSONValue]] =
        Dictionary(uniqueKeysWithValues: virtualMachines.map { ($0, [ignoreShortcuts.id: JSONValue.string("always")]) })

    /// v1 config keys that listed apps (→ the per-app setting and value they meant).
    nonisolated(unsafe) private static var appLists: [String: (id: String, value: JSONValue)] = ["optOut": (quitOnLastWindow.id, .bool(false))]
    public static var legacyAppLists: [String: (id: String, value: JSONValue)] { registryLock.withLock { appLists } }

    /// Every setting: the engine's, then registered ones.
    public static var all: [AnySetting] { registryLock.withLock { catalog } }

    public static func setting(id: String) -> AnySetting? { registryLock.withLock { byID[id] } }

    /// Settings that only matter while another one is on (a settings window disables them otherwise).
    public static var dependsOn: [String: (id: String, value: JSONValue)] { registryLock.withLock { depends } }

    /// Extra words a settings search should match (the Windows names people know).
    public static var keywords: [String: [String]] { registryLock.withLock { words } }

    /// Adds settings to the catalog (pane Pro, at launch), with what they depend on, search words and built-in
    /// per-app values (bundle → setting → value).
    public static func register(_ settings: [AnySetting], dependsOn: [String: (id: String, value: JSONValue)] = [:],
                                keywords: [String: [String]] = [:], builtInOverrides: [String: [String: JSONValue]] = [:],
                                legacyAppLists: [String: (id: String, value: JSONValue)] = [:]) {
        registryLock.withLock {
            for setting in settings where byID[setting.id] == nil {
                catalog.append(setting)
                byID[setting.id] = setting
            }
            depends.merge(dependsOn) { _, new in new }
            words.merge(keywords) { a, b in a + b }
            for (bundle, values) in builtInOverrides { overrides[bundle, default: [:]].merge(values) { _, new in new } }
            appLists.merge(legacyAppLists) { _, new in new }
        }
    }

    /// Search over titles, help, section names and keywords (case-insensitive).
    public static func search(_ query: String, includePlanned: Bool = false) -> [AnySetting] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return all.filter { s in
            (includePlanned || s.info.status != .planned) &&
            ([s.info.title, s.info.help, s.info.section.rawValue] + (keywords[s.id] ?? [])).contains { $0.lowercased().contains(q) }
        }
    }
    public static func settings(in section: SettingSection, includePlanned: Bool = false) -> [AnySetting] {
        all.filter { $0.info.section == section && (includePlanned || $0.info.status != .planned) }
    }
}

// MARK: - The store

public enum SettingsError: Error, Equatable {
    case invalid(id: String)
    case notPerApp(id: String)
    case unreadable(String)
}

/// Cancels its observation when cancelled or released.
public final class SettingsObservation {
    private var cancelHandler: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelHandler = cancel }
    public func cancel() { cancelHandler?(); cancelHandler = nil }
    deinit { cancelHandler?() }
}

@MainActor
public final class SettingsStore {
    nonisolated public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pane/config.json")

    public let url: URL?
    private var values: [String: JSONValue] = [:]
    private var apps: [String: [String: JSONValue]] = [:]
    /// Keys in the file that no setting knows (kept on save, so a newer pane's settings survive an older one).
    private var unknown: [String: JSONValue] = [:]
    /// Problems found while reading (bad values are ignored, the default applies).
    public private(set) var issues: [String] = []
    private var observers: [String: [UUID: () -> Void]] = [:]
    private var anyObservers: [UUID: (String) -> Void] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var lastWritten: Data?

    /// `url: nil` = in memory only (tests, previews).
    public init(url: URL? = SettingsStore.defaultURL) {
        self.url = url
        reload(notify: false)
    }

    // Reading

    public subscript<V>(_ s: Setting<V>) -> V {
        get { value(s) }
        set { try? set(s, newValue) }
    }

    public func value<V>(_ s: Setting<V>) -> V {
        if let locked = locks[s.id], let v = locked.decode(V.self) { return v }
        return values[s.id].flatMap { $0.decode(V.self) } ?? s.defaultValue
    }

    /// The value for one app: its override if it has one (yours, then pane's built-in ones), else the global value.
    public func value<V>(_ s: Setting<V>, for bundleID: String) -> V {
        userApps[bundleID]?[s.id].flatMap { $0.decode(V.self) }
            ?? PaneSettings.builtInOverrides[bundleID]?[s.id].flatMap { $0.decode(V.self) }
            ?? value(s)
    }

    /// Every app (your overrides and pane's built-in ones) whose value of a per-app setting passes `test`.
    public func apps<V>(_ s: Setting<V>, where test: (V) -> Bool) -> Set<String> {
        var bundles = Set(PaneSettings.builtInOverrides.keys).union(userApps.keys)
        bundles = bundles.filter { userApps[$0]?[s.id] != nil || PaneSettings.builtInOverrides[$0]?[s.id] != nil }
        return bundles.filter { test(value(s, for: $0)) }
    }

    // Locks (pane Pro's editions): a locked setting reads as a fixed value; your stored
    // choice stays. The Free build never locks anything.

    /// Locked settings → the value they read as.
    public private(set) var locks: [String: JSONValue] = [:]
    /// Your own per-app overrides are ignored (pane's built-in ones still apply).
    public private(set) var userOverridesLocked = false

    public func isLocked(id: String) -> Bool { locks[id] != nil }

    /// Replaces the locks; observers hear every setting whose value in effect changed.
    public func setLocks(_ new: [String: JSONValue], userOverrides: Bool) {
        let affected = Set(locks.keys).union(new.keys)
        let perApp: Set<String> = userOverrides != userOverridesLocked ? Set(apps.values.flatMap(\.keys)) : []
        let before = Dictionary(uniqueKeysWithValues: affected.map { ($0, effective($0)) })
        locks = new
        userOverridesLocked = userOverrides
        for id in affected.union(perApp) where perApp.contains(id) || before[id] != effective(id) { notify(id) }
    }

    private func effective(_ id: String) -> JSONValue? { locks[id] ?? values[id] }

    /// Your per-app overrides as they apply now (none while they're locked).
    private var userApps: [String: [String: JSONValue]] { userOverridesLocked ? [:] : apps }

    /// Writes a set of shortcuts (`ShortcutPresets`; other bindings you set are kept).
    public func applyShortcutPreset(_ name: String) {
        for (action, binding) in ShortcutPresets.bindings(name) { try? set(action.setting, binding) }
    }

    public func isDefault<V>(_ s: Setting<V>) -> Bool { values[s.id] == nil }

    // Writing

    public func set<V>(_ s: Setting<V>, _ newValue: V) throws {
        guard Setting<V>.valid(newValue, s.info.kind), let json = JSONValue.from(newValue) else { throw SettingsError.invalid(id: s.id) }
        let stored: JSONValue? = newValue == s.defaultValue ? nil : json
        guard values[s.id] != stored else { return }
        values[s.id] = stored
        save()
        notify(s.id)
    }

    public func reset<V>(_ s: Setting<V>) {
        guard values.removeValue(forKey: s.id) != nil else { return }
        save()
        notify(s.id)
    }

    /// Every setting back to its default (per-app overrides too unless `keepApps`).
    public func resetAll(keepApps: Bool = false) {
        let changed = Set(values.keys).union(keepApps ? [] : apps.values.flatMap(\.keys))
        values = [:]
        if !keepApps { apps = [:] }
        save()
        changed.forEach(notify)
    }

    public func setOverride<V>(_ s: Setting<V>, _ newValue: V?, for bundleID: String) throws {
        guard s.info.perApp else { throw SettingsError.notPerApp(id: s.id) }
        if let newValue {
            guard Setting<V>.valid(newValue, s.info.kind), let json = JSONValue.from(newValue) else { throw SettingsError.invalid(id: s.id) }
            apps[bundleID, default: [:]][s.id] = json
        } else {
            apps[bundleID]?[s.id] = nil
            if apps[bundleID]?.isEmpty == true { apps[bundleID] = nil }
        }
        save()
        notify(s.id)
    }

    /// Apps with an override for this setting, and their values.
    public func overrides<V>(_ s: Setting<V>) -> [String: V] {
        var result: [String: V] = [:]
        for (bundle, settings) in userApps { if let v = settings[s.id]?.decode(V.self) { result[bundle] = v } }
        return result
    }

    // By id (a settings window renders `PaneSettings.all`, which knows settings only by id)

    /// The value in effect (stored, else the default).
    public func json(_ id: String) -> JSONValue? {
        guard let s = PaneSettings.setting(id: id) else { return nil }
        return locks[id] ?? values[id] ?? s.defaultJSON
    }

    /// What you chose, even while it's locked (the Settings window shows it under a badge).
    public func storedJSON(_ id: String) -> JSONValue? {
        guard let s = PaneSettings.setting(id: id) else { return nil }
        return values[id] ?? s.defaultJSON
    }

    /// One app's value: its own override, else pane's built-in one, else the global value.
    public func json(_ id: String, for bundleID: String) -> JSONValue? {
        userApps[bundleID]?[id] ?? PaneSettings.builtInOverrides[bundleID]?[id] ?? json(id)
    }

    public func isDefault(id: String) -> Bool { values[id] == nil }

    public func set(id: String, json value: JSONValue) throws {
        guard let s = PaneSettings.setting(id: id), s.accepts(value) else { throw SettingsError.invalid(id: id) }
        let stored: JSONValue? = value == s.defaultJSON ? nil : value
        guard values[id] != stored else { return }
        values[id] = stored
        save()
        notify(id)
    }

    public func reset(id: String) {
        guard values.removeValue(forKey: id) != nil else { return }
        save()
        notify(id)
    }

    /// nil removes this app's override (pane's built-in one, if any, applies again).
    public func setOverride(id: String, json value: JSONValue?, for bundleID: String) throws {
        guard let s = PaneSettings.setting(id: id) else { throw SettingsError.invalid(id: id) }
        guard s.info.perApp else { throw SettingsError.notPerApp(id: id) }
        if let value {
            guard s.accepts(value) else { throw SettingsError.invalid(id: id) }
            apps[bundleID, default: [:]][id] = value
        } else {
            apps[bundleID]?[id] = nil
            if apps[bundleID]?.isEmpty == true { apps[bundleID] = nil }
        }
        save()
        notify(id)
    }

    /// Every app with an override: yours, then pane's built-in ones (VMs, remote desktops, terminals), sorted.
    public func appsWithOverrides() -> [String] {
        Array(Set(apps.keys).union(PaneSettings.builtInOverrides.keys)).sorted()
    }

    /// The overrides you set for an app (not the built-in ones).
    public func overrides(for bundleID: String) -> [String: JSONValue] { apps[bundleID] ?? [:] }

    /// Removes every override you set for an app (the built-in ones stay).
    public func removeOverrides(for bundleID: String) {
        guard let removed = apps.removeValue(forKey: bundleID) else { return }
        save()
        removed.keys.forEach(notify)
    }

    // Observing

    /// Called (main actor) after this setting changes, including edits to the file by hand.
    public func observe<V>(_ s: Setting<V>, _ handler: @escaping (V) -> Void) -> SettingsObservation {
        let token = UUID()
        observers[s.id, default: [:]][token] = { [weak self] in if let self { handler(self.value(s)) } }
        return SettingsObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.observers[s.id]?.removeValue(forKey: token) }
        }
    }

    /// Called with the id of every setting that changes.
    public func observeAll(_ handler: @escaping (String) -> Void) -> SettingsObservation {
        let token = UUID()
        anyObservers[token] = handler
        return SettingsObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.anyObservers.removeValue(forKey: token) }
        }
    }

    private func notify(_ id: String) {
        observers[id]?.values.forEach { $0() }
        anyObservers.values.forEach { $0(id) }
    }

    // Import / export

    /// The file's JSON (version 2), with every non-default value and override.
    public func exportData() -> Data {
        var settings = unknown
        for (k, v) in values { settings[k] = v }
        var root: [String: JSONValue] = ["version": .number(2), "settings": .object(settings)]
        if !apps.isEmpty { root["apps"] = .object(apps.mapValues { .object($0) }) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(JSONValue.object(root))) ?? Data()
    }

    /// Replaces everything with an exported file (v1 or v2). Returns the problems found (bad values are skipped).
    @discardableResult
    public func importData(_ data: Data) throws -> [String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = root else {
            throw SettingsError.unreadable("not a settings file")
        }
        let before = snapshot()
        apply(root)
        save()
        changedIDs(from: before).forEach(notify)
        return issues
    }

    // File

    /// Re-reads the file (also called by the file watcher). Observers hear about what changed.
    public func reload(notify shouldNotify: Bool = true) {
        let before = snapshot()
        values = [:]; apps = [:]; unknown = [:]; issues = []
        if let url, let data = try? Data(contentsOf: url) {
            if let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = root { apply(root) }
            else { issues.append("config.json is not valid JSON; using defaults") }
        }
        if shouldNotify { changedIDs(from: before).forEach(notify) }
    }

    /// Applies edits made to the file by hand (or by a settings app writing it) while pane runs.
    public func watchFile() {
        guard watcher == nil, let url else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let url = self.url else { return }
                let data = try? Data(contentsOf: url)
                if data != nil, data == self.lastWritten { return } // our own save
                self.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    public func stopWatching() { watcher?.cancel(); watcher = nil }

    private func save() {
        guard let url else { return }
        let data = exportData()
        lastWritten = data
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func snapshot() -> [String: JSONValue] {
        var s = values
        for (bundle, settings) in apps { for (k, v) in settings { s["\(bundle)|\(k)"] = v } }
        return s
    }

    private func changedIDs(from before: [String: JSONValue]) -> Set<String> {
        let after = snapshot()
        let keys = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        return Set(keys.map { $0.split(separator: "|").last.map(String.init) ?? $0 })
    }

    /// Reads a v2 root, or a v1 flat file (migrated in memory).
    private func apply(_ root: JSONValue) {
        guard case .object(let object) = root else { return }
        values = [:]; apps = [:]; unknown = [:]; issues = []
        if case .number(let version)? = object["version"], version >= 2 {
            if case .object(let settings)? = object["settings"] { for (k, v) in settings { store(k, v, into: &values, keepUnknown: true) } }
            if case .object(let perApp)? = object["apps"] {
                for (bundle, entry) in perApp {
                    guard case .object(let settings) = entry else { continue }
                    var appValues: [String: JSONValue] = [:]
                    for (k, v) in settings {
                        guard let s = PaneSettings.setting(id: k), s.info.perApp else { issues.append("\(bundle): \(k) can't be set per app"); continue }
                        store(k, v, into: &appValues, keepUnknown: false)
                    }
                    if !appValues.isEmpty { apps[bundle] = appValues }
                }
            }
            return
        }
        // v1: flat keys named after the old Config fields.
        for (key, v) in object {
            switch key {
            case _ where PaneSettings.legacyAppLists[key] != nil:
                let (id, value) = PaneSettings.legacyAppLists[key]!
                for b in v.decode([String].self) ?? [] { apps[b, default: [:]][id] = value }
            default:
                if let s = PaneSettings.all.first(where: { $0.info.legacyKey == key }) { store(s.id, v, into: &values, keepUnknown: false) }
                else { issues.append("unknown v1 key \(key) ignored") }
            }
        }
    }

    private func store(_ id: String, _ value: JSONValue, into target: inout [String: JSONValue], keepUnknown: Bool) {
        guard let s = PaneSettings.setting(id: id) else {
            if keepUnknown { unknown[id] = value }
            return
        }
        guard s.accepts(value) else { issues.append("\(id): invalid value, default used"); return }
        if value != s.defaultJSON { target[id] = value }
    }
}

/// A full backup (E12): config.json's settings plus named sections, each from the part of pane that owns it (Start's
/// layout from the engine; the tray's from pane Pro). A settings file without sections imports as before.
public struct BackupSection {
    public let key: String
    public let export: () -> JSONValue?
    /// Restores from the section's JSON; false when it isn't readable (it's skipped).
    public let restore: (JSONValue) -> Bool
    public init(key: String, export: @escaping () -> JSONValue?, restore: @escaping (JSONValue) -> Bool) {
        self.key = key; self.export = export; self.restore = restore
    }
}

public enum PaneBackup {
    @MainActor public static func exportData(_ store: SettingsStore, sections: [BackupSection]) -> Data {
        guard case .object(var root)? = try? JSONDecoder().decode(JSONValue.self, from: store.exportData()) else { return store.exportData() }
        for section in sections { if let value = section.export() { root[section.key] = value } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(JSONValue.object(root))) ?? store.exportData()
    }

    /// Imports the settings and every section found. Returns the problems.
    @MainActor @discardableResult
    public static func importData(_ data: Data, store: SettingsStore, sections: [BackupSection]) throws -> [String] {
        guard case .object(var root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw SettingsError.unreadable("not a settings file")
        }
        var problems: [String] = []
        for section in sections {
            guard let value = root.removeValue(forKey: section.key) else { continue }
            if !section.restore(value) { problems.append("\(section.key): not readable; skipped") }
        }
        return problems + (try store.importData(JSONEncoder().encode(JSONValue.object(root))))
    }
}

/// JSON ⇄ Codable through JSONValue (for backup sections).
public extension JSONValue {
    static func encoding<T: Encodable>(_ value: T) -> JSONValue? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
    func decoding<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
