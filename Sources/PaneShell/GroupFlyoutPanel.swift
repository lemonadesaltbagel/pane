// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Group flyout (harness): the windows of one taskbar group above its button — live previews from the
/// PanePreview helper when available (placeholders first, images fill in), else a title list.
/// Click = focus that window (minimize if it's the active one), middle-click or × = close it.
@MainActor
public final class GroupFlyoutPanel {
    public static let thumbnailWidth: CGFloat = 220
    public let panel: NSPanel
    public private(set) var flyout: GroupFlyout?
    public private(set) var imagesLoaded = 0
    /// Window ids whose tile shows a real preview (diagnostics/tests).
    public private(set) var previewedWIDs: [CGWindowID] = []
    public var onActivate: ((CGWindowID) -> Void)?
    public var onClose: ((CGWindowID) -> Void)?
    /// True while the pointer is over the flyout (the bar keeps a hover flyout open meanwhile).
    public private(set) var isHovered = false

    private let stack = NSStackView()
    private var monitor: Any?
    private var loadTask: Task<Void, Never>?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        // The first click must act, not just make the panel key (measured: the first click into a fresh panel was lost).
        panel.becomesKeyOnlyIfNeeded = true
        GlassSurface.configure(panel, shadow: true)
        panel.title = "Pane Group Flyout"
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let tracking = TrackingView()
        tracking.onHover = { [weak self] inside in self?.isHovered = inside }
        tracking.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            stack.topAnchor.constraint(equalTo: tracking.topAnchor),
            stack.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
        ])
        panel.contentView = GlassSurface(role: .popup, cornerRadius: 12, content: tracking)
    }

    public var isShown: Bool { panel.isVisible }

    /// `anchor` is the group button's frame in screen (Cocoa) coordinates.
    public func show(_ flyout: GroupFlyout, appIcon: NSImage?, anchor: NSRect) {
        loadTask?.cancel()
        self.flyout = flyout
        imagesLoaded = 0
        previewedWIDs = []
        stack.orientation = flyout.presentation == .thumbnails ? .horizontal : .vertical
        stack.alignment = flyout.presentation == .thumbnails ? .top : .leading
        var imageViews: [CGWindowID: NSImageView] = [:]
        let views: [NSView] = flyout.entries.map { entry in
            let view = EntryView(entry: entry, presentation: flyout.presentation, appIcon: appIcon)
            view.onActivate = { [weak self] in self?.hide(); self?.onActivate?(entry.wid) }
            view.onClose = { [weak self] in self?.onClose?(entry.wid) }
            imageViews[entry.wid] = view.imageView
            return view
        }
        stack.setViews(views, in: .leading)
        let size = stack.fittingSize
        // The bar's own display (another display's bar opens it there).
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens[0]).frame
        let x = min(max(screen.minX + 4, anchor.midX - size.width / 2), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: anchor.maxY + 8, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        guard flyout.presentation == .thumbnails, let provider = WindowThumbnails.provider else { return }
        // All previews in parallel: the flyout is up at once with placeholders and fills in together.
        loadTask = Task { [weak self] in
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for entry in flyout.entries {
                    group.addTask { (entry.wid, await provider(entry.wid, Self.thumbnailWidth * 2)) }
                }
                for await (wid, image) in group {
                    guard let image, !Task.isCancelled else { continue }
                    await MainActor.run {
                        imageViews[wid]?.image = NSImage(cgImage: image, size: .zero)
                        self?.imagesLoaded += 1
                        self?.previewedWIDs.append(wid)
                    }
                }
            }
        }
    }

    public func hide() {
        loadTask?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        isHovered = false
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackMouse()
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    final class EntryView: NSView {
        let entry: GroupFlyout.Entry
        let imageView = NSImageView()
        var onActivate: (() -> Void)?
        var onClose: (() -> Void)?

        init(entry: GroupFlyout.Entry, presentation: GroupFlyout.Presentation, appIcon: NSImage?) {
            self.entry = entry
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityTitle("flyout: \(entry.title)")
            let title = NSTextField(labelWithString: entry.title + (entry.isMinimized ? "  (minimized)" : entry.isOnOtherSpace ? "  (other desktop)" : ""))
            title.lineBreakMode = .byTruncatingTail
            title.font = entry.isActive ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
            let close = NSButton(title: "×", target: self, action: #selector(closeTapped))
            close.isBordered = false
            close.setAccessibilityTitle("close: \(entry.title)")
            imageView.image = appIcon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            for view in [imageView, title, close] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            // × keeps its size: unconstrained it stretched over most of a list row, so a click on the row closed the window.
            close.widthAnchor.constraint(equalToConstant: 20).isActive = true
            close.setContentHuggingPriority(.required, for: .horizontal)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if presentation == .thumbnails {
                let width = GroupFlyoutPanel.thumbnailWidth
                NSLayoutConstraint.activate([
                    widthAnchor.constraint(equalToConstant: width),
                    title.topAnchor.constraint(equalTo: topAnchor),
                    title.leadingAnchor.constraint(equalTo: leadingAnchor),
                    title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                    close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                    close.trailingAnchor.constraint(equalTo: trailingAnchor),
                    imageView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
                    imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    imageView.heightAnchor.constraint(equalToConstant: width * 0.62),
                    imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    widthAnchor.constraint(equalToConstant: 320),
                    heightAnchor.constraint(equalToConstant: 24),
                    imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    title.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    title.centerYAnchor.constraint(equalTo: centerYAnchor),
                    title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                    close.trailingAnchor.constraint(equalTo: trailingAnchor),
                    close.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The whole tile is one target (except ×): otherwise a click on the preview image can be delivered to the
        /// image view and never reach the tile (measured as a flaky ignored click).
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            if let hit, hit is NSButton { return hit }
            return hit == nil ? nil : self
        }

        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { onActivate?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
        override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
        @objc func closeTapped() { onClose?() }
    }
}
