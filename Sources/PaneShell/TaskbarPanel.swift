// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Minimal functional taskbar — a test harness for the mechanics (placement over the Dock, level, Spaces,
/// click semantics), not a design. The real UI is built separately on top of `TaskbarLayout` /
/// `TaskbarActions` / `WindowInventory`.
@MainActor
public final class TaskbarPanel {
    public let panel: NSPanel
    public private(set) var items: [TaskbarItem] = []
    public var pinned: [String]
    /// Windows "Combine taskbar buttons": `.never` = one button per window (default), `.always`, `.whenFull`.
    public var mode: CombineMode = .never
    public let history: FocusHistory
    public private(set) var groups: [TaskbarGroup] = []
    public private(set) var presentation = TaskbarPresentation.empty
    public let flyoutPanel = GroupFlyoutPanel()
    private let cycle = GroupCycle()
    private var hoverWork: DispatchWorkItem?

    private let inventory: WindowInventory
    /// Windows 11's "Show desktop" sliver at the far right.
    private let showDesktopButton = ShowDesktopButton()
    public var onShowDesktop: (() -> Void)?
    @objc private func showDesktopClicked() { onShowDesktop?() }
    /// Windows: right-clicking the bar's empty space offers "Taskbar settings".
    public var onTaskbarSettings: (() -> Void)?

    final class BarBackground: NSView {
        var onRightClick: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    }

    private func showBarMenu() {
        let entries: [(String, (() -> Void)?)] = [("Taskbar settings", { [weak self] in self?.onTaskbarSettings?() })]
        let at = NSEvent.mouseLocation, top = panel.frame.maxY
        ChoicePanel.shared.show(entries, atAX: Geometry.cocoaToAX(CGRect(x: at.x, y: top + 8 + CGFloat(entries.count) * 26, width: 1, height: 1), primaryHeight: Geometry.primaryHeight).origin)
    }
    /// The bar's background: glass over the wallpaper slice under the bar (GlassSurface).
    private var surface: GlassSurface!
    /// Windows 11 alignment of Start and the app buttons.
    public enum Alignment: String { case center, left }
    public var alignment: Alignment = .center { didSet { applyAlignment() } }
    private var leftAligned: NSLayoutConstraint!
    private var centered: NSLayoutConstraint!
    private let stack = NSStackView()
    private let clock = ClockLabel(labelWithString: "")
    /// An app's recent files for its right-click list (Windows' jump list), from an extension. Nil: none.
    public var jumpList: ((String) -> [JumpItem])?
    public struct JumpItem {
        public let title: String
        public let open: () -> Void
        public init(title: String, open: @escaping () -> Void) { self.title = title; self.open = open }
    }

    /// The clock's calendar (Windows 11): a click on the clock opens or closes it.
    public let calendarPanel = CalendarFlyoutPanel()
    private var clockTimer: Timer?
    private let trayStack = NSStackView()
    private var trayTimer: Timer?
    /// The notification area (pane Pro's tray): the bar gives it the stack between the apps and the clock.
    /// (A computed property: a stored one's `didSet` wouldn't run when the bar's own init sets it.)
    public var trayProvider: TaskbarTray? {
        get { installedTray }
        set {
            installedTray?.detach()
            installedTray = newValue
            newValue?.attach(self, stack: trayStack)
            if panel.isVisible { newValue?.barShown() }
        }
    }
    private var installedTray: TaskbarTray?
    /// Made for every taskbar when set (tests standing in for the official build use it).
    nonisolated(unsafe) public static var makeTray: (@MainActor () -> TaskbarTray)?
    /// One level above the Dock, so the bar covers the small reserving Dock.
    public static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    public init(inventory: WindowInventory, height: CGFloat, pinned: [String] = [], history: FocusHistory = FocusHistory(), mode: CombineMode = .never) {
        self.inventory = inventory
        self.pinned = pinned
        self.history = history
        self.mode = mode
        let screen = NSScreen.screens[0]
        panel = BarPanel(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true // must precede `level`: it resets the level to .floating
        panel.level = Self.level
        // On every desktop, not moving during Space switches; not on fullscreen Spaces (like Windows hiding the
        // taskbar for fullscreen apps) and not in the window cycle.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none // panels zoom in on show; mid-animation the WindowServer frame is scaled
        panel.becomesKeyOnlyIfNeeded = true
        GlassSurface.configure(panel, shadow: false)
        panel.title = "Pane Taskbar"

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clock.translatesAutoresizingMaskIntoConstraints = false
        clock.alignment = .right
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.textColor = .labelColor
        clock.maximumNumberOfLines = 2
        clock.onClick = { [weak self] in self?.toggleCalendar() }
        trayStack.orientation = .horizontal
        trayStack.spacing = 2
        trayStack.translatesAutoresizingMaskIntoConstraints = false
        let content = BarBackground()
        content.addSubview(stack)
        content.addSubview(trayStack)
        content.addSubview(clock)
        showDesktopButton.translatesAutoresizingMaskIntoConstraints = false
        showDesktopButton.target = self
        showDesktopButton.action = #selector(showDesktopClicked)
        content.addSubview(showDesktopButton)
        // Alignment (Windows 11: centred by default, Start first in the group): both constraints exist, one is active.
        leftAligned = stack.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        centered = stack.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        centered.priority = .defaultHigh // yields to the tray/clock when the bar is full
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trayStack.leadingAnchor, constant: -8),
            trayStack.trailingAnchor.constraint(equalTo: clock.leadingAnchor, constant: -10),
            trayStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            clock.trailingAnchor.constraint(equalTo: showDesktopButton.leadingAnchor, constant: -8),
            showDesktopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            showDesktopButton.topAnchor.constraint(equalTo: content.topAnchor),
            showDesktopButton.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            { let c = showDesktopButton.widthAnchor.constraint(equalToConstant: 10); showDesktopWidth = c; return c }(),
            clock.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        surface = GlassSurface(role: .bar, content: content)
        panel.contentView = surface
        content.onRightClick = { [weak self] in self?.showBarMenu() }
        if let make = Self.makeTray { trayProvider = make() }
        applyAlignment()
        tickClock()
        scheduleClock()
        flyoutPanel.onActivate = { [weak self] wid in
            guard let self else { return }
            TaskbarActions.activate(wid, inventory: self.inventory, history: self.history)
            self.inventory.scheduleRefresh()
        }
        flyoutPanel.onClose = { [weak self] wid in
            guard let self, let window = self.inventory.windows.first(where: { $0.id == wid }) else { return }
            TaskbarActions.close(window, inventory: self.inventory)
            self.inventory.scheduleRefresh()
        }
    }

    private var observers: [NSObjectProtocol] = []

    private var debugMonitor: Any?

    public func show() {
        if MouseTap.debug, debugMonitor == nil {
            debugMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                let hit = event.window?.contentView.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
                print("app got \(event.type == .rightMouseDown ? "rightMouseDown" : "leftMouseDown") window=\(event.window?.title ?? "nil") at \(event.locationInWindow) hit=\(hit.map { "\(type(of: $0)) '\($0.accessibilityTitle() ?? "")' \($0.frame)" } ?? "nil")")
                return event
            }
        }
        trayProvider?.barShown()
        if trayTimer == nil {
            trayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshBackground()
                    self.trayProvider?.tick()
                }
            }
        }
        pinFrame()
        updateVisibilityForSpace()
        refreshBackground()
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibilityForSpace(); self?.refreshBackground() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinFrame(); self?.refreshBackground() }
        })
        // The clock follows the system's 12/24-hour and date format settings.
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockFormatter = nil; self?.tickClock() }
        })
    }

    /// Like Windows hiding the taskbar for fullscreen apps: off on fullscreen Spaces, on everywhere else.
    /// (`canJoinAllSpaces` alone puts it on fullscreen Spaces too.)
    /// Hidden while a Windows-style full-screen window is focused (FullScreenService).
    public var suppressed = false {
        didSet { if suppressed != oldValue { updateVisibilityForSpace() } }
    }

    public func updateVisibilityForSpace() {
        if suppressed || PrivateAPI.activeSpace()?.kind == .fullscreen {
            panel.orderOut(nil)
            reportFrame()
        } else {
            pinFrame()
            panel.orderFrontRegardless()
        }
    }

    public func close() {
        clockTimer?.invalidate()
        trayTimer?.invalidate()
        trayTimer = nil
        trayProvider?.barClosed()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        panel.orderOut(nil)
        reportFrame()
    }

    @objc private func taskViewClicked(_ sender: NSButton) { onTaskView?(sender) }

    /// Keep the bar exactly screen-wide however many buttons there are (they shrink instead).
    private func pinFrame() {
        let screen = NSScreen.screens[0]
        let y = screen.frame.minY - (autoHide && !revealed ? panel.frame.height - 2 : 0)
        panel.setFrame(NSRect(x: screen.frame.minX, y: y, width: screen.frame.width, height: panel.frame.height), display: true)
        reportFrame()
    }

    // MARK: Auto-hide (setting `taskbar.autoHide`)

    /// Windows' "Automatically hide the taskbar": the bar slides down leaving a 2 pt line at the bottom edge, comes
    /// back when the pointer reaches it, and leaves again 0.6 s after the pointer does (not while one of its pop-ups or
    /// menus is open).
    public var autoHide = false {
        didSet {
            guard autoHide != oldValue else { return }
            revealed = !autoHide
            installAutoHideTracking()
            pinFrame()
        }
    }
    public private(set) var revealed = true
    private var hideWork: DispatchWorkItem?
    private var autoHideTimer: Timer?
    private var lastOverBar: Bool?

    private func installAutoHideTracking() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        guard autoHide else { return }
        // The pointer's position, 10 times a second: at the bottom edge → show; off the bar (and nothing open) → hide.
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutoHide() }
        }
    }

    private func checkAutoHide() {
        if TrayLog.enabled, lastOverBar == nil { TrayLog.write("taskbar: auto-hide watching (visible \(panel.isVisible))") }
        guard autoHide, panel.isVisible || revealed else { return }
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens[0].frame
        let overBar = p.x >= screen.minX && p.x <= screen.maxX && p.y <= screen.minY + (revealed ? panel.frame.height : 2)
        let popupOpen = flyoutPanel.isShown || ChoicePanel.shared.isShown || (trayProvider?.isPopupShown ?? false)
        if TrayLog.enabled, overBar != lastOverBar { lastOverBar = overBar; TrayLog.write("taskbar: auto-hide pointer \(Int(p.x)),\(Int(p.y)) over bar \(overBar) revealed \(revealed) visible \(panel.isVisible)") }
        if overBar || popupOpen {
            hideWork?.cancel()
            hideWork = nil
            if !revealed { slide(show: true) }
        } else if revealed, hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hideWork = nil
                    self?.slide(show: false)
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func slide(show: Bool) {
        revealed = show
        TrayLog.write("taskbar: auto-hide \(show ? "shown" : "hidden")")
        let screen = NSScreen.screens[0].frame
        let target = NSRect(x: screen.minX, y: screen.minY - (show ? 0 : panel.frame.height - 2), width: screen.width, height: panel.frame.height)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().setFrame(target, display: true)
            }
        }
        reportFrame()
    }

    /// The bar's frame in global top-left coordinates while it's on screen, nil while hidden (DockHoverShield).
    public var onBarFrame: ((CGRect?) -> Void)? { didSet { reportFrame() } }
    private func reportFrame() {
        onBarFrame?(panel.isVisible ? Geometry.cocoaToAX(panel.frame, primaryHeight: Geometry.primaryHeight) : nil)
    }

    /// Only show windows of these pids (tests, per-app bars); nil = all.
    public var includedPIDs: Set<pid_t>?

    /// Extra filter (Windows: the taskbar shows only the current virtual desktop's windows).
    public var windowFilter: ((ManagedWindow) -> Bool)?
    /// Task View button (virtual desktops); nil = no button. Title = current desktop's name.
    public var taskViewTitle: String? { didSet { if taskViewTitle != oldValue { forceRebuild = true } } }
    public var onTaskView: ((NSView) -> Void)?
    private var forceRebuild = false
    private var itemViews: [String: ItemButton] = [:]
    private lazy var startButton: NSButton = {
        // Icon only, like Windows 11 (a pane glyph: the Windows logo is a trademark).
        let start = StartPlateButton(title: "", target: self, action: #selector(startClicked))
        start.onRightClick = { [weak self] in self?.onStartRightClick?() }
        start.image = NSImage(systemSymbolName: "square.split.2x2.fill", accessibilityDescription: "Start")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        start.contentTintColor = .controlAccentColor
        start.imagePosition = .imageOnly
        start.setAccessibilityTitle("Start")
        start.size(width: 44)
        return start
    }()
    /// True while the menu-bar icons are revealed for a capture (about half a second).
    /// Also true for 0.8 s after: the menu bar is still re-laying out, which dismisses a panel opened meanwhile (measured).
    public var isCapturingIcons: Bool { trayProvider?.isCapturingIcons ?? false }

    /// The Start button (the same as a ⌘ tap). Unset: the macOS Apps panel.
    public var onStart: (() -> Void)?
    /// Right-click on Start: Windows' Quick Link menu (Win+X).
    public var onStartRightClick: (() -> Void)?
    /// The Start button on screen (AppKit coordinates): Start opens above it with left alignment.
    public var startButtonFrame: NSRect { screenFrame(of: startButton) }
    public func isPinned(_ bundleID: String) -> Bool { pinned.contains(bundleID) }
    /// Opens a menu from the Start button (Quick Link): anchored to a view, so it shows even though pane isn't the
    /// active app.
    public func popUpFromStart(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: startButton.isFlipped ? 0 : startButton.bounds.height), in: startButton)
    }

    final class StartPlateButton: PlateButton {
        var onRightClick: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    }
    @objc private func startClicked() { if let onStart { onStart() } else { AppsPanel.toggle() } }
    private lazy var taskViewButton: NSButton = {
        let taskView = PlateButton(title: "", target: self, action: #selector(taskViewClicked(_:)))
        taskView.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Task View")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        taskView.imagePosition = .imageLeading
        taskView.font = .systemFont(ofSize: 11)
        taskView.setAccessibilityIdentifier("pane.taskView")
        taskView.size(width: nil)
        return taskView
    }()
    private lazy var moreButton = ItemButton(overflow: 0) { [weak self] view, _ in self?.showOverflow(from: view) }

    /// Only these apps' windows (tests: the agent's `--taskbar-scope`, so your own windows can't push test buttons out).
    public var includedBundles: Set<String>?

    func filtered(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        var byPID = includedPIDs.map { pids in windows.filter { pids.contains($0.pid) } } ?? windows
        if let includedBundles { byPID = byPID.filter { includedBundles.contains($0.bundleID ?? "") } }
        if !hiddenBundles.isEmpty { byPID = byPID.filter { !hiddenBundles.contains($0.bundleID ?? "") } }
        return windowFilter.map { byPID.filter($0) } ?? byPID
    }

    /// Badges, progress and attention per bundle ID (DockSignals), shown on the app buttons.
    public var signals: [String: DockSignals.Signal] = [:] {
        didSet { if signals != oldValue { applySignals() } }
    }
    private func applySignals() {
        for view in stack.arrangedSubviews.compactMap({ $0 as? ItemButton }) {
            var signal = view.button?.bundleID.flatMap { signals[$0] }
            if !showBadges { signal?.badge = nil }
            if !showAttention { signal?.attention = false }
            view.signal = signal.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: Settings (taskbar.badges, .flashing, .hoverPreviews, .farCornerShowsDesktop, apps.hideFromTaskbar)

    public var showBadges = true { didSet { applySignals() } }
    public var showAttention = true { didSet { applySignals() } }
    public var showHoverPreviews = true
    public var showDesktopCorner = true {
        didSet {
            showDesktopButton.isHidden = !showDesktopCorner
            showDesktopWidth?.constant = showDesktopCorner ? 10 : 0
        }
    }
    private var showDesktopWidth: NSLayoutConstraint?
    /// Apps left off the bar (per-app "Hide from the taskbar", and apps pane leaves alone).
    public var hiddenBundles: Set<String> = [] {
        didSet { if hiddenBundles != oldValue { forceRebuild = true; update(lastWindows) } }
    }

    /// The pinned list changed from the bar's menu (save it: setting `taskbar.pinned`).
    public var onPinnedChanged: (([String]) -> Void)?
    private var lastWindows: [ManagedWindow] = []

    /// Replaces the whole pinned list (the Dock's, when "Sync pinned apps with the Dock" is turned on).
    public func replacePinned(_ list: [String]) {
        guard list != pinned else { return }
        pinned = list
        forceRebuild = true
        update(lastWindows)
    }

    /// The user's drag order of unpinned apps (this session; pinned apps keep theirs in `pinned`).
    private var appOrder: [AppKey] = []

    /// A button was dragged and dropped at `index` among the bar's app buttons: that app moves there. Pinned apps
    /// save the new order (setting `taskbar.pinned`); unpinned ones keep it for the session. Pinned apps stay first.
    func reorder(_ view: ItemButton, toSlot index: Int) {
        guard let key = view.button?.groupKey else { return }
        var keys: [AppKey] = []
        for b in stack.arrangedSubviews.compactMap({ ($0 as? ItemButton)?.button }) where !keys.contains(b.groupKey) { keys.append(b.groupKey) }
        guard let from = keys.firstIndex(of: key) else { return }
        keys.remove(at: from)
        keys.insert(key, at: max(0, min(keys.count, index > from ? index - 1 : index)))
        let newPinned = keys.map(\.raw).filter { pinned.contains($0) }
        appOrder = keys.filter { !pinned.contains($0.raw) }
        TrayLog.write("taskbar: moved \(key.raw) to slot \(index)")
        forceRebuild = true
        if newPinned != pinned {
            pinned = newPinned
            update(lastWindows)
            onPinnedChanged?(pinned)
        } else {
            update(lastWindows)
        }
    }

    /// Pins (appended at the end of the pinned apps, as Windows does) or unpins an app.
    public func setPinned(_ bundleID: String, _ pin: Bool) {
        if pin { if !pinned.contains(bundleID) { pinned.append(bundleID) } } else { pinned.removeAll { $0 == bundleID } }
        TrayLog.write("taskbar: \(pin ? "pinned" : "unpinned") \(bundleID)")
        forceRebuild = true
        update(lastWindows)
        onPinnedChanged?(pinned)
    }

    public func update(_ allWindows: [ManagedWindow]) {
        lastWindows = allWindows
        let windows = filtered(allWindows)
        items = TaskbarLayout.items(windows: windows, pinned: pinned)
        groups = TaskbarLayout.groups(windows: windows, pinned: pinned, appOrder: appOrder, history: history)
        let available = panel.frame.width - 90 - trayStack.fittingSize.width - clock.fittingSize.width - 40
        presentation = TaskbarLayout.present(groups: groups, mode: mode, availableWidth: available, previous: presentation)
        // Same buttons as before (only state changed: active, minimized, titles)? Update them in place. Rebuilding on
        // every focus change replaced buttons under the pointer and dropped clicks (measured in the grouping test).
        let existing = stack.arrangedSubviews.compactMap { $0 as? ItemButton }.filter { $0.button != nil }
        let hasOverflowButton = stack.arrangedSubviews.contains { ($0 as? ItemButton)?.button == nil && $0 is ItemButton }
        if !forceRebuild, existing.map({ $0.button!.id }) == presentation.buttons.map(\.id), hasOverflowButton == !presentation.overflow.isEmpty {
            for (view, button) in zip(existing, presentation.buttons) { view.apply(button) }
            applySignals()
            pinFrame()
            return
        }
        // Reuse button views by id (and the fixed ones): every NSButton created leaves ~14 KVO-dependency records
        // in AppKit forever on macOS 26 even after it's freed (measured: 3,000 buttons → 42,600 records), and the
        // soak rebuilt the bar thousands of times.
        forceRebuild = false
        var views: [NSView] = [startButton]
        if let taskViewTitle {
            taskViewButton.title = taskViewTitle
            views.append(taskViewButton)
        }
        var reused: [String: ItemButton] = [:]
        for button in presentation.buttons {
            let view = itemViews[button.id] ?? {
                let view = ItemButton(button: button) { [weak self] view, kind in self?.handle(kind, view) }
                view.onDrop = { [weak self] view, slot in self?.reorder(view, toSlot: slot) }
                view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return view
            }()
            view.apply(button)
            reused[button.id] = view
            views.append(view)
        }
        itemViews = reused
        if !presentation.overflow.isEmpty {
            moreButton.title = "… \(presentation.overflow.count)"
            views.append(moreButton)
        }
        stack.setViews(views, in: .leading)
        applySignals()
        pinFrame()
        // Lay out now: new buttons have no frame until the next layout pass, and a click before it hits nothing.
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    enum ClickKind { case primary, control, middle, close, menu, groupMenu, hoverStart, hoverEnd }

    private func group(_ key: AppKey) -> TaskbarGroup? { groups.first { $0.key == key } }

    private func screenFrame(of view: NSView) -> NSRect {
        panel.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func handle(_ kind: ClickKind, _ view: ItemButton) {
        guard let button = view.button else { return }
        if MouseTap.debug && kind != .hoverStart && kind != .hoverEnd { print("taskbar \(kind) on \(button.id)") }
        let window: ManagedWindow? = { if case .window(let wid) = button.kind { return inventory.windows.first { $0.id == wid } }; return nil }()
        switch kind {
        case .primary:
            if let window {
                if TaskbarActions.click(window, inventory: inventory) == .focused { history.note(window.id) }
            } else if let group = group(button.groupKey) {
                Task { @MainActor in
                    if await TaskbarActions.clickGroup(group, inventory: self.inventory) == .showFlyout {
                        if self.flyoutPanel.isShown && self.flyoutPanel.flyout?.group == group.key { self.flyoutPanel.hide() } else { self.showFlyout(group, from: view) }
                    }
                }
            }
        case .control:
            // Windows Ctrl+click: cycle through the group's windows (MRU head first, then seat order). Uses a
            // fresh window list: the bar's last snapshot can lag the real focus.
            let fresh = TaskbarLayout.groups(windows: filtered(inventory.refreshNow()), pinned: pinned, appOrder: appOrder, history: history)
            if let group = fresh.first(where: { $0.key == button.groupKey }), let wid = cycle.next(group) {
                if MouseTap.debug { print("cycle → \(wid) seats=\(group.windows.map { "\($0.id):\($0.title)\($0.isFocused ? "*" : "")" }) mru=\(group.mru)") }
                TaskbarActions.focus(wid, inventory: inventory, history: history)
            }
        case .middle:
            if let bundleID = button.bundleID { Task { await TaskbarActions.middleClick(bundleID: bundleID, pid: group(button.groupKey)?.pids.first) } }
        case .close:
            if let window { TaskbarActions.close(window, inventory: inventory) } else if let group = group(button.groupKey) {
                TaskbarActions.perform(.closeAll, on: group, inventory: inventory, history: history)
            }
        case .menu, .groupMenu:
            // A menu wins over the hover flyout (measured: the flyout opened on top of the menu and ate the click).
            hoverWork?.cancel()
            flyoutPanel.hide()
            guard let group = group(button.groupKey) else { return }
            var entries: [(String, (() -> Void)?)] = []
            // Windows' jump list: the app's recent files first, from an extension (`jumpList`).
            if let bundleID = group.bundleID ?? button.bundleID, let recent = jumpList?(bundleID), !recent.isEmpty {
                entries.append(("Recent", nil))
                entries += recent.prefix(10).map { item in (item.title, Optional(item.open)) }
            }
            entries.append((group.appName, nil))
            entries.append((group.windows.isEmpty ? "Open" : "New window", { [weak self] in self?.handle(.middle, view) }))
            if kind == .groupMenu || group.windows.count > 1 {
                for (title, command) in [("Restore all windows", TaskbarActions.GroupCommand.restoreAll), ("Minimize all windows", .minimizeAll),
                                         ("Show windows side by side", .sideBySide), ("Show windows stacked", .stacked), ("Cascade windows", .cascade)] {
                    entries.append((title, { [weak self] in
                        guard let self else { return }
                        TaskbarActions.perform(command, on: group, inventory: self.inventory, history: self.history)
                    }))
                }
            }
            // Windows: "Pin to taskbar" / "Unpin from taskbar".
            if let bundleID = group.bundleID ?? button.bundleID {
                let isPinned = pinned.contains(bundleID)
                entries.append((isPinned ? "Unpin from taskbar" : "Pin to taskbar", { [weak self] in self?.setPinned(bundleID, !isPinned) }))
            }
            if !group.windows.isEmpty {
                entries.append((group.windows.count > 1 ? "Close all windows" : "Close window", { [weak self] in self?.handle(.close, view) }))
            }
            let frame = screenFrame(of: view)
            ChoicePanel.shared.show(entries, atAX: Geometry.cocoaToAX(CGRect(x: frame.minX, y: frame.maxY + 8 + CGFloat(entries.count) * 26, width: 1, height: 1), primaryHeight: Geometry.primaryHeight).origin)
        case .hoverStart:
            TrayLog.write("taskbar: hover start \(button.id)")
            guard showHoverPreviews, case .group = button.kind, let group = group(button.groupKey), !group.windows.isEmpty else { return }
            // Already showing this app's previews: leave them (re-showing rebuilt the flyout: a blink).
            if flyoutPanel.isShown, flyoutPanel.flyout?.group == group.key { return }
            hoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard !ChoicePanel.shared.isShown else { return }
                    self?.showFlyout(group, from: view)
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        case .hoverEnd:
            // Only cancels a pending show. Hiding follows the pointer's real position (watchFlyout): the button's own
            // exit events also fire when the bar refreshes its buttons under a resting pointer, which hid the preview
            // while the pointer was still on the icon (user report: it flashed and didn't come back).
            TrayLog.write("taskbar: hover end \(button.id)")
            hoverWork?.cancel()
        }
        inventory.scheduleRefresh()
    }

    /// Hides the flyout once the pointer has been off the icon, the gap above it and the flyout for 0.4 s.
    private var flyoutWatch: Timer?
    private var flyoutAnchor = NSRect.zero
    private var pointerOutsideSince: Date?

    private func watchFlyout(anchor: NSRect) {
        flyoutAnchor = anchor
        pointerOutsideSince = nil
        flyoutWatch?.invalidate()
        flyoutWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFlyoutPointer() }
        }
    }

    private func checkFlyoutPointer() {
        guard flyoutPanel.isShown else { flyoutWatch?.invalidate(); flyoutWatch = nil; return }
        let p = NSEvent.mouseLocation
        let panelFrame = flyoutPanel.panel.frame
        let gap = NSRect(x: flyoutAnchor.minX, y: flyoutAnchor.maxY - 1, width: flyoutAnchor.width, height: max(0, panelFrame.minY - flyoutAnchor.maxY) + 2)
        let inside = flyoutAnchor.insetBy(dx: -2, dy: -2).contains(p) || gap.contains(p) || panelFrame.insetBy(dx: -2, dy: -2).contains(p)
        if inside || ChoicePanel.shared.isShown { pointerOutsideSince = nil; return }
        guard let since = pointerOutsideSince else { pointerOutsideSince = Date(); return }
        if Date().timeIntervalSince(since) >= 0.4 {
            TrayLog.write("taskbar: flyout hidden (pointer left)")
            flyoutPanel.hide()
            flyoutWatch?.invalidate()
            flyoutWatch = nil
        }
    }

    public func showFlyout(_ group: TaskbarGroup, from view: NSView) {
        TrayLog.write("taskbar: flyout shown for \(group.appName)")
        watchFlyout(anchor: screenFrame(of: view))
        let previews = WindowThumbnails.available
        let flyout = GroupFlyout.make(for: group, previewsAvailable: previews,
                                      maxThumbnails: GroupFlyout.maxThumbnails(screenWidth: NSScreen.screens[0].frame.width,
                                                                               thumbnailWidth: GroupFlyoutPanel.thumbnailWidth))
        let icon = group.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
        flyoutPanel.show(flyout, appIcon: icon, anchor: screenFrame(of: view))
    }

    /// Opens the flyout for the group at `index` (⌘N with ≥ 2 windows, and tests).
    public func showFlyout(forGroupAt index: Int) {
        guard let group = groups.first(where: { $0.index == index }),
              let view = stack.arrangedSubviews.compactMap({ $0 as? ItemButton }).first(where: { $0.button?.groupKey == group.key }) else { return }
        showFlyout(group, from: view)
    }

    private func showOverflow(from view: NSView) {
        let entries: [(String, (() -> Void)?)] = presentation.overflow.map { button in
            (button.label, { [weak self] in
                guard let self else { return }
                if case .window(let wid) = button.kind { TaskbarActions.focus(wid, inventory: self.inventory, history: self.history) }
                else if let group = self.group(button.groupKey), let wid = group.representative { TaskbarActions.focus(wid, inventory: self.inventory, history: self.history) }
            })
        }
        let frame = screenFrame(of: view)
        ChoicePanel.shared.show(entries, atAX: Geometry.cocoaToAX(CGRect(x: frame.minX, y: frame.maxY + 8 + CGFloat(entries.count) * 26, width: 1, height: 1), primaryHeight: Geometry.primaryHeight).origin)
    }

    /// Opens or closes the calendar above the clock.
    public func toggleCalendar() {
        hoverWork?.cancel()
        flyoutPanel.hide()
        calendarPanel.anchorHit = { [weak self] event in
            guard let self, event.window === self.panel else { return false }
            return self.clock.convert(self.clock.bounds, to: nil).contains(event.locationInWindow)
        }
        calendarPanel.toggle(anchor: screenFrame(of: clock))
    }

    /// The clock: clickable (the calendar), its full date on hover.
    final class ClockLabel: NSTextField {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "Clock" }
        override func accessibilityIdentifier() -> String { "taskbar.clock" }
        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    }

    /// Time over date, in the user's locale (12/24-hour as set in macOS), like Windows' two-line clock.
    private var clockFormatter: (time: DateFormatter, date: DateFormatter)?

    private func tickClock() {
        let formatters = clockFormatter ?? {
            let time = DateFormatter(), date = DateFormatter()
            time.setLocalizedDateFormatFromTemplate("jmm")
            date.dateStyle = .short
            date.timeStyle = .none
            return (time, date)
        }()
        clockFormatter = formatters
        let now = Date()
        clock.stringValue = formatters.time.string(from: now) + "\n" + formatters.date.string(from: now)
        clock.toolTip = DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none)
    }

    /// Ticks on the minute (no 15 s polling): one timer to the next minute boundary, then every 60 s.
    private func scheduleClock() {
        clockTimer?.invalidate()
        let next = ceil(Date().timeIntervalSinceReferenceDate / 60) * 60 + 0.05
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func applyAlignment() {
        guard let leftAligned, let centered else { return }
        leftAligned.isActive = alignment == .left
        centered.isActive = alignment == .center
    }

    /// Solid instead of glass (setting `appearance.material`).
    public var solidBackground = false { didSet { surface.forceSolid = solidBackground } }

    /// The wallpaper slice under the bar (cheap when nothing changed; re-captured every 10 min for dynamic wallpapers).
    private func refreshBackground() {
        guard panel.isVisible || panel.frame.width > 0 else { return }
        surface.refreshUnderlay(screenRect: panel.frame)
    }

    /// AppKit nudges windows that overlap the Dock/menu-bar areas (`constrainFrameRect`); the bar must sit
    /// exactly where it's put (Tungsten Edge does the same).
    final class BarPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The far-right sliver: invisible until hovered, then a thin line on its left (Windows 11).
    final class ShowDesktopButton: NSButton {
        private var hovering = false { didSet { needsDisplay = true } }
        init() {
            super.init(frame: .zero)
            isBordered = false
            title = ""
            setAccessibilityTitle("Show desktop")
            toolTip = "Show desktop"
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackMouse()
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func draw(_ dirtyRect: NSRect) {
            guard hovering else { return }
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height * 0.2, width: 1, height: bounds.height * 0.6).fill()
        }
    }

    /// A borderless button that draws Windows 11's backplate: hover, pressed (and `isActive` for app buttons).
    class PlateButton: NSButton {
        private(set) var isHovered = false
        var isActiveLook: Bool { false }
        private var widthConstraint: NSLayoutConstraint?

        override init(frame: NSRect) {
            super.init(frame: frame)
            isBordered = false
            bezelStyle = .regularSquare
            setButtonType(.momentaryChange)
            font = .systemFont(ofSize: 12)
            imageScaling = .scaleProportionallyDown
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 40).isActive = true
        }

        convenience init(title: String, target: AnyObject?, action: Selector?) {
            self.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Fixed width (icon-only buttons: 44 pt, Windows' 44×40 hit area), or nil for the content's width.
        func size(width: CGFloat?) {
            widthConstraint?.isActive = false
            widthConstraint = width.map { widthAnchor.constraint(equalToConstant: $0) }
            widthConstraint?.isActive = true
        }

        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            if !title.isEmpty { size.width += 20 } // label insets inside the backplate
            return size
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackMouse()
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true; hoverChanged() }
        override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true; hoverChanged() }
        func hoverChanged() {}

        override func draw(_ dirtyRect: NSRect) {
            let fill: NSColor? = isHighlighted ? .secondarySystemFill
                : isActiveLook ? (isHovered ? .secondarySystemFill : .tertiarySystemFill)
                : isHovered ? .quaternarySystemFill : nil
            if let fill {
                fill.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            drawExtras()
            super.draw(dirtyRect)
            drawOverlay()
        }
        /// Under the icon and title (backplate details, pills).
        func drawExtras() {}
        /// Over the icon (badges).
        func drawOverlay() {}
    }

    /// App / window / group button. AX title: the window title for window buttons (tests use it),
    /// "group: App (n)" for combined buttons, "pin: App" for pinned apps, "overflow" for the "…" button.
    /// Look (Windows 11): 24 pt icon in a 44×40 backplate, the label beside it when shown, and the running pill under
    /// it — 6 pt grey when the app has windows, 16 pt accent for the active one.
    final class ItemButton: PlateButton {
        private(set) var button: TaskbarButton?
        let onClick: (ItemButton, ClickKind) -> Void
        override var isActiveLook: Bool { button?.isActive == true }
        private var iconFor: String?
        /// Badge, progress, attention (Windows 11): red count on the icon, a bar under it, orange when it wants you.
        var signal: DockSignals.Signal? {
            didSet {
                guard signal != oldValue else { return }
                var parts: [String] = []
                if let badge = signal?.badge { parts.append("badge \(badge)") }
                if let progress = signal?.progress { parts.append("progress \(Int(progress * 100))%") }
                if signal?.attention == true { parts.append("needs attention") }
                setAccessibilityValue(parts.isEmpty ? nil : parts.joined(separator: "; "))
                needsDisplay = true
            }
        }

        init(button: TaskbarButton, onClick: @escaping (ItemButton, ClickKind) -> Void) {
            self.button = button
            self.onClick = onClick
            super.init(frame: .zero)
            apply(button)
            target = self
            action = #selector(primary)
        }

        /// Shows `button`'s state (also used to update in place).
        func apply(_ button: TaskbarButton) {
            self.button = button
            switch button.kind {
            case .window:
                title = String(button.label.prefix(24))
                setAccessibilityTitle(button.label)
            case .group:
                // Windows 10's stacked look, approximated: a count suffix when ≥ 2 windows.
                let count = button.windowCount > 1 ? " ×\(button.windowCount)" : ""
                title = button.showsLabel ? String(button.label.prefix(20)) + count : ""
                setAccessibilityTitle("group: \(button.label) (\(button.windowCount))")
            case .pinnedApp:
                title = ""
                setAccessibilityTitle("pin: \(button.label)")
            }
            font = .systemFont(ofSize: 12)
            if image == nil || iconFor != button.bundleID {
                // The installed app's icon, else the running app's (apps outside /Applications), else a generic app icon.
                let icon = button.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
                    ?? button.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.icon }
                    ?? NSWorkspace.shared.icon(for: .applicationBundle)
                let sized = icon.copy() as! NSImage
                sized.size = NSSize(width: 24, height: 24)
                image = sized
                iconFor = button.bundleID
            }
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            alignment = title.isEmpty ? .center : .left
            size(width: title.isEmpty ? 44 : nil)
            alphaValue = 1
            needsDisplay = true
        }

        init(overflow count: Int, onClick: @escaping (ItemButton, ClickKind) -> Void) {
            button = nil
            self.onClick = onClick
            super.init(frame: .zero)
            title = "… \(count)"
            setAccessibilityTitle("overflow")
            target = self
            action = #selector(primary)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func drawExtras() {
            guard let button else { return }
            if signal?.attention == true {
                // Windows 11: an orange backplate (and pill) until you switch to the app.
                NSColor.systemOrange.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            let running: Bool = { if case .pinnedApp = button.kind { return false }; return button.windowCount > 0 || { if case .window = button.kind { return true }; return false }() }()
            guard running else { return }
            let attention = signal?.attention == true
            let width: CGFloat = button.isActive || attention ? 16 : 6
            let y = isFlipped ? bounds.maxY - 5 : bounds.minY + 2
            let x = title.isEmpty ? bounds.midX - width / 2 : 12
            (attention ? NSColor.systemOrange : button.isActive ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }

        /// The icon's square in the button (24 pt, centred for icon-only buttons, at the left for labelled ones).
        private var iconRect: NSRect {
            let side: CGFloat = 24
            let x = title.isEmpty ? bounds.midX - side / 2 : 10
            return NSRect(x: x, y: bounds.midY - side / 2, width: side, height: side)
        }

        override func drawOverlay() { drawBadgeAndProgress() }

        private func drawBadgeAndProgress() {
            let icon = iconRect
            if let progress = signal?.progress {
                // A thin bar under the icon (Windows: the button's progress), above the pill.
                let y = isFlipped ? icon.maxY + 2 : icon.minY - 5
                let track = NSRect(x: icon.minX - 4, y: y, width: icon.width + 8, height: 3)
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                NSColor.systemGreen.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, progress)), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let badge = signal?.badge {
                // A red count at the icon's top-right corner ("•" for a badge without a number).
                let text = badge.count > 3 ? "99+" : badge
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
                let size = (text as NSString).size(withAttributes: attributes)
                let w = max(15, size.width + 8), h: CGFloat = 15
                let top = isFlipped ? icon.minY - 5 : icon.maxY + 5 - h
                let pill = NSRect(x: icon.maxX - w / 2 - 1, y: top, width: w, height: h)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
                (text as NSString).draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attributes)
            }
        }

        @objc func primary() { onClick(self, .primary) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Where a drag would drop this button (set while dragging): an index among the bar's app buttons.
        var onDrop: ((ItemButton, Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            if MouseTap.debug { print("button mouseDown flags=\(String(event.modifierFlags.rawValue, radix: 16)) clicks=\(event.clickCount)") }
            // ⌃-click: Windows' Ctrl+click (cycle the group), not a context menu.
            if event.modifierFlags.contains(.control) { onClick(self, .control); return }
            guard button != nil, let window else { super.mouseDown(with: event); return }
            // A click, or a sideways drag (> 6 pt) that moves the button to another place on the bar.
            let start = event.locationInWindow
            isHighlighted = true
            var dragging = false
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let dx = next.locationInWindow.x - start.x
                if next.type == .leftMouseDragged {
                    if !dragging, abs(dx) > 6 {
                        dragging = true
                        isHighlighted = false
                        onClick(self, .hoverEnd)
                        wantsLayer = true
                        layer?.zPosition = 10
                        alphaValue = 0.85
                    }
                    if dragging { layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0)) }
                    continue
                }
                // Mouse up.
                isHighlighted = false
                if dragging {
                    layer?.setAffineTransform(.identity)
                    layer?.zPosition = 0
                    alphaValue = 1
                    onDrop?(self, dropSlot(atX: convert(next.locationInWindow, from: nil).x + frame.minX))
                } else if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    onClick(self, .primary)
                }
                return
            }
        }

        /// The slot under `x` (in the stack's coordinates): before the first app button whose middle is right of it.
        private func dropSlot(atX x: CGFloat) -> Int {
            let apps = (superview?.subviews ?? []).compactMap { $0 as? ItemButton }.filter { $0.button != nil }.sorted { $0.frame.minX < $1.frame.minX }
            var keys: [AppKey] = []
            var mids: [(AppKey, CGFloat)] = []
            for b in apps { if let k = b.button?.groupKey, !keys.contains(k) { keys.append(k); mids.append((k, b.frame.midX)) } }
            return mids.firstIndex { $0.1 > x } ?? mids.count
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onClick(self, .middle) } else { super.otherMouseDown(with: event) }
        }

        override func rightMouseDown(with event: NSEvent) {
            if MouseTap.debug { print("button rightMouseDown flags=\(String(event.modifierFlags.rawValue, radix: 16))") }
            onClick(self, event.modifierFlags.contains(.shift) ? .groupMenu : .menu)
        }

        override func hoverChanged() { onClick(self, isHovered ? .hoverStart : .hoverEnd) }
    }
}

/// The taskbar's notification area, supplied by an extension (pane Pro's tray).
@MainActor
public protocol TaskbarTray: AnyObject {
    /// The bar hands over its tray stack (between the apps and the clock).
    func attach(_ taskbar: TaskbarPanel, stack: NSStackView)
    func detach()
    /// The bar was shown (a fresh bar sweeps every process once).
    func barShown()
    /// Every 5 s while the bar is up.
    func tick()
    /// The bar closed: never reveal the menu bar again, close pop-ups.
    func barClosed()
    /// Revealing menu-bar icons for a capture (Start and the Apps panel wait).
    var isCapturingIcons: Bool { get }
    /// One of its pop-ups is open (auto-hide keeps the bar up).
    var isPopupShown: Bool { get }
}
