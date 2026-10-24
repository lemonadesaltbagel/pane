// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Non-modal picker (harness): a list of buttons near a point. Unlike `NSMenu.popUp`, it never blocks the main
/// thread (a modal menu left open stalls signal handling and every main-queue callback). Closes on a choice,
/// a click elsewhere, or after `timeout`.
@MainActor
public final class ChoicePanel {
    public static let shared = ChoicePanel()
    private let panel: NSPanel
    private let stack = NSStackView()
    private var monitor: Any?
    private var timer: Timer?
    private var actions: [() -> Void] = []
    public private(set) var isShown = false
    /// The panel window (tests locate its buttons by AX title).
    public var window: NSWindow { panel }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        // The first click must act, not just make the panel key (measured: the first click into a fresh panel was lost).
        panel.becomesKeyOnlyIfNeeded = true
        GlassSurface.configure(panel, shadow: true)
        panel.title = "Pane Choices"
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.contentView = GlassSurface(role: .menu, cornerRadius: 10, content: stack)
    }

    /// `point` is the top-left in AX coordinates. Entries with a nil action are headers.
    public func show(_ entries: [(String, (() -> Void)?)], atAX point: CGPoint, timeout: TimeInterval = 10) {
        hide()
        actions = []
        let views: [NSView] = entries.map { title, action in
            guard let action else {
                let header = NSTextField(labelWithString: title)
                header.textColor = .secondaryLabelColor
                header.font = .systemFont(ofSize: 12, weight: .semibold)
                return header
            }
            actions.append(action)
            let button = FirstMouseButton(title: title, target: self, action: #selector(choose(_:)))
            button.tag = actions.count - 1
            button.isBordered = false
            button.alignment = .left
            button.font = .menuFont(ofSize: 13)
            button.setAccessibilityTitle(title)
            return button
        }
        stack.setViews(views, in: .top)
        let size = stack.fittingSize
        let frame = Geometry.axToCocoa(CGRect(origin: point, size: size), primaryHeight: Geometry.primaryHeight)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isShown = true
        if MouseTap.debug { print("choice panel at \(frame) entries=\(entries.map(\.0))") }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }

    public func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        isShown = false
    }

    @objc private func choose(_ sender: NSButton) {
        if MouseTap.debug { print("choice \(sender.title)") }
        let action = actions.indices.contains(sender.tag) ? actions[sender.tag] : nil
        hide()
        action?()
    }

    /// A menu row: borderless, highlighted under the pointer like a macOS menu item.
    final class FirstMouseButton: NSButton {
        private var hovering = false { didSet { needsDisplay = true } }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var intrinsicContentSize: NSSize {
            let s = super.intrinsicContentSize
            return NSSize(width: max(s.width + 20, 180), height: 24)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackMouse()
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func draw(_ dirtyRect: NSRect) {
            if hovering {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            }
            let color: NSColor = hovering ? .alternateSelectedControlTextColor : .labelColor
            let text = NSAttributedString(string: title, attributes: [.font: font ?? .menuFont(ofSize: 13), .foregroundColor: color])
            let size = text.size()
            text.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2))
        }
    }
}
