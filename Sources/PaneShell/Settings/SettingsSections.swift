// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaneKit

// Page content beyond plain settings rows: permissions, the shortcut presets, Advanced, About.

// MARK: - General

struct PermissionsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let accessibility = Permissions.shared.accessibility
        let previews = Permissions.shared.previews
        Section("Permissions") {
            LabeledContent {
                if accessibility == .granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow…") { Permissions.shared.requestAccessibility() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text("Required: pane moves, snaps and switches windows with it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.permission.accessibility")
            .accessibilityValue(accessibility.rawValue)
            LabeledContent {
                if previews == .granted {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Off: window lists show app icons").font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window previews")
                    Text("Optional: window thumbnails.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.permission.previews")
            .accessibilityValue(previews.rawValue)
        }
    }
}

// MARK: - Keyboard

/// Under the shortcut groups: put a preset back.
struct KeymapSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            HStack {
                ForEach(model.shortcutPresets, id: \.id) { preset in
                    Button(preset.title, action: preset.apply).accessibilityIdentifier(preset.id)
                }
                Spacer()
                let count = Set(model.conflicts.map(\.shortcut)).count
                if count > 0 {
                    Label(count == 1 ? "1 shortcut conflicts" : "\(count) shortcuts conflict", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                        .accessibilityIdentifier("settings.keys.conflictCount")
                }
            }
        } footer: {
            Text("Shortcuts take effect after pane restarts.")
        }
    }
}

// MARK: - Advanced

struct AdvancedActionsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Backup") {
            HStack {
                Button("Export settings…") { later(export) }.accessibilityIdentifier("settings.export")
                Button("Import settings…") { later(importSettings) }.accessibilityIdentifier("settings.import")
            }
        }
        Section {
            HStack {
                Button("Reset all settings…", role: .destructive) { later(resetAll) }.accessibilityIdentifier("settings.resetAll")
                Button("Restore macOS settings now…") { later(restoreNow) }.accessibilityIdentifier("settings.restoreNow")
                Button("Show welcome again") {
                    model.store.reset(id: PaneSettings.onboardingDone.id)
                    model.onShowWelcome?()
                }
                .accessibilityIdentifier("settings.showWelcome")
            }
        } header: {
            Text("Reset")
        } footer: {
            Text(SystemChanges.promise)
        }
        if !model.store.issues.isEmpty {
            Section("Problems in config.json") {
                ForEach(model.store.issues, id: \.self) { Text($0).font(.caption) }
            }
            .accessibilityIdentifier("settings.issues")
        }
    }

    /// Panels and alerts run after the button's action returns (a click, or AXPress, doesn't wait on the modal loop).
    private func later(_ action: @escaping () -> Void) { DispatchQueue.main.async { action() } }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pane-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = PaneBackup.exportData(model.store, sections: model.backupSections)
        do { try data.write(to: url, options: .atomic); model.notice = "Settings exported to \(url.lastPathComponent)." }
        catch { model.notice = "Couldn't export: \(error.localizedDescription)" }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let alert = NSAlert()
        alert.messageText = "Replace all of pane's settings?"
        alert.informativeText = "Your current settings and app exceptions are replaced by the ones in \(url.lastPathComponent)."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let problems = try PaneBackup.importData(data, store: model.store, sections: model.backupSections)
            model.onImported?()
            model.notice = problems.isEmpty ? "Settings imported." : "Settings imported. Skipped: " + problems.joined(separator: "; ")
        } catch {
            model.notice = "Couldn't import: that file isn't a pane settings file."
        }
    }

    private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all of pane's settings?"
        alert.informativeText = "Every setting goes back to its default."
        alert.alertStyle = .warning
        let keep = NSButton(checkboxWithTitle: "Keep app exceptions", target: nil, action: nil)
        keep.state = .on
        alert.accessoryView = keep
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.store.resetAll(keepApps: keep.state == .on)
        model.notice = "Settings reset."
    }

    private func restoreNow() {
        let changes = SystemChanges.describe(model.store)
        guard !changes.isEmpty else { model.notice = "pane isn't changing any macOS settings."; return }
        let alert = NSAlert()
        alert.messageText = "Turn off everything pane changes in macOS?"
        alert.informativeText = changes.map { "• \($0.title)" }.joined(separator: "\n") + "\n\nThe Dock and window tiling come back when pane restarts."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try SystemChanges.restoreAll(model.store) } catch { model.notice = "Couldn't change a setting: \(error)" }
    }
}

// MARK: - About

struct AboutSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        Section {
            HStack(spacing: 14) {
                Image(systemName: "square.split.2x2").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("pane").font(.title2).fontWeight(.semibold)
                    Text("Windows-style window management for macOS").foregroundStyle(.secondary)
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("settings.about.version")
                }
            }
            .padding(.vertical, 4)
        }
        Section("Files") {
            if let url = model.store.url {
                LabeledContent("Settings file") {
                    HStack {
                        Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                    }
                }
            }
            LabeledContent("Program") {
                Text(Bundle.main.executablePath ?? CommandLine.arguments[0]).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        Section("Permissions") {
            LabeledContent("Accessibility", value: Permissions.shared.accessibility == .granted ? "Allowed" : "Not allowed")
            LabeledContent("Window previews", value: Permissions.shared.previews == .granted ? "On" : "Off")
        }
    }
}
