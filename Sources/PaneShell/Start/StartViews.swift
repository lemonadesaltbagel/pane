// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaneKit

// Start's views. Identifiers: start.search, start.pinned, start.pinned.<id>,
// start.folder.<n>, start.showAllPins, start.recent, start.recent.<n>, start.all, start.all.view, start.all.<id>,
// start.all.index.<letter>, start.results, start.result.<n>, start.preview, start.account, start.place.<name>,
// start.power, start.power.<action>.

struct StartRootView: View {
    @ObservedObject var model: StartMenuModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBox(model: model, focused: $searchFocused)
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 14)
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                StartHome(model: model)
            } else {
                SearchResults(model: model)
            }
            BottomBar(model: model)
        }
        .overlay { if model.openFolder != nil { FolderOverlay(model: model) } }
        .overlay { if let overlay = model.overlay { overlay } }
        .overlay { if model.jumpGrid { JumpGrid(model: model) } }
        .onAppear { searchFocused = true }
        .onChange(of: model.revision) { _, _ in if !searchFocused && model.openFolder == nil { searchFocused = true } }
    }
}

struct SearchBox: View {
    @ObservedObject var model: StartMenuModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for apps, settings and documents", text: $model.query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit { model.openSelection() }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .accessibilityIdentifier("start.search")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: - Home: Pinned, Recent, All

struct StartHome: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.prefs[PaneSettings.startShowPinned] { PinnedSection(model: model) }
                    if model.prefs[PaneSettings.startShowRecent] && (!model.recentItems.isEmpty || model.recentHint() != nil) { RecentSection(model: model) }
                    if model.prefs[PaneSettings.startShowAll] { AllSection(model: model) }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            trailing()
        }
    }
}

/// An app's tile: icon over its name (Pinned, Grid view, folders).
public struct AppTile: View {
    @ObservedObject var model: StartMenuModel
    let app: AppIndex.App
    let identifier: String
    var size: CGFloat = 36

    public init(model: StartMenuModel, app: AppIndex.App, identifier: String, size: CGFloat = 36) {
        self.model = model; self.app = app; self.identifier = identifier; self.size = size
    }

    public var body: some View {
        Button { model.launch(app) } label: {
            VStack(spacing: 6) {
                Image(nsImage: model.index.icon(app)).resizable().frame(width: size, height: size)
                Text(app.name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8).padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel(app.name)
        .accessibilityIdentifier(identifier)
    }
}

public struct TileStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0001)))
            .modifier(HoverHighlight())
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
            .onHover { hovered = $0 }
    }
}

/// The menu shown on right-click for an app (Pinned, All, search).
public struct AppMenu: View {
    @ObservedObject var model: StartMenuModel
    let app: AppIndex.App
    var inFolder: Int? = nil

    public init(model: StartMenuModel, app: AppIndex.App, inFolder: Int? = nil) { self.model = model; self.app = app; self.inFolder = inFolder }

    public var body: some View {
        if model.store.isPinned(app.id) {
            Button("Unpin from Start") { model.store.unpin(app.id) }
            if model.store.pinned.first != .app(app.id), model.store.pinned.contains(.app(app.id)) {
                Button("Move to front") { model.store.moveToFront(app.id) }
            }
        } else {
            Button("Pin to Start") { model.store.pin(app.id) }
        }
        if let folder = inFolder { Button("Remove from folder") { model.store.removeFromFolder(app.id, folder: folder) } }
        if model.isPinnedToTaskbar(app.id) {
            Button("Unpin from taskbar") { model.setPinnedToTaskbar(app.id, false) }
        } else {
            Button("Pin to taskbar") { model.setPinnedToTaskbar(app.id, true) }
        }
        Divider()
        Button("Show in Finder") { model.showInFinder(app.url) }
    }
}

struct PinnedSection: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        let items = model.pinned
        let shown = model.showAllPins ? items : Array(items.prefix(model.columns * 2))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Pinned") {
                if items.count > model.columns * 2 {
                    Button(model.showAllPins ? "Show less" : "Show all") { model.showAllPins.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .accessibilityIdentifier("start.showAllPins")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: model.columns), spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                    PinnedCell(model: model, item: item, position: i)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("start.pinned")
        }
    }
}

/// One pinned item: drag it to reorder; drop another onto its middle to make (or fill) a folder.
struct PinnedCell: View {
    @ObservedObject var model: StartMenuModel
    let item: PinnedItem
    let position: Int
    @State private var targeted = false

    var body: some View {
        Group {
            switch item {
            case .app(let id):
                if let app = model.index.app(id) {
                    AppTile(model: model, app: app, identifier: "start.pinned.\(id)")
                        .contextMenu { AppMenu(model: model, app: app) }
                }
            case .folder(let name, let apps):
                FolderTile(model: model, name: name, apps: apps, position: position)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
        .draggable("pin:\(position)")
        .dropDestination(for: String.self) { payloads, location in
            guard let payload = payloads.first, payload.hasPrefix("pin:"), let from = Int(payload.dropFirst(4)), from != position else { return false }
            // The middle of a tile makes a folder; its edges place the item before or after it.
            let width: CGFloat = 80
            // Making folders is Pro: in Free a drop on the middle just places it there.
            if model.canMakeFolders() && location.x > width * 0.25 && location.x < width * 0.75 { model.store.drop(from, onto: position) }
            else { model.store.move(from: from, to: location.x <= width * 0.25 ? position : position + (from < position ? 0 : 1)) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct FolderTile: View {
    @ObservedObject var model: StartMenuModel
    let name: String
    let apps: [String]
    let position: Int

    var body: some View {
        Button { model.openFolder = position } label: {
            VStack(spacing: 6) {
                LazyVGrid(columns: [GridItem(.fixed(16), spacing: 2), GridItem(.fixed(16), spacing: 2)], spacing: 2) {
                    ForEach(apps.prefix(4), id: \.self) { id in
                        if let app = model.index.app(id) { Image(nsImage: model.index.icon(app)).resizable().frame(width: 16, height: 16) }
                    }
                }
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                Text(name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 84).contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel("Folder \(name)")
        .accessibilityIdentifier("start.folder.\(position)")
    }
}

struct FolderOverlay: View {
    @ObservedObject var model: StartMenuModel
    @State private var name = ""

    var body: some View {
        if let index = model.openFolder, model.store.pinned.indices.contains(index), case .folder(let folderName, let apps) = model.store.pinned[index] {
            ZStack {
                Color.black.opacity(0.25).onTapGesture { model.openFolder = nil }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Folder name", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                        .onSubmit { model.store.renameFolder(index, to: name) }
                        .onAppear { name = folderName }
                        .accessibilityIdentifier("start.folder.name")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(apps, id: \.self) { id in
                            if let app = model.index.app(id) {
                                AppTile(model: model, app: app, identifier: "start.folder.\(index).\(id)")
                                    .contextMenu { AppMenu(model: model, app: app, inFolder: index) }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(width: 380)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                .onDisappear { if !name.isEmpty && name != folderName { model.store.renameFolder(index, to: name) } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("start.folder.open")
        }
    }
}

struct RecentSection: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        let items = model.recentItems
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent") { EmptyView() }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Button { item.kind == .app ? model.launch(id: item.id) : model.openFile(item.url) } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 12)).lineLimit(1)
                                Text(item.kind == .app ? "Recently added" : RecentFiles.relativeTime(item.date))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6).contentShape(Rectangle())
                    }
                    .buttonStyle(TileStyle())
                    .contextMenu {
                        Button("Remove from list") { model.store.hideRecent(item.id) }
                        Button("Show in Finder") { model.showInFinder(item.url) }
                    }
                    .accessibilityLabel(item.name)
                    .accessibilityIdentifier("start.recent.\(i)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("start.recent")
            if let hint = model.recentHint() {
                Button(hint.text) { hint.action() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("start.recent.allow")
            }
        }
    }
}

struct AllSection: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        let view = model.allView
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "All") {
                Picker("View", selection: Binding(get: { view }, set: { try? model.prefs.set(PaneSettings.startAllView, $0) })) {
                    ForEach(model.extraAllViews.filter { $0.isAvailable() }, id: \.id) { Text($0.title).tag($0.id) }
                    Text("Grid").tag("grid")
                    Text("List").tag("list")
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("All apps view")
                .accessibilityIdentifier("start.all.view")
            }
            Group {
                switch view {
                case "grid": LetterGrid(model: model, grid: true)
                case "list": LetterGrid(model: model, grid: false)
                default: model.extraAllViews.first { $0.id == view }.map { $0.view() } ?? AnyView(LetterGrid(model: model, grid: true))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("start.all")
        }
    }
}


/// Grid and List views: A–Z under letter headers; a header opens the letter grid. Most used first, when shown.
struct LetterGrid: View {
    @ObservedObject var model: StartMenuModel
    let grid: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.prefs[PaneSettings.startMostUsed], !model.index.mostUsed().isEmpty {
                letterSection("Most used", apps: model.index.mostUsed(), header: false)
            }
            ForEach(model.index.byLetter(), id: \.letter) { group in
                letterSection(group.letter, apps: group.apps, header: true)
            }
        }
    }

    @ViewBuilder
    private func letterSection(_ letter: String, apps: [AppIndex.App], header: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if header {
                Button(letter) { model.jumpGrid = true }
                    .buttonStyle(.borderless).font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("start.all.index.\(letter)")
            } else {
                Text(letter).font(.system(size: 13, weight: .semibold))
            }
            if grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: model.columns), spacing: 4) {
                    ForEach(apps) { app in
                        AppTile(model: model, app: app, identifier: header ? "start.all.\(app.id)" : "start.mostUsed.\(app.id)", size: 32)
                            .contextMenu { AppMenu(model: model, app: app) }
                    }
                }
            } else {
                ForEach(apps) { app in
                    Button { model.launch(app) } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: model.index.icon(app)).resizable().frame(width: 24, height: 24)
                            Text(app.name).font(.system(size: 12))
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(TileStyle())
                    .contextMenu { AppMenu(model: model, app: app) }
                    .accessibilityLabel(app.name)
                    .accessibilityIdentifier(header ? "start.all.\(app.id)" : "start.mostUsed.\(app.id)")
                }
            }
        }
        .id("letter-\(letter)")
    }
}

struct JumpGrid: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        let present = Set(model.index.byLetter().map(\.letter))
        let letters = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
        ZStack {
            Color.black.opacity(0.35).onTapGesture { model.jumpGrid = false }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 7), spacing: 6) {
                ForEach(letters, id: \.self) { letter in
                    Button(letter) {
                        model.jumpGrid = false
                        model.scrollTarget = "letter-\(letter)"
                    }
                    .buttonStyle(.borderless).font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(present.contains(letter) ? 0.1 : 0.03)))
                    .disabled(!present.contains(letter))
                    .accessibilityIdentifier("start.jump.\(letter)")
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start.jumpGrid")
    }
}

// MARK: - Search results

struct SearchResults: View {
    @ObservedObject var model: StartMenuModel

    var body: some View {
        let all = model.allResults
        let best = all.first { $0.id == model.selection } ?? all.first
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if all.isEmpty {
                        Text("No results for “\(model.query)”").foregroundStyle(.secondary).padding(.top, 20)
                    }
                    ForEach(groups(all), id: \.0) { group in
                        Text(group.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 6)
                        ForEach(group.1) { result in ResultRow(model: model, result: result, position: all.firstIndex(of: result) ?? 0) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("start.results")
            if let best { Preview(model: model, result: best).frame(width: 250) }
        }
    }

    private func groups(_ all: [StartResult]) -> [(String, [StartResult])] {
        guard let first = all.first(where: { $0.id == StartSearch.bestMatch(all, query: model.query)?.id }) else { return [] }
        let rest = all.filter { $0 != first }
        var result: [(String, [StartResult])] = [("Best match", [first])]
        for (title, kinds) in [("Apps", [StartResult.Kind.app]), ("Settings", [.systemSetting, .paneSetting]), ("Documents", [.file]), ("Folders", [.folder])] {
            let items = rest.filter { kinds.contains($0.kind) }
            if !items.isEmpty { result.append((title, items)) }
        }
        return result
    }
}

struct ResultRow: View {
    @ObservedObject var model: StartMenuModel
    let result: StartResult
    let position: Int

    var body: some View {
        let selected = model.selection == result.id
        Button { model.open(result) } label: {
            HStack(spacing: 10) {
                ResultIcon(model: model, result: result, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(.system(size: 13)).lineLimit(1)
                    Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selection = result.id } }
        .accessibilityLabel("\(result.title), \(result.subtitle)")
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityIdentifier("start.result.\(position)")
    }
}

struct ResultIcon: View {
    @ObservedObject var model: StartMenuModel
    let result: StartResult
    let size: CGFloat

    var body: some View {
        Group {
            switch result.kind {
            case .app:
                if let app = model.index.app(result.target) { Image(nsImage: model.index.icon(app)).resizable() } else { Image(systemName: "app") }
            case .systemSetting: Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")).resizable()
            case .paneSetting: Image(systemName: "square.split.2x2").resizable().foregroundStyle(.tint)
            case .file, .folder: Image(nsImage: NSWorkspace.shared.icon(forFile: result.url?.path ?? "/")).resizable()
            }
        }
        .frame(width: size, height: size)
    }
}

struct Preview: View {
    @ObservedObject var model: StartMenuModel
    let result: StartResult

    var body: some View {
        VStack(spacing: 10) {
            ResultIcon(model: model, result: result, size: 56).padding(.top, 24)
            Text(result.title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(kindName).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 2) {
                action("Open", "arrow.up.forward.app") { model.open(result) }
                if let url = result.url, result.kind != .systemSetting { action("Show in Finder", "folder") { model.showInFinder(url) } }
                if result.kind == .app {
                    let id = result.target
                    if model.store.isPinned(id) { action("Unpin from Start", "pin.slash") { model.store.unpin(id) } }
                    else { action("Pin to Start", "pin") { model.store.pin(id) } }
                    if model.isPinnedToTaskbar(id) { action("Unpin from taskbar", "pin.slash") { model.setPinnedToTaskbar(id, false) } }
                    else { action("Pin to taskbar", "dock.rectangle") { model.setPinnedToTaskbar(id, true) } }
                }
            }
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .padding(.trailing, 20).padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("start.preview")
    }

    private var kindName: String {
        switch result.kind {
        case .app: return "App"
        case .systemSetting: return "System Settings"
        case .paneSetting: return result.subtitle
        case .file: return "Document"
        case .folder: return "Folder"
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
        .accessibilityIdentifier("start.preview.\(title)")
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var model: StartMenuModel
    /// Sized up front: a menu's label ignores SwiftUI's frame and would show the picture at full size.
    private let avatar = Account.avatar(size: 28)

    var body: some View {
        HStack(spacing: 6) {
            if !model.prefs[PaneSettings.startHideAccount] {
                Menu {
                    Button("Change account settings") { model.openAccountSettings() }
                    Divider()
                    Button("Lock") { model.power(.lock) }.accessibilityIdentifier("start.account.lock")
                    Button("Log out") { model.power(.logOut) }.accessibilityIdentifier("start.account.logOut")
                    Button("Switch user") { model.power(.switchUser) }.accessibilityIdentifier("start.account.switchUser")
                } label: {
                    HStack(spacing: 8) {
                        if let picture = avatar { Image(nsImage: picture) }
                        else { Image(systemName: "person.crop.circle.fill").resizable().frame(width: 28, height: 28).foregroundStyle(.secondary) }
                        Text(Account.name).font(.system(size: 12))
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Account: \(Account.name)")
                .accessibilityIdentifier("start.account")
            }
            Spacer()
            ForEach(model.prefs[PaneSettings.startFolders].compactMap(StartPlace.init(rawValue:)), id: \.self) { place in
                Button { model.open(place) } label: { Image(systemName: place.symbol).frame(width: 30, height: 30) }
                    .buttonStyle(TileStyle())
                    .help(place.title)
                    .accessibilityLabel(place.title)
                    .accessibilityIdentifier("start.place.\(place.rawValue)")
            }
            Menu {
                ForEach([PowerAction.lock, .sleep, .restart, .shutDown], id: \.self) { action in
                    Button(action.title) { model.power(action) }.accessibilityIdentifier("start.power.\(action.rawValue)")
                }
            } label: { Image(systemName: "power").frame(width: 30, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Power")
                .accessibilityLabel("Power")
                .accessibilityIdentifier("start.power")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }
}
