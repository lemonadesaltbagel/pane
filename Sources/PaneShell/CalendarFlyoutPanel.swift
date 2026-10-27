// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

/// The taskbar clock's calendar (Windows 11): the date, then the month with today marked and ◀ ▶ to change month.
/// Clicking the date goes back to today. A click anywhere else closes it; so does clicking the clock again.
@MainActor
public final class CalendarFlyoutPanel {
    public let panel: NSPanel
    let model = CalendarModel()
    private var monitors: [Any] = []
    /// Clicks here don't close it (the clock: it toggles the flyout itself).
    var anchorHit: ((NSEvent) -> Bool)?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 330), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        // The first click must act, not just make the panel key.
        panel.becomesKeyOnlyIfNeeded = true
        GlassSurface.configure(panel, shadow: true)
        panel.title = "Pane Calendar"
        let host = NSHostingView(rootView: CalendarView(model: model))
        panel.contentView = GlassSurface(role: .popup, cornerRadius: 12, content: host)
    }

    public var isShown: Bool { panel.isVisible }

    /// The month shown now (tests).
    public var month: CalendarMonth { model.month }

    /// Above `anchor` (the clock's frame in screen coordinates), its right edges lined up, on this month.
    public func show(anchor: NSRect) {
        model.reset()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 330)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.maxX - size.width, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.maxY + 12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if monitors.isEmpty {
            // Another app's window, or the desktop.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }) { monitors.append(global) }
            // One of pane's own windows (the taskbar), but not the flyout or the clock.
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window !== self.panel, self.anchorHit?(event) != true else { return }
                    self.hide()
                }
                return event
            }) { monitors.append(local) }
        }
    }

    public func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel.orderOut(nil)
    }

    public func toggle(anchor: NSRect) { isShown ? hide() : show(anchor: anchor) }

    /// Tests and keys: the next or previous month, back to today.
    public func move(by months: Int) { model.move(by: months) }
    public func goToToday() { model.reset() }
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var month = CalendarMonth(containing: Date())
    @Published private(set) var header = CalendarMonth.header()

    func reset() {
        month = CalendarMonth(containing: Date())
        header = CalendarMonth.header()
    }

    func move(by months: Int) { month = month.moved(by: months) }
}

struct CalendarView: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.reset() } label: {
                Text(model.header).font(.headline).foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Today")
            .accessibilityIdentifier("calendar.header")
            Divider()
            HStack {
                Text(model.month.title).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("calendar.title")
                Spacer()
                Button { model.move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous month")
                    .accessibilityIdentifier("calendar.previous")
                Button { model.move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next month")
                    .accessibilityIdentifier("calendar.next")
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(model.month.weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 38, height: 22)
                    }
                }
                ForEach(Array(model.month.weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week) { day in DayCell(day: day) }
                    }
                }
            }
        }
        .padding(16)
        .fixedSize()
    }
}

struct DayCell: View {
    let day: CalendarMonth.Day

    var body: some View {
        Text("\(day.number)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(day.isToday ? Color.white : day.inMonth ? Color.primary : Color.secondary.opacity(0.6))
            .frame(width: 38, height: 34)
            .background {
                if day.isToday { Circle().fill(Color.accentColor).frame(width: 32, height: 32) }
            }
            .accessibilityElement()
            .accessibilityLabel("\(day.number)" + (day.isToday ? ", today" : day.inMonth ? "" : ", other month"))
            .accessibilityIdentifier("calendar.day.\(day.id)")
    }
}
