// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox

/// An active keyboard tap for Windows-style chords (Win+Arrow, Alt+F4) and lone-modifier taps (Alt → menu,
/// Win → Start). Matching chords are swallowed so the frontmost app never sees them. Runs on its own thread;
/// handlers are called there.
///
/// Carbon `RegisterEventHotKey` is the public alternative for chords (no Accessibility needed, but it can't
/// see a lone modifier and can't override shortcuts the system has already claimed).
public final class KeyTap {
    /// Keys the Windows keyboard (pane Pro) rewrote carry this in `eventSourceUserData`: pane's own shortcuts let them through.
    public static let remappedTag: Int64 = 0x7061_6E65_6B65_79 // "panekey"

    public struct Chord: Hashable {
        public let keyCode: Int64
        public let modifiers: CGEventFlags.RawValue

        public init(_ keyCode: Int, _ modifiers: CGEventFlags) {
            self.keyCode = Int64(keyCode)
            self.modifiers = modifiers.rawValue & KeyTap.modifierMask
        }
    }

    public enum Modifier: CaseIterable { case option, command, control }

    static let modifierMask: CGEventFlags.RawValue =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    private let lock = NSLock()
    private var chords: [Chord: () -> Void] = [:]
    public var onModifierTap: ((Modifier) -> Void)?
    /// Sees every keyDown before chord matching; return true to swallow it (modal UIs like the switcher).
    public var interceptor: ((_ keyCode: Int64, _ flags: CGEventFlags) -> Bool)?
    /// Every modifier change (e.g. to notice ⌥ being released).
    public var onFlagsChanged: ((CGEventFlags) -> Void)?
    /// True while pane's chords must stand down (an app whose own keys win is in front: VMs, remote desktops — the
    /// per-app setting `apps.ignoreShortcuts`). Called per key event: keep it cheap.
    public var isSuppressed: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// The modifier currently held alone (nil once any other key or modifier joins in).
    private var loneModifier: Modifier?

    public init() throws {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            }
            self.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap = self.tap {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if self.tap != nil { CFRunLoopRun() }
        }
        thread.name = "pane.KeyTap"
        thread.start()
        ready.wait()
        if tap == nil { throw MouseTapError.tapRefused }
    }

    deinit { stop() }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    public func bind(_ chord: Chord, _ action: @escaping () -> Void) {
        lock.withLock { chords[chord] = action }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            TapDiagnostics.disabled("KeyTap", type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case _ where Pause.isOn || ShortcutRecording.isOn:
            loneModifier = nil // paused: every key goes to the apps untouched
        case .keyDown:
            loneModifier = nil
            // Keys the Windows mode rewrote (Ctrl+D → ⌘D) are the app's, never pane's chords; nor anything in an
            // app that ignores pane's shortcuts.
            if event.getIntegerValueField(.eventSourceUserData) == KeyTap.remappedTag || isSuppressed?() == true { break }
            if let interceptor, interceptor(event.getIntegerValueField(.keyboardEventKeycode), event.flags) { return nil }
            let chord = Chord(Int(event.getIntegerValueField(.keyboardEventKeycode)), event.flags)
            if let action = lock.withLock({ chords[chord] }) {
                action()
                return nil
            }
        case .flagsChanged:
            onFlagsChanged?(event.flags)
            if isSuppressed?() == true { loneModifier = nil; break }
            let flags = event.flags.rawValue & Self.modifierMask
            let held: Modifier? = switch flags {
            case CGEventFlags.maskAlternate.rawValue: .option
            case CGEventFlags.maskCommand.rawValue: .command
            case CGEventFlags.maskControl.rawValue: .control
            default: nil
            }
            if flags == 0, let lone = loneModifier {
                loneModifier = nil
                onModifierTap?(lone)
            } else {
                loneModifier = (loneModifier == nil && held != nil) ? held : (held == loneModifier ? held : nil)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

/// macOS disables an event tap whose callback is too slow; events pass untouched meanwhile. Logged so a long run
/// can line these up with odd input effects.
public enum TapDiagnostics {
    nonisolated(unsafe) public static var count = 0
    public static func disabled(_ tap: String, _ type: CGEventType) {
        count += 1
        PaneLog.write("\(tap) disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled; total \(count)")
    }
}

public enum SyntheticKeyboard {
    /// A chord typed the way a person does: modifier keys down, the key, modifier keys up — all from the
    /// HID-state source so the system's modifier state ends where it started. (Posting a key event that
    /// merely carries modifier flags sets those flags system-wide, from any source, and leaves them held.)
    /// Presses made while macOS Secure Input was on (a password field somewhere): event taps don't see those keys.
    /// Test diagnostics for keyboard tests that fail only in full runs.
    nonisolated(unsafe) public static var pressesDuringSecureInput = 0
    public static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    public static func press(_ keyCode: Int, _ modifiers: CGEventFlags = []) {
        if IsSecureEventInputEnabled() { pressesDuringSecureInput += 1 }
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(CGEventFlags, Int)] = [(.maskControl, kVK_Control), (.maskAlternate, kVK_Option),
                                                   (.maskCommand, kVK_Command), (.maskShift, kVK_Shift)]
        let held = modifierKeys.filter { modifiers.contains($0.0) }.map(\.1)
        for key in held { CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)?.post(tap: .cghidEventTap); usleep(10_000) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            event?.flags = modifiers
            event?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        for key in held.reversed() { CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)?.post(tap: .cghidEventTap); usleep(10_000) }
    }

    /// Hold modifiers down (HID state) until `releaseModifiers` — for switcher-style "hold ⌥, tap Tab".
    public static func holdModifiers(_ modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for (flag, key) in [(CGEventFlags.maskControl, kVK_Control), (.maskAlternate, kVK_Option), (.maskCommand, kVK_Command), (.maskShift, kVK_Shift)]
        where modifiers.contains(flag) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    public static func releaseModifiers(_ modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for (flag, key) in [(CGEventFlags.maskShift, kVK_Shift), (.maskCommand, kVK_Command), (.maskAlternate, kVK_Option), (.maskControl, kVK_Control)]
        where modifiers.contains(flag) {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    /// A key while modifiers are held via `holdModifiers` (no modifier down/up of its own).
    public static func tapKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// Press and release a modifier on its own. Uses real key down/up events from the HID-state source so
    /// the system's modifier state goes down AND back up. (Rewriting a key event's type to flagsChanged
    /// left Option logically held system-wide — every later click became an Option-click.)
    public static func tap(_ modifier: KeyTap.Modifier) {
        let key: Int = switch modifier {
        case .option: kVK_Option
        case .command: kVK_Command
        case .control: kVK_Control
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    /// Modifiers the system currently believes are held.
    public static var heldModifiers: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
    }

    /// Safety net after synthesizing input: key-up for every modifier key.
    public static func releaseAllModifiers() {
        let source = CGEventSource(stateID: .hidSystemState)
        for key in [kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand, kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }
}
