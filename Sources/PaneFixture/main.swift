// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

// A deterministic AppKit app for integration tests. Tests launch it (wrapped in a .app bundle so
// LaunchServices treats it like a real app) and drive it only through AX / WindowServer, the same way pane
// would drive any third-party app.
//
//   PaneFixture --label F --windows A,B,C [--panel] [--frame x,y,w,h] [--tabs] [--status-item] [--status-action] [--status-dynamic] [--status-popover] [--status-panel] [--counter]
//
// Windows are titled "<label> <name>"; the panel is "<label> Palette". --frame is in AX coordinates
// (top-left origin) for the first window; later windows cascade by 30pt. Native tabbing is off unless
// --tabs is given (then every window joins one tab group), so system tab preferences can't change results.

struct Options {
    var label = "Fixture"
    var windows = ["A"]
    var panel = false
    var tabs = false
    var statusItem = false
    var statusAction = false
    var statusToggle = false
    var statusDynamic = false
    var statusPopover = false
    var statusPanel = false
    var counter = false
    var frame = CGRect(x: 200, y: 200, width: 600, height: 400)
    /// Dock-tile badge text (taskbar badge tests).
    var badge: String?
    /// Request the user's attention (critical) this many seconds after launch, once it's in the background.
    var attentionAfter: Double?
    /// An editable text view in each window (keyboard remap tests).
    var text = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--label": label = iterator.next() ?? label
            case "--windows": windows = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--panel": panel = true
            case "--tabs": tabs = true
            case "--status-item": statusItem = true
            case "--status-action": statusAction = true
            case "--status-toggle": statusToggle = true
            case "--status-dynamic": statusDynamic = true
            case "--status-popover": statusPopover = true
            case "--status-panel": statusPanel = true
            case "--counter": counter = true
            case "--badge": badge = iterator.next()
            case "--attention": attentionAfter = Double(iterator.next() ?? "") ?? 2
            case "--text": text = true
            case "--frame":
                let parts = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 { frame = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
            default: break
            }
        }
    }
}

/// Logs deallocation so tests/probes can tell "closed and freed" from "closed but kept alive".
final class FixtureWindow: NSWindow {
    deinit { FileHandle.standardError.write("PaneFixture: deallocated \(title)\n".data(using: .utf8)!) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ClickArea: NSView {
    var onClick: (() -> Void)?
    var onDrag: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseDragged(with event: NSEvent) { onDrag?() }
    override func draw(_ dirtyRect: NSRect) { NSColor.systemBlue.withAlphaComponent(0.2).setFill(); bounds.fill() }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let options = Options(CommandLine.arguments)
    /// Strong refs only while open, so a closed window is deallocated like a document window would be.
    var windows: [NSWindow] = []
    var panel: NSPanel?
    var created = 0
    var statusItem: NSStatusItem?
    var extraItems: [NSStatusItem] = []
    var popover: NSPopover?
    var customPanel: NSPanel?
    // Click-through experiment state (read through AX from the counter label).
    var clicks = 0, firstMouseClicks = 0, areaClicks = 0, areaDrags = 0
    var counterLabel: NSTextField?
    var scrollLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        if let badge = options.badge { NSApp.dockTile.badgeLabel = badge }
        if let delay = options.attentionAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = NSApp.requestUserAttention(.criticalRequest) }
        }
        // Control by file (tests): a badge written to /tmp/pane-fixture-<label>.badge is shown within half a second.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let url = URL(fileURLWithPath: "/tmp/pane-fixture-\(self.options.label).badge")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSApp.dockTile.badgeLabel = label.isEmpty ? nil : label
            try? FileManager.default.removeItem(at: url)
        }
        // Every fixture shares this defaults domain, so a position saved by one run (an icon dragged onto the bar) would
        // put the next run's icons there too: start each launch with new items (they appear at the far left).
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem ") { defaults.removeObject(forKey: key) }
        if options.statusItem {
            // A tray icon (menu-bar extra) with a menu, for the tray tests.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "PF"
            item.button?.setAccessibilityTitle("\(options.label) Tray")
            let menu = NSMenu()
            menu.addItem(withTitle: "Tray New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
            item.menu = menu
            statusItem = item
        }
        if options.statusDynamic {
            // A menu built only when it opens (menuNeedsUpdate), like apps whose menus show live data.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "PD"
            item.button?.setAccessibilityTitle("\(options.label) Dynamic")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            extraItems.append(item)
        }
        if options.statusPopover {
            // An NSPopover anchored to the status button (BetterDisplay-style).
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "PP"
            item.button?.setAccessibilityTitle("\(options.label) Popover")
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            extraItems.append(item)
        }
        if options.statusPanel {
            // A custom panel the app positions itself from the button's window frame.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "PN"
            item.button?.setAccessibilityTitle("\(options.label) Panel")
            item.button?.target = self
            item.button?.action = #selector(togglePanel(_:))
            extraItems.append(item)
        }
        if options.statusAction {
            // A tray icon with no menu, only an action (like popover apps): opens a "Tray Popover" window.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "PA"
            item.button?.setAccessibilityTitle("\(options.label) Action")
            item.button?.target = self
            item.button?.action = #selector(trayAction(_:))
            statusItem = item
        }
        if options.statusToggle {
            // A toggle icon (keep-awake / mute style): its action flips its own glyph and opens nothing. A tray that
            // follows an AXPress with a click would flip it twice. "toggles" counts flips (for tests).
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "○"
            item.button?.setAccessibilityTitle("\(options.label) Toggle")
            item.button?.target = self
            item.button?.action = #selector(toggleAction(_:))
            toggleItem = item
        }
        for name in options.windows { openWindow(named: name) }
        if options.panel {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 260),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "\(options.label) Palette"
            panel.isFloatingPanel = true
            panel.setFrameTopLeftPoint(cocoaPoint(axX: options.frame.maxX + 20, axY: options.frame.minY))
            panel.orderFront(nil)
            self.panel = panel
        }
    }

    /// Dynamic status menu: items exist only once the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Dynamic \(Date().timeIntervalSince1970.rounded())", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Dynamic New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
    }

    // Mac default, stated explicitly: the app does NOT quit on its own when its last window closes.
    // That's the behavior pane has to override from the outside.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let controller = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
        let label = NSTextField(labelWithString: "\(options.label) popover content")
        label.frame = NSRect(x: 12, y: 50, width: 200, height: 24)
        let button = NSButton(title: "Popover New Window", target: self, action: #selector(newWindow(_:)))
        button.frame = NSRect(x: 12, y: 12, width: 190, height: 28)
        content.addSubview(label)
        content.addSubview(button)
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        self.popover = popover
    }

    @objc func togglePanel(_ sender: NSStatusBarButton) {
        if let customPanel, customPanel.isVisible { customPanel.orderOut(nil); return }
        let panel = customPanel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        panel.title = "\(options.label) Custom Panel"
        // Position from the status button's window, as such apps do.
        if let frame = sender.window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.minY - 4))
        }
        panel.orderFrontRegardless()
        customPanel = panel
    }

    @objc func countClick(_ sender: Any?) {
        clicks += 1
        updateCounter()
    }

    @objc func countFirstMouseClick(_ sender: Any?) {
        firstMouseClicks += 1
        updateCounter()
    }

    func updateCounter() {
        counterLabel?.stringValue = "clicks=\(clicks) firstMouse=\(firstMouseClicks) area=\(areaClicks) drags=\(areaDrags)"
        counterLabel?.setAccessibilityValue(counterLabel?.stringValue)
    }

    @objc func trayAction(_ sender: Any?) {
        openWindow(named: "Tray Popover")
    }

    var toggleItem: NSStatusItem?
    var toggles = 0
    @objc func toggleAction(_ sender: Any?) {
        toggles += 1
        toggleItem?.button?.title = toggles % 2 == 1 ? "●" : "○"
        toggleItem?.button?.setAccessibilityValue("toggles \(toggles)")
    }

    @objc func newWindow(_ sender: Any?) {
        created += 1
        openWindow(named: "New \(created)")
    }

    private func openWindow(named name: String) {
        let offset = CGFloat(windows.count) * 30
        let window = FixtureWindow(contentRect: NSRect(origin: .zero, size: options.frame.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = options.tabs ? .preferred : .disallowed
        window.tabbingIdentifier = "pane.fixture"
        // Disallowing tabbing also drops AppKit's automatic full-screen capability (the green button then
        // zooms instead); real document apps have it, so set it explicitly.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "\(options.label) \(name)"
        window.setFrameTopLeftPoint(cocoaPoint(axX: options.frame.minX + offset, axY: options.frame.minY + offset))
        let field = NSTextField(labelWithString: window.title)
        field.font = .systemFont(ofSize: 28, weight: .semibold)
        field.frame = NSRect(x: 20, y: 20, width: options.frame.width - 40, height: 40)
        window.contentView?.addSubview(field)
        if options.text {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 20, y: 70, width: options.frame.width - 40, height: max(60, options.frame.height - 130))
            if let view = scroll.documentView as? NSTextView {
                view.string = "first line of text\nsecond line of text"
                view.setAccessibilityIdentifier("fixture.text")
            }
            window.contentView?.addSubview(scroll)
            window.initialFirstResponder = scroll.documentView
        }
        if options.counter { addCounter(to: window) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
            self?.windows.removeAll { $0 === note.object as? NSWindow }
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Click-through experiment: a normal button (AppKit default: no first mouse), a first-mouse button, a
    /// counter label, and a scroll view whose offset is reported.
    private func addCounter(to window: NSWindow) {
        guard let content = window.contentView else { return }
        let normal = NSButton(title: "Press me", target: self, action: #selector(countClick(_:)))
        normal.frame = NSRect(x: 20, y: 300, width: 140, height: 32)
        let first = FirstMouseButton(title: "Press me (first mouse)", target: self, action: #selector(countFirstMouseClick(_:)))
        first.frame = NSRect(x: 180, y: 300, width: 220, height: 32)
        let label = NSTextField(labelWithString: "clicks=0 firstMouse=0")
        label.frame = NSRect(x: 20, y: 270, width: 360, height: 22)
        label.setAccessibilityIdentifier("counter")
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 360, height: 180))
        scroll.hasVerticalScroller = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 340, height: 3000))
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        let scrollLabel = NSTextField(labelWithString: "scrollY=0")
        scrollLabel.frame = NSRect(x: 400, y: 270, width: 200, height: 22)
        scrollLabel.setAccessibilityIdentifier("scroll")
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
            scrollLabel.stringValue = "scrollY=\(Int(scroll.contentView.bounds.minY))"
            scrollLabel.setAccessibilityValue(scrollLabel.stringValue)
        }
        // A plain custom view: AppKit's default acceptsFirstMouse (NO), like most content views.
        let area = ClickArea(frame: NSRect(x: 420, y: 70, width: 180, height: 180))
        area.onClick = { [weak self] in self?.areaClicks += 1; self?.updateCounter() }
        area.onDrag = { [weak self] in self?.areaDrags += 1; self?.updateCounter() }
        area.setAccessibilityElement(true)
        area.setAccessibilityRole(.group)
        area.setAccessibilityTitle("Click area")
        for view in [normal, first, label, scroll, scrollLabel, area] { content.addSubview(view) }
        counterLabel = label
        self.scrollLabel = scrollLabel
        updateCounter()
    }

    private func cocoaPoint(axX: CGFloat, axY: CGFloat) -> NSPoint {
        NSPoint(x: axX, y: (NSScreen.screens.first?.frame.height ?? 0) - axY)
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "PaneFixture")
        appItem.submenu?.addItem(withTitle: "Quit PaneFixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
