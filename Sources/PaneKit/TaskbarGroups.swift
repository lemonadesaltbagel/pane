// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

// Windows "Combine taskbar buttons" for pane (docs/research/taskbar-grouping.md §3): app groups, the three combine
// modes with the "when taskbar is full" solver, group cycling, the group flyout model and group actions.
// Everything here is UI-free; the bar renders `TaskbarPresentation` and the flyout renders `GroupFlyout`.

/// Windows' AppUserModelID analogue: the bundle ID (every pid of a bundle is one group), else the pid.
public struct AppKey: Hashable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(bundleID: String?, pid: pid_t) { raw = bundleID ?? "pid:\(pid)" }
    public var description: String { raw }
}

public enum CombineMode: String, Codable, CaseIterable {
    /// One icon-only button per app (Windows default).
    case always
    /// Labeled per-window buttons until the bar runs out of room, then apps collapse one by one.
    case whenFull
    /// One labeled button per window.
    case never
}

public struct TaskbarGroup: Identifiable, Equatable {
    public var id: String { "app:\(key.raw)" }
    public let key: AppKey
    public let bundleID: String?
    public let appName: String
    public let pids: [pid_t]
    public let isPinned: Bool
    /// Seat (creation) order — stable display order, like Windows.
    public let windows: [ManagedWindow]
    /// The same windows, most recently used first.
    public let mru: [CGWindowID]
    /// 0-based app position: the ⌘N target.
    public let index: Int

    public var activeWindow: CGWindowID? { windows.first(where: \.isFocused)?.id }
    public var isActive: Bool { activeWindow != nil }
    /// AltTab-style representative: the MRU head, else the first non-minimized, else the first window.
    public var representative: CGWindowID? {
        mru.first ?? windows.first(where: { !$0.isMinimized })?.id ?? windows.first?.id
    }
}

public struct TaskbarButton: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// An uncombined window button.
        case window(CGWindowID)
        /// A combined button (≥ 1 window), seat-ordered window ids.
        case group([CGWindowID])
        /// Pinned app without windows.
        case pinnedApp
    }

    /// `win:<id>` for windows, `app:<key>` for groups/pins — stable across combine transitions.
    public let id: String
    public let kind: Kind
    public let groupKey: AppKey
    public let groupIndex: Int
    public let bundleID: String?
    public let label: String
    public let showsLabel: Bool
    public let windowCount: Int
    public let isActive: Bool
    public let isMinimized: Bool
    public let width: CGFloat
}

public struct TaskbarMetrics {
    public var iconButton: CGFloat = 44
    public var labeledMin: CGFloat = 96
    public var labeledMax: CGFloat = 200
    /// Icon, padding and the label's insets around the text.
    public var labelChrome: CGFloat = 44
    public var spacing: CGFloat = 2
    public var overflowButton: CGFloat = 32
    /// Extra room required before collapsed groups expand again (stops the bar flapping).
    public var hysteresis: CGFloat = 24
    /// Text width of a label; the UI provides its font metrics, the default approximates 7 pt/character.
    public var measure: (String) -> CGFloat = { CGFloat($0.count) * 7 }

    public init() {}
}

public struct TaskbarPresentation: Equatable {
    public let buttons: [TaskbarButton]
    /// Behind the "…" button (Windows 11 overflow).
    public let overflow: [TaskbarButton]
    public let collapsed: Set<AppKey>

    public static let empty = TaskbarPresentation(buttons: [], overflow: [], collapsed: [])
}

extension TaskbarLayout {
    /// App groups in bar order: pinned apps (pinned order), then `appOrder` (the user's drag order), then new
    /// apps in order of their first window. Windows inside a group keep seat order.
    public static func groups(windows: [ManagedWindow], pinned: [String], appOrder: [AppKey] = [], history: FocusHistory? = nil) -> [TaskbarGroup] {
        let byKey = Dictionary(grouping: windows) { AppKey(bundleID: $0.bundleID, pid: $0.pid) }
        var order: [AppKey] = pinned.map(AppKey.init)
        for key in appOrder where !order.contains(key) && byKey[key] != nil { order.append(key) }
        let rest = byKey.keys.filter { !order.contains($0) }.sorted { (byKey[$0]?.map(\.seat).min() ?? 0) < (byKey[$1]?.map(\.seat).min() ?? 0) }
        order += rest

        var result: [TaskbarGroup] = []
        for key in order {
            let members = (byKey[key] ?? []).sorted { $0.seat < $1.seat }
            let isPinned = pinned.contains(key.raw)
            guard !members.isEmpty || isPinned else { continue }
            let name = members.first?.appName ?? displayName(bundleID: key.raw)
            let mru = (history?.sorted(members) ?? members).map(\.id)
            result.append(TaskbarGroup(key: key, bundleID: members.first?.bundleID ?? (isPinned ? key.raw : nil), appName: name,
                                       pids: Array(Set(members.map(\.pid))).sorted(), isPinned: isPinned, windows: members, mru: mru,
                                       index: result.count))
        }
        return result
    }

    static func displayName(bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    /// Buttons for a combine mode within `availableWidth` (§3.2). `previous` provides hysteresis for whenFull.
    public static func present(groups: [TaskbarGroup], mode: CombineMode, metrics: TaskbarMetrics = TaskbarMetrics(),
                               availableWidth: CGFloat, previous: TaskbarPresentation? = nil) -> TaskbarPresentation {
        func labeledWidth(_ text: String) -> CGFloat { min(metrics.labeledMax, max(metrics.labeledMin, metrics.measure(text) + metrics.labelChrome)) }

        func windowButton(_ window: ManagedWindow, _ group: TaskbarGroup, width: CGFloat? = nil) -> TaskbarButton {
            TaskbarButton(id: "win:\(window.id)", kind: .window(window.id), groupKey: group.key, groupIndex: group.index, bundleID: group.bundleID,
                          label: window.title, showsLabel: true, windowCount: 1, isActive: window.isFocused, isMinimized: window.isMinimized,
                          width: width ?? labeledWidth(window.title))
        }

        func groupButton(_ group: TaskbarGroup, labeled: Bool) -> TaskbarButton {
            if group.windows.isEmpty {
                return TaskbarButton(id: "app:\(group.key.raw)", kind: .pinnedApp, groupKey: group.key, groupIndex: group.index, bundleID: group.bundleID,
                                     label: group.appName, showsLabel: false, windowCount: 0, isActive: false, isMinimized: false, width: metrics.iconButton)
            }
            return TaskbarButton(id: "app:\(group.key.raw)", kind: .group(group.windows.map(\.id)), groupKey: group.key, groupIndex: group.index,
                                 bundleID: group.bundleID, label: group.appName, showsLabel: labeled, windowCount: group.windows.count,
                                 isActive: group.isActive, isMinimized: group.windows.allSatisfy(\.isMinimized),
                                 width: labeled ? labeledWidth(group.appName) : metrics.iconButton)
        }

        func total(_ buttons: [TaskbarButton]) -> CGFloat {
            buttons.reduce(0) { $0 + $1.width } + metrics.spacing * CGFloat(max(0, buttons.count - 1))
        }

        /// Evenly shrinks labeled buttons down to `labeledMin` to fit `width`.
        func shrink(_ buttons: [TaskbarButton], to width: CGFloat) -> [TaskbarButton] {
            let excess = total(buttons) - width
            guard excess > 0 else { return buttons }
            let labeled = buttons.filter(\.showsLabel)
            let slack = labeled.reduce(0) { $0 + ($1.width - metrics.labeledMin) }
            guard slack > 0 else { return buttons }
            let ratio = min(1, excess / slack)
            return buttons.map { button in
                guard button.showsLabel else { return button }
                let width = button.width - (button.width - metrics.labeledMin) * ratio
                return TaskbarButton(id: button.id, kind: button.kind, groupKey: button.groupKey, groupIndex: button.groupIndex, bundleID: button.bundleID,
                                     label: button.label, showsLabel: true, windowCount: button.windowCount, isActive: button.isActive,
                                     isMinimized: button.isMinimized, width: width.rounded(.down))
            }
        }

        /// Moves buttons from the right into overflow until the rest fits; never the active one.
        func overflowing(_ buttons: [TaskbarButton], collapsed: Set<AppKey>) -> TaskbarPresentation {
            var visible = buttons
            var hidden: [TaskbarButton] = []
            let budget = availableWidth - metrics.overflowButton - metrics.spacing
            while total(visible) > budget, let index = visible.lastIndex(where: { !$0.isActive }) {
                hidden.insert(visible.remove(at: index), at: 0)
            }
            return TaskbarPresentation(buttons: visible, overflow: hidden, collapsed: collapsed)
        }

        func layout(collapsed: Set<AppKey>, labeledGroups: Bool) -> [TaskbarButton] {
            groups.flatMap { group -> [TaskbarButton] in
                if group.windows.isEmpty || collapsed.contains(group.key) { return [groupButton(group, labeled: labeledGroups)] }
                return group.windows.map { windowButton($0, group) }
            }
        }

        switch mode {
        case .always:
            let buttons = groups.map { groupButton($0, labeled: false) }
            if total(buttons) <= availableWidth { return TaskbarPresentation(buttons: buttons, overflow: [], collapsed: Set(groups.map(\.key))) }
            return overflowing(buttons, collapsed: Set(groups.map(\.key)))

        case .never:
            let buttons = shrink(layout(collapsed: [], labeledGroups: false), to: availableWidth)
            if total(buttons) <= availableWidth { return TaskbarPresentation(buttons: buttons, overflow: [], collapsed: []) }
            return overflowing(buttons, collapsed: [])

        case .whenFull:
            // Collapse candidates: multi-window apps, oldest first (XP/7 default), ones without the active window first.
            let candidates = groups.filter { $0.windows.count >= 2 }
                .sorted { a, b in
                    if a.isActive != b.isActive { return !a.isActive }
                    return (a.windows.map(\.seat).min() ?? 0) < (b.windows.map(\.seat).min() ?? 0)
                }
            var collapsed = Set<AppKey>()
            // Hysteresis: keep what was collapsed unless the expanded bar fits with room to spare.
            if let previous, !previous.collapsed.isEmpty {
                let expanded = shrink(layout(collapsed: [], labeledGroups: true), to: availableWidth)
                if total(expanded) > availableWidth - metrics.hysteresis {
                    collapsed = previous.collapsed.intersection(Set(candidates.map(\.key)))
                }
            }
            var buttons = shrink(layout(collapsed: collapsed, labeledGroups: true), to: availableWidth)
            for candidate in candidates where total(buttons) > availableWidth && !collapsed.contains(candidate.key) {
                collapsed.insert(candidate.key)
                buttons = shrink(layout(collapsed: collapsed, labeledGroups: true), to: availableWidth)
            }
            if total(buttons) <= availableWidth { return TaskbarPresentation(buttons: buttons, overflow: [], collapsed: collapsed) }
            // Still too wide: icon-only collapsed groups, then overflow.
            buttons = shrink(layout(collapsed: collapsed, labeledGroups: false), to: availableWidth)
            if total(buttons) <= availableWidth { return TaskbarPresentation(buttons: buttons, overflow: [], collapsed: collapsed) }
            return overflowing(buttons, collapsed: collapsed)
        }
    }
}

/// ⌃-click / repeated ⌘N on a group: first the MRU head (or the next window when the head is already active),
/// then seat order, wrapping. Stepping through MRU would
/// ping-pong between the two most recent windows, since each focus re-sorts it. Resets after `timeout` idle.
public final class GroupCycle {
    private var state: (key: AppKey, index: Int, at: Date)?
    public var timeout: TimeInterval = 1.5

    public init() {}

    public func next(_ group: TaskbarGroup, now: Date = Date()) -> CGWindowID? {
        let seats = group.windows.map(\.id)
        guard !seats.isEmpty else { return nil }
        if let state, state.key == group.key, now.timeIntervalSince(state.at) < timeout {
            let index = (state.index + 1) % seats.count
            self.state = (group.key, index, now)
            return seats[index]
        }
        let head = group.mru.first ?? seats[0]
        var index = seats.firstIndex(of: head) ?? 0
        // The head is already the active window (the app is in front): Windows moves on to the next one.
        if head == group.activeWindow, seats.count > 1 { index = (index + 1) % seats.count }
        self.state = (group.key, index, now)
        return seats[index]
    }

    public func reset() { state = nil }
}

/// What the group flyout shows (UI-agnostic). Thumbnails are primary; the title list is the fallback when
/// previews aren't available or there are too many windows to fit (Windows switches to a list too).
public struct GroupFlyout: Equatable {
    public enum Presentation: Equatable { case thumbnails, list }

    public struct Entry: Equatable {
        public let wid: CGWindowID
        public let pid: pid_t
        public let title: String
        public let isActive: Bool
        public let isMinimized: Bool
        public let isOnOtherSpace: Bool
    }

    public let group: AppKey
    public let entries: [Entry]
    public let presentation: Presentation

    public static func make(for group: TaskbarGroup, previewsAvailable: Bool, maxThumbnails: Int) -> GroupFlyout {
        let entries = group.windows.map {
            Entry(wid: $0.id, pid: $0.pid, title: trimmed($0.title, appName: group.appName), isActive: $0.isFocused,
                  isMinimized: $0.isMinimized, isOnOtherSpace: !$0.isOnVisibleSpace)
        }
        let thumbnails = previewsAvailable && entries.count <= maxThumbnails
        return GroupFlyout(group: group.key, entries: entries, presentation: thumbnails ? .thumbnails : .list)
    }

    /// Windows' fit rule: how many thumbnails fit across the screen.
    public static func maxThumbnails(screenWidth: CGFloat, thumbnailWidth: CGFloat = 220, gap: CGFloat = 12) -> Int {
        max(1, Int((screenWidth - gap) / (thumbnailWidth + gap)))
    }

    /// Drops a trailing " — AppName" / " - AppName" suffix (Tungsten Edge does the same).
    static func trimmed(_ title: String, appName: String) -> String {
        for separator in [" — ", " - ", " – "] where title.hasSuffix(separator + appName) {
            return String(title.dropLast(separator.count + appName.count))
        }
        return title.isEmpty ? appName : title
    }
}

extension TaskbarActions {
    public enum GroupClick: Equatable {
        case launched, focused(CGWindowID), minimized(CGWindowID), showFlyout, failed
    }

    /// Windows: pinned without windows → launch; one window → that window's click; ≥ 2 → the flyout.
    public static func clickGroup(_ group: TaskbarGroup, inventory: WindowInventory) async -> GroupClick {
        if group.windows.isEmpty {
            guard let bundleID = group.bundleID else { return .failed }
            return await launch(bundleID: bundleID) == .launched ? .launched : .failed
        }
        if group.windows.count == 1, let window = group.windows.first {
            switch click(window, inventory: inventory) {
            case .focused: return .focused(window.id)
            case .minimized: return .minimized(window.id)
            default: return .failed
            }
        }
        return .showFlyout
    }

    /// Focus one window of a group (flyout entry, cycle, ⌘N). An already-active entry minimizes, as on Windows.
    @discardableResult
    public static func activate(_ wid: CGWindowID, inventory: WindowInventory, history: FocusHistory?) -> Outcome {
        guard let window = inventory.windows.first(where: { $0.id == wid }) else { return .failed }
        let outcome = click(window, inventory: inventory)
        if outcome == .focused { history?.note(wid) }
        return outcome
    }

    /// Focus only — never the minimize toggle (cycling, ⌘N, overflow picks).
    @discardableResult
    public static func focus(_ wid: CGWindowID, inventory: WindowInventory, history: FocusHistory?) -> Bool {
        guard let window = inventory.windows.first(where: { $0.id == wid }) else { return false }
        let element = inventory.element(for: wid)
        let ok: Bool
        if let element, window.isOnVisibleSpace || window.isMinimized { ok = Focus.focusBest(element) } else { ok = Focus.focusAnywhere(wid: wid, pid: window.pid, element: element) }
        if ok { history?.note(wid) }
        return ok
    }

    /// ⇧-right-click group menu.
    public enum GroupCommand: CaseIterable { case restoreAll, minimizeAll, closeAll, sideBySide, stacked, cascade }

    public static func perform(_ command: GroupCommand, on group: TaskbarGroup, inventory: WindowInventory, history: FocusHistory?) {
        if MouseTap.debug { print("group command \(command) on \(group.windows.map(\.title))") }
        let elements = group.windows.compactMap { window in inventory.element(for: window.id).map { (window, $0) } }
        switch command {
        case .restoreAll:
            for (_, element) in elements where AX.isMinimized(element) { AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse) }
            if let head = group.mru.first, let element = inventory.element(for: head) { Focus.focusBest(element) }
        case .minimizeAll:
            for (_, element) in elements {
                let result = AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
                if MouseTap.debug { print("minimizeAll \(AX.title(element) ?? "?") → \(result.rawValue)") }
            }
        case .closeAll:
            for (_, element) in elements { if let close = AX.button(element, kAXCloseButtonAttribute) { AX.perform(close, kAXPressAction) } }
        case .sideBySide, .stacked, .cascade:
            let visible = elements.filter { !AX.isMinimized($0.1) }
            guard let first = visible.first, let frame = AX.frame(first.1), let work = Geometry.workArea(for: frame) else { return }
            for (index, (_, element)) in visible.enumerated() {
                AX.setFrame(element, Self.arrange(command, index: index, count: visible.count, in: work))
            }
        }
    }

    /// Frames for Windows' "Show windows side by side / stacked" and "Cascade windows".
    public static func arrange(_ command: GroupCommand, index: Int, count: Int, in work: CGRect) -> CGRect {
        let n = CGFloat(max(1, count)), i = CGFloat(index)
        switch command {
        case .sideBySide:
            let width = (work.width / n).rounded(.down)
            return CGRect(x: work.minX + width * i, y: work.minY, width: index == count - 1 ? work.maxX - (work.minX + width * i) : width, height: work.height)
        case .stacked:
            let height = (work.height / n).rounded(.down)
            return CGRect(x: work.minX, y: work.minY + height * i, width: work.width, height: index == count - 1 ? work.maxY - (work.minY + height * i) : height)
        default:
            let step: CGFloat = 30
            let size = CGSize(width: (work.width * 0.6).rounded(), height: (work.height * 0.6).rounded())
            return CGRect(origin: CGPoint(x: work.minX + step * i, y: work.minY + step * i), size: size)
        }
    }
}
