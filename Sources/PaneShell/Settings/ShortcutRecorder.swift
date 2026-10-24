// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

/// pane's shortcut recorder: click (or AXPress) it, type a chord. While it records, pane's own keys stand down
/// (`ShortcutRecording`, E8) so ⌥Tab or ⌃⌥← can be typed instead of acting. A chord needs a modifier (F-keys excepted);
/// a lone modifier pressed and released records a tap where the action allows one (Start, menu mode). Escape or a
/// click elsewhere cancels.
final class ShortcutRecorderButton: NSButton {
    var binding: KeyBinding? { didSet { updateTitle() } }
    var allowsTap = false
    var onRecord: ((KeyBinding) -> Void)?
    private(set) var isRecording = false { didSet { updateTitle() } }
    private var pendingTap: KeyBinding.Modifier?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    @objc private func clicked() {
        if isRecording { window?.makeFirstResponder(nil) } else { window?.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true
        pendingTap = nil
        ShortcutRecording.begin()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            ShortcutRecording.end()
        }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isRecording { isRecording = false; ShortcutRecording.end() }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<KeyBinding.Modifier> {
        var m: Set<KeyBinding.Modifier> = []
        if flags.contains(.control) { m.insert(.ctrl) }
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.cmd) }
        return m
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        pendingTap = nil
        let mods = Self.modifiers(event.modifierFlags)
        guard let name = KeyBinding.keyCodes.first(where: { $0.value == Int(event.keyCode) })?.key else { NSSound.beep(); return }
        if name == "escape" && mods.isEmpty { window?.makeFirstResponder(nil); return }
        let isFunctionKey = name.count > 1 && name.hasPrefix("f") && Int(name.dropFirst()) != nil
        if mods.isEmpty && !isFunctionKey { NSSound.beep(); return }
        record(KeyBinding(mods, name))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let mods = Self.modifiers(event.modifierFlags)
        if mods.count == 1, pendingTap == nil { pendingTap = mods.first }
        else if mods.isEmpty, let tap = pendingTap {
            pendingTap = nil
            if allowsTap { record(.tap(tap)) }
        } else if mods.count > 1 { pendingTap = nil }
    }

    private func record(_ b: KeyBinding) {
        binding = b
        onRecord?(b)
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = isRecording ? "Type a shortcut…" : (binding?.display ?? "Off")
        setAccessibilityValue(isRecording ? "recording" : (binding?.text ?? "off"))
    }
}

struct RecorderView: NSViewRepresentable {
    let binding: KeyBinding?
    let allowsTap: Bool
    let label: String
    let identifier: String
    let onRecord: (KeyBinding) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton(frame: .zero) }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        if !view.isRecording { view.binding = binding }
        view.allowsTap = allowsTap
        view.onRecord = onRecord
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
    }
}

/// A `keys.<action>` row: the recorder, Off (×), reset, and any conflict under the title.
struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let info: SettingInfo

    var body: some View {
        let binding = model.store.json(id).flatMap(\.stringValue).flatMap(KeyBinding.init)
        let action = Shortcut.allCases.first { $0.setting.id == id }
        let conflicts = model.conflicts(for: id).map { c in
            c.other.map { "Also used by “\($0.title)”" } ?? "Conflicts with \(c.systemMeaning ?? "a macOS shortcut")"
        }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                RowLabel(info: info)
                if !conflicts.isEmpty {
                    Label(conflicts.joined(separator: "; "), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("\(id).conflict")
                }
            }
            Spacer()
            RecorderView(binding: binding, allowsTap: action == .start || action == .menuMode,
                         label: "Shortcut for \(info.title)", identifier: "\(id).recorder") { recorded in
                try? model.store.set(id: id, json: .string(recorded.text))
            }
            .frame(width: 150, height: 24)
            Button { try? model.store.set(id: id, json: .null) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .disabled(binding == nil)
                .help("Turn this shortcut off")
                .accessibilityLabel("Turn off \(info.title)")
                .accessibilityIdentifier("\(id).clear")
            Button { model.store.reset(id: id) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .opacity(model.store.isDefault(id: id) ? 0 : 1)
                .disabled(model.store.isDefault(id: id))
                .help("Reset to default")
                .accessibilityLabel("Reset \(info.title) to default")
                .accessibilityIdentifier("\(id).reset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}
