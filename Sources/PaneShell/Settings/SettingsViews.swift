// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

// The settings window's pages. Each control's accessibility identifier is its
// setting id; fixed ids for the rest (§6): settings.sidebar.<page>, settings.search, settings.advancedToggle,
// settings.restartBar / restartButton, settings.apps.*, keys.<action>.recorder / .conflict.

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !model.pending.isEmpty { RestartBar(model: model) }
                if let notice = model.notice { NoticeBar(model: model, text: notice) }
                if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    PageView(model: model, page: model.currentPage)
                } else {
                    SearchResultsView(model: model)
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    /// Consecutive pages under the same header.
    private var sections: [(category: String?, pages: [SettingsPage])] {
        var result: [(String?, [SettingsPage])] = []
        for page in model.pages {
            if let last = result.last, last.0 == page.category { result[result.count - 1].1.append(page) }
            else { result.append((page.category, [page])) }
        }
        return result.map { (category: $0.0, pages: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find a setting", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .accessibilityIdentifier("settings.search")
            List(selection: Binding<String?>(get: { model.search.isEmpty ? model.page : nil },
                                             set: { if let id = $0 { model.page = id; model.search = "" } })) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.pages) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page.id)
                                .accessibilityIdentifier("settings.sidebar.\(page.id)")
                        }
                    } header: {
                        if let category = section.category { Text(category) }
                    }
                }
            }
            .listStyle(.sidebar)
            Toggle("Show advanced settings", isOn: $model.showAdvanced)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .accessibilityIdentifier("settings.advancedToggle")
        }
    }
}

// MARK: - Pages

struct PageView: View {
    @ObservedObject var model: SettingsModel
    let page: SettingsPage

    var body: some View {
        Form {
            switch page.id {
            case "general": PermissionsSection(model: model)
            default: EmptyView()
            }
            ForEach(Array(page.groups.enumerated()), id: \.offset) { _, group in
                let ids = group.ids.filter { model.isShown($0) }
                if !ids.isEmpty {
                    Section {
                        ForEach(ids, id: \.self) { SettingRow(model: model, id: $0) }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            switch page.id {
            case "keyboard": KeymapSection(model: model)
            case "apps": EmptyView()
            case "advanced": AdvancedActionsSection(model: model)
            case "about": AboutSection(model: model)
            default: EmptyView()
            }
            if let section = model.pageSections[page.id] { section() }
        }
        .formStyle(.grouped)
    }
}

struct SearchResultsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let ids = PaneSettings.search(model.search).map(\.id).filter { id in
            guard let s = PaneSettings.setting(id: id), !SettingsPages.internalIDs.contains(id) else { return false }
            return s.info.status != .planned || s.info.kind == .shortcut
        }
        Form {
            if ids.isEmpty {
                Text("No settings match “\(model.search)”.").foregroundStyle(.secondary)
            }
            ForEach(model.pages) { page in
                let onPage = ids.filter { SettingsPages.page(containing: $0)?.id == page.id }
                if !onPage.isEmpty {
                    Section(page.title) {
                        ForEach(onPage, id: \.self) { SettingRow(model: model, id: $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Bars

struct RestartBar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let titles = model.pending.map { model.title($0) }
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(titles.count == 1 ? "1 change takes effect after pane restarts" : "\(titles.count) changes take effect after pane restarts")
                    .fontWeight(.semibold)
                Text(titles.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Restart pane") { model.onRestart?(model.page) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.restartButton")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.restartBar")
    }
}

struct NoticeBar: View {
    @ObservedObject var model: SettingsModel
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.notice")
    }
}

// MARK: - Rows

/// Title, help, and "after restart" for a setting.
public struct RowLabel: View {
    let info: SettingInfo
    public init(info: SettingInfo) { self.info = info }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title)
            if !info.help.isEmpty {
                Text(info.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if info.status == .restart {
                Label("After restart", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.orange)
            } else if info.status == .planned {
                Text("Not available yet").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// One setting, with the control its kind calls for and a reset button when it isn't the default.
struct SettingRow: View {
    @ObservedObject var model: SettingsModel
    let id: String

    var body: some View {
        if let setting = PaneSettings.setting(id: id) {
            HStack(alignment: .center, spacing: 8) {
                control(setting)
                    .disabled(!model.isEnabled(id) || model.isLocked(id))
                if model.isLocked(id) {
                    Button { if let page = model.lockPage { model.page = page } } label: {
                        Text(model.lockBadge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .help("Not in this edition")
                    .accessibilityLabel("\(model.lockBadge) feature")
                    .accessibilityIdentifier("\(id).pro")
                }
                if !model.store.isDefault(id: id) && setting.info.kind != .shortcut {
                    Button { model.store.reset(id: id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to default")
                        .accessibilityLabel("Reset \(setting.info.title) to default")
                        .accessibilityIdentifier("\(id).reset")
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ setting: AnySetting) -> some View {
        let info = setting.info
        switch info.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { model.store.json(id) == .bool(true) }, set: { set(.bool($0)) })) { RowLabel(info: info) }
                .accessibilityLabel(info.title)
                .help(info.help)
                .accessibilityIdentifier(id)
        case _ where model.customRows[id] != nil:
            model.customRows[id]!()
        case .choice(let choices):
            Picker(selection: Binding(get: { model.store.json(id).flatMap(\.stringValue) ?? "" }, set: { set(.string($0)) })) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            } label: { RowLabel(info: info) }
                .accessibilityLabel(info.title)
                .help(info.help)
                .accessibilityIdentifier(id)
        case .number(let min, let max, let step, let unit):
            NumberRow(model: model, id: id, info: info, range: min...max, step: step, unit: unit)
        case .appList:
            AppListRow(model: model, id: id, info: info)
        case .shortcut:
            ShortcutRow(model: model, id: id, info: info)
        case .multiChoice(let choices):
            MultiChoiceRow(model: model, id: id, info: info, choices: choices)
        case .text:
            LabeledContent {
                TextField(info.title, text: Binding(get: { model.store.json(id).flatMap(\.stringValue) ?? "" }, set: { set(.string($0)) }))
                    .accessibilityIdentifier(id)
            } label: { RowLabel(info: info) }
        }
    }

    private func set(_ value: JSONValue) {
        do { try model.store.set(id: id, json: value) } catch { model.notice = "Couldn't change “\(model.title(id))”: the value isn't allowed." }
    }
}

struct NumberRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let info: SettingInfo
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        let value = model.store.json(id).flatMap(\.doubleValue) ?? range.lowerBound
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { value }, set: { try? model.store.set(id: id, json: .number(($0 / step).rounded() * step)) }),
                       in: range, step: step)
                    .frame(minWidth: 140, maxWidth: 220)
                    .accessibilityLabel(info.title)
                    .accessibilityIdentifier(id)
                Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) \(unit)" : String(format: "%.1f \(unit)", value))
                    .monospacedDigit().frame(minWidth: 56, alignment: .trailing)
            }
        } label: { RowLabel(info: info) }
            .help(info.help)
    }
}

/// Several of fixed choices: one switch each (ids `<setting>.<value>`), kept in the choices' order.
struct MultiChoiceRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let info: SettingInfo
    let choices: [SettingKind.Choice]

    var body: some View {
        let chosen = Set(model.store.json(id)?.stringArray ?? [])
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(info: info)
            ForEach(choices, id: \.value) { choice in
                Toggle(choice.label, isOn: Binding(get: { chosen.contains(choice.value) }, set: { on in
                    let next = choices.map(\.value).filter { $0 == choice.value ? on : chosen.contains($0) }
                    try? model.store.set(id: id, json: .array(next.map { .string($0) }))
                }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("\(id).\(choice.value)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - App lists

/// Name and icon of an app by bundle ID (running or installed; else the ID itself).
public enum AppInfo {
    public static func name(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    public static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// Running apps with a Dock icon (`menuBarApps`: also menu-bar-only ones), by name, minus `excluded`.
    public static func runningApps(excluding excluded: Set<String>, menuBarApps: Bool = false) -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { ($0.activationPolicy == .regular || menuBarApps && $0.activationPolicy == .accessory) && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { (id: $0, name: app.localizedName ?? $0) } }
            .filter { !excluded.contains($0.id) }
            .reduce(into: [(id: String, name: String)]()) { list, app in if !list.contains(where: { $0.id == app.id }) { list.append(app) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Choose from Applications…": bundle IDs of the chosen apps.
    @MainActor public static func chooseApps() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

public struct AppIconView: View {
    let bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
    public var body: some View { Image(nsImage: AppInfo.icon(bundleID)).resizable().frame(width: 20, height: 20) }
}

/// A list of apps (bundle IDs): "+" adds a running app or one from Applications, "−" removes. `taskbar.pinned` is
/// optional: nil means "the Dock's apps".
struct AppListRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let info: SettingInfo

    var body: some View {
        let stored = model.store.json(id)
        let list = stored?.stringArray ?? []
        let followsDock = id == PaneSettings.pinned.id && stored == .null
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RowLabel(info: info)
                Spacer()
                Menu {
                    ForEach(AppInfo.runningApps(excluding: Set(list), menuBarApps: info.section == .tray), id: \.id) { app in
                        Button(app.name) { save((followsDock ? DockPins.read() : list) + [app.id]) }
                    }
                    Divider()
                    Button("Choose from Applications…") {
                        let chosen = AppInfo.chooseApps().filter { !list.contains($0) }
                        if !chosen.isEmpty { save((followsDock ? DockPins.read() : list) + chosen) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Add an app to \(info.title)")
                    .accessibilityIdentifier("\(id).add")
            }
            if followsDock {
                HStack {
                    Text("Same as the Dock's apps.").font(.caption).foregroundStyle(.secondary)
                    Button("Customize") { save(DockPins.read()) }.controlSize(.small)
                }
            } else if list.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { bundle in
                HStack(spacing: 8) {
                    AppIconView(bundleID: bundle)
                    Text(AppInfo.name(bundle))
                    Text(bundle).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { save(list.filter { $0 != bundle }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(AppInfo.name(bundle))")
                        .accessibilityIdentifier("\(id).remove.\(bundle)")
                }
                .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private func save(_ list: [String]) {
        try? model.store.set(id: id, json: .array(list.map { .string($0) }))
    }
}

// MARK: - JSON helpers

extension JSONValue {
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }
}
