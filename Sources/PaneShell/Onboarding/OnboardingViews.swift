// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

// Onboarding's steps. Fixed accessibility identifiers: onboarding.step.<name>, onboarding.back / .continue,
// onboarding.accessibility.status (AXValue granted/missing) / .grant, onboarding.previews.status / .allow,
// onboarding.keyboard.mac / .windows, onboarding.conflict.<bundle>[.quit|.ignore], onboarding.change.<setting> (one row
// per setting), onboarding.promise,
// onboarding.login.

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 0) {
            StepList(model: model)
                .frame(width: 210)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    StepContent(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 20)
                }
                Divider()
                HStack {
                    if model.step != .welcome {
                        Button("Back") { model.back() }
                            .accessibilityIdentifier("onboarding.back")
                    }
                    Spacer()
                    if model.step == .accessibility && model.accessibility != .granted {
                        Text("pane needs this to work.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(continueTitle) { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canContinue)
                        .accessibilityIdentifier("onboarding.continue")
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private var continueTitle: String {
        if model.isLast { return "Finish" }
        if model.step == .welcome { return "Get Started" }
        if model.step == .previews && model.previews != .granted { return "Continue Without Previews" }
        return "Continue"
    }
}

struct StepList: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let current = model.steps.firstIndex(of: model.step) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up pane").font(.headline).padding(.bottom, 12).padding(.top, 40)
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 10) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : step.symbol)
                        .foregroundStyle(i < current ? Color.green : (i == current ? Color.accentColor : Color.secondary))
                        .frame(width: 20)
                    Text(step.title)
                        .fontWeight(i == current ? .semibold : .regular)
                        .foregroundStyle(i <= current ? Color.primary : Color.secondary)
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == current ? Color.accentColor.opacity(0.12) : .clear))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of \(model.steps.count): \(model.step.title)")
    }
}

struct StepContent: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.step {
            case .welcome: WelcomeStep(model: model)
            case .accessibility: AccessibilityStep(model: model)
            case .previews: PreviewsStep(model: model)
            case .files: FilesStep(model: model)
            case .keyboard: model.keyboardStep.map { $0() }
            case .conflicts: ConflictsStep(model: model)
            case .changes: ChangesStep(model: model)
            case .login: LoginStep(model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.step.\(model.step.rawValue)")
    }
}

public struct StepHeader: View {
    let symbol: String
    let title: String
    let text: String
    public init(symbol: String, title: String, text: String) { self.symbol = symbol; self.title = title; self.text = text }

    public var body: some View {
        Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.tint)
        Text(title).font(.largeTitle).fontWeight(.semibold)
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct StatusLabel: View {
    let ok: Bool
    let okText: String
    let missingText: String

    var body: some View {
        Label(ok ? okText : missingText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "square.split.2x2", title: "Welcome to pane",
                   text: "pane brings Windows 11's taskbar, Start, snapping and Alt+Tab to your Mac. A few steps set it up; you can change every choice later in Settings (⌃⌘I).\(model.welcomeNote.map { " " + $0 } ?? "")")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.welcomeFeatures, id: \.text) { Label($0.text, systemImage: $0.symbol) }
        }
        .padding(.top, 6)
    }
}

struct AccessibilityStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let granted = model.accessibility == .granted
        StepHeader(symbol: "accessibility", title: "Allow Accessibility",
                   text: "pane moves, snaps and switches windows, and reads the keys you press for its shortcuts, through macOS's Accessibility permission. It's required; pane never records or sends what you type.")
        HStack(spacing: 14) {
            StatusLabel(ok: granted, okText: "Allowed", missingText: "Not allowed yet")
                .accessibilityIdentifier("onboarding.accessibility.status")
                .accessibilityValue(model.accessibility.rawValue)
            if !granted {
                Button("Allow…") { Permissions.shared.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.accessibility.grant")
            }
        }
        if !granted {
            Text("In System Settings ▸ Privacy & Security ▸ Accessibility, turn on pane. This step completes by itself; no restart needed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PreviewsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "rectangle.on.rectangle", title: "Window previews",
                   text: model.previewsText ?? "")
        HStack(spacing: 14) {
            StatusLabel(ok: model.previews == .granted, okText: "On", missingText: model.previews == .skipped ? "Skipped" : "Off")
                .accessibilityIdentifier("onboarding.previews.status")
                .accessibilityValue(model.previews.rawValue)
            if model.previews != .granted {
                Button(model.previewsBusy ? "Starting…" : "Turn On Previews…") { model.turnOnPreviews() }
                    .disabled(model.previewsBusy)
                    .accessibilityIdentifier("onboarding.previews.allow")
            }
        }
        if let note = model.previewNote {
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


struct FilesStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "doc.text.magnifyingglass", title: "Recent files", text: model.filesText ?? "")
        FileAccessControls()
    }
}

/// Full Disk Access, or only Desktop, Documents and Downloads (the welcome's recent-files step, and Settings). Each is
/// optional: without them only recent files are missing. The state is read again every second (you turn Full Disk
/// Access on in System Settings).
public struct FileAccessControls: View {
    @State private var level = FileAccess.level
    @State private var asking = false
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLabel(ok: level != .none, okText: level == .full ? "Full Disk Access is on: every recent file shows"
                                                                   : "Desktop, Documents and Downloads are allowed (jump lists need Full Disk Access)",
                        missingText: "Not allowed: recent files from protected folders don't show")
                .accessibilityIdentifier("files.status")
                .accessibilityValue(level.rawValue)
            if level != .full {
                HStack(spacing: 10) {
                    Button("Open Full Disk Access…") { FileAccess.openFullDiskAccessSettings() }
                        .accessibilityIdentifier("files.full")
                    if level == .none {
                        Button(asking ? "Asking…" : "Only Desktop, Documents and Downloads") {
                            asking = true
                            FileAccess.requestFolders { _ in asking = false; level = FileAccess.level }
                        }
                        .disabled(asking)
                        .accessibilityIdentifier("files.folders")
                    }
                }
                Text("In System Settings, turn on pane under Full Disk Access (add it with + if it isn't listed). It covers every folder and the apps' Open Recent lists.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !asking { level = FileAccess.level }
        }
    }
}

struct ConflictsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "app.badge", title: "Other apps that do the same",
                   text: "Two window managers, or two menu-bar managers, fight over the same windows and icons. Quit the ones pane replaces, or keep them.")
        if model.conflicts.isEmpty {
            Label("No other window, menu-bar or Dock managers are running.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("onboarding.conflicts.none")
        }
        ForEach(model.conflicts, id: \.pid) { app in
            let ignored = model.ignored.contains(app.bundleID)
            HStack(spacing: 10) {
                AppIconView(bundleID: app.bundleID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).fontWeight(.medium)
                    Text("A \(app.kind.rawValue): \(app.overlap).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if ignored {
                    Text("Kept").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Keep") { model.ignored.insert(app.bundleID) }
                        .accessibilityIdentifier("onboarding.conflict.\(app.bundleID).ignore")
                    Button("Quit \(app.name)") { Conflicts.quit(app); model.refresh() }
                        .accessibilityIdentifier("onboarding.conflict.\(app.bundleID).quit")
                }
            }
            .opacity(ignored ? 0.6 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.conflict.\(app.bundleID)")
        }
        if !model.macOSFeatures.isEmpty {
            Text("macOS").font(.headline).padding(.top, 8)
            ForEach(model.macOSFeatures, id: \.self) { feature in
                Label(note(feature), systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.macos.\(feature)")
            }
        }
    }

    private func note(_ feature: String) -> String {
        if feature.hasPrefix("macOS window tiling") {
            return model.store[PaneSettings.takeOverTiling]
                ? "\(feature) is on: pane turns it off while it runs and puts it back when it quits."
                : "\(feature) is on, and pane's snapping is off: both can't own window edges."
        }
        if feature == "Stage Manager" { return "Stage Manager is on: it regroups windows. Windows has no Stage Manager; turn it off in System Settings ▸ Desktop & Dock for pane's layout." }
        return feature
    }
}

struct ChangesStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "slider.horizontal.3", title: "What pane changes on your Mac",
                   text: "To work like Windows, pane changes these macOS settings while it runs. Turn off any you'd rather keep.")
        if model.changeRows.isEmpty {
            Text("Nothing: pane leaves macOS's settings as they are.").foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.changeRows, id: \.title) { change in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.title)
                        Text(change.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(change.title, isOn: Binding(get: { model.isOn(change) }, set: { model.set(change, on: $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(change.title)
                        .accessibilityIdentifier("onboarding.change.\(change.setting)")
                }
                .padding(.vertical, 4)
            }
        }
        Label(SystemChanges.promise, systemImage: "arrow.uturn.backward.circle")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.promise")
    }
}

struct LoginStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepHeader(symbol: "power", title: "Start pane at login",
                   text: "Like Windows' taskbar, pane is most useful when it's always there.")
        Toggle("Start pane when you log in", isOn: Binding(get: { model.store[PaneSettings.launchAtLogin] },
                                                         set: { try? model.store.set(PaneSettings.launchAtLogin, $0) }))
            .toggleStyle(.switch)
            .accessibilityIdentifier("onboarding.login")
        Text("You're set. Open Settings any time with ⌃⌘I, from pane's menu-bar icon, or by starting pane again.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}
