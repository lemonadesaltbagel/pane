// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Windows 11 Alt+Tab: a centred glass panel of window tiles (app icon and title over a live thumbnail), flowing into
/// rows, the selected tile ringed in the accent colour. Hovering a tile selects it, clicking switches to it.
///
/// Thumbnails come from the preview helper (Screen Recording lives there). Until a window's thumbnail arrives the tile
/// shows the app's icon; the last thumbnail of each window is kept, so the panel is complete at once the next time.
@MainActor
public final class SwitcherPanel {
    private let panel: NSPanel
    private let content = FlippedView()
    private var tiles: [Tile] = []
    private var loadTask: Task<Void, Never>?
    /// Last thumbnail per window (shown instantly next time, refreshed on every show).
    private var cache: [CGWindowID: NSImage] = [:]

    /// Mouse: the pointer moved onto tile `index` / clicked it.
    public var onHover: ((Int) -> Void)?
    public var onChoose: ((Int) -> Void)?
    /// Where the pointer was when the panel opened: hovering selects only once it has moved (a panel opening under a
    /// resting pointer must not take the selection away from the keyboard).
    private var pointerAtShow = NSPoint.zero

    public static let thumbHeight: CGFloat = 132
    public static let headerHeight: CGFloat = 26
    public static let tilePadding: CGFloat = 8
    static let spacing: CGFloat = 8
    static let margin: CGFloat = 14
    static let maxTiles = 30

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        // The first click must act, not just make the panel key (measured: the first click into a fresh panel was lost).
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Pane Switcher"
        GlassSurface.configure(panel, shadow: true)
        panel.contentView = GlassSurface(role: .switcher, cornerRadius: 16, content: content)
    }

    /// Off (the default without a thumbnail provider) shows the app icon in every tile and fetches no thumbnails.
    public var showsPreviews = true
    public var isShown: Bool { panel.isVisible }
    /// Tiles whose thumbnail has arrived (tests).
    public var thumbnailsShown: Int { tiles.filter(\.hasThumbnail).count }
    public var tileCount: Int { tiles.count }
    public var window: NSWindow { panel }

    public func show(_ items: [ManagedWindow], selected: Int) {
        loadTask?.cancel()
        tiles.forEach { $0.removeFromSuperview() }
        pointerAtShow = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let maxRowWidth = screen.visibleFrame.width * 0.86
        let shown = Array(items.prefix(Self.maxTiles))
        tiles = shown.enumerated().map { index, item in
            let tile = Tile(item: item, index: index, thumbnail: showsPreviews ? cache[item.id] : nil)
            tile.onHover = { [weak self] index in
                guard let self, hypot(NSEvent.mouseLocation.x - self.pointerAtShow.x, NSEvent.mouseLocation.y - self.pointerAtShow.y) > 3 else { return }
                self.onHover?(index)
            }
            tile.onClick = { [weak self] in self?.onChoose?($0) }
            return tile
        }
        // Flow layout: rows as wide as fit, each row centred.
        var rows: [[Tile]] = [[]]
        var rowWidth: CGFloat = 0
        for tile in tiles {
            let w = tile.size.width
            if !rows[rows.count - 1].isEmpty, rowWidth + Self.spacing + w > maxRowWidth { rows.append([]); rowWidth = 0 }
            rowWidth += (rows[rows.count - 1].isEmpty ? 0 : Self.spacing) + w
            rows[rows.count - 1].append(tile)
        }
        let rowWidths = rows.map { $0.map(\.size.width).reduce(0, +) + Self.spacing * CGFloat(max(0, $0.count - 1)) }
        let width = (rowWidths.max() ?? 200) + Self.margin * 2
        let rowHeight = Tile.height
        let height = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * Self.spacing + Self.margin * 2
        var y = Self.margin
        for (r, row) in rows.enumerated() {
            var x = (width - rowWidths[r]) / 2
            for tile in row {
                tile.frame = NSRect(x: x, y: y, width: tile.size.width, height: rowHeight)
                content.addSubview(tile)
                x += tile.size.width + Self.spacing
            }
            y += rowHeight + Self.spacing
        }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral, display: true)
        select(selected)
        panel.orderFrontRegardless()
        loadThumbnails(shown.map(\.id))
    }

    public func select(_ index: Int) {
        for tile in tiles { tile.isSelected = tile.index == index }
    }

    public func hide() {
        loadTask?.cancel()
        panel.orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
    }

    /// All thumbnails in parallel; each lands in its tile (and the cache) as it arrives.
    private func loadThumbnails(_ wids: [CGWindowID]) {
        guard showsPreviews, WindowThumbnails.available, let provider = WindowThumbnails.provider else { return }
        if cache.count > 200 { let alive = Set(wids); cache = cache.filter { alive.contains($0.key) } }
        loadTask = Task { [weak self] in
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for wid in wids {
                    group.addTask { (wid, await provider(wid, 480)) }
                }
                for await (wid, image) in group {
                    guard let image, !Task.isCancelled else { continue }
                    await MainActor.run {
                        guard let self else { return }
                        let picture = NSImage(cgImage: image, size: .zero)
                        self.cache[wid] = picture
                        self.tiles.first { $0.item.id == wid }?.setThumbnail(picture)
                    }
                }
            }
        }
    }

    public final class FlippedView: NSView {
        public override var isFlipped: Bool { true }
    }

    /// One window: app icon and title, then the thumbnail (or the app icon until it arrives). Shared with Task View,
    /// which adds a × on hover (`onClose`) and dragging the tile onto a desktop (`onDragEnd`, screen point).
    public final class Tile: NSView {
        public let item: ManagedWindow
        public let index: Int
        public let size: NSSize
        public var onHover: ((Int) -> Void)?
        public var onClick: ((Int) -> Void)?
        public var onClose: ((Int) -> Void)?
        public var onDragEnd: ((Int, NSPoint) -> Void)?
        public var onDragMove: ((NSPoint) -> Void)?
        private let picture = NSImageView()
        private let placeholder = NSImageView()
        public private(set) var hasThumbnail = false
        public var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
        private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

        public static var height: CGFloat { SwitcherPanel.headerHeight + SwitcherPanel.thumbHeight + SwitcherPanel.tilePadding * 2 }
        public override var isFlipped: Bool { true }

        public let thumbHeight: CGFloat
        public var tileHeight: CGFloat { SwitcherPanel.headerHeight + thumbHeight + SwitcherPanel.tilePadding * 2 }

        public init(item: ManagedWindow, index: Int, thumbnail: NSImage?, thumbHeight: CGFloat = SwitcherPanel.thumbHeight, maxWidth: CGFloat = 300) {
            self.item = item
            self.index = index
            self.thumbHeight = thumbHeight
            // Tiles share a height; widths follow the window's shape (Windows does the same).
            let aspect = item.frame.height > 0 ? item.frame.width / item.frame.height : 1.5
            let thumbWidth = min(max(thumbHeight * aspect, thumbHeight * 0.9), maxWidth)
            size = NSSize(width: thumbWidth + SwitcherPanel.tilePadding * 2, height: SwitcherPanel.headerHeight + thumbHeight + SwitcherPanel.tilePadding * 2)
            super.init(frame: NSRect(origin: .zero, size: size))
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityTitle("switcher: \(item.title)")

            let pad = SwitcherPanel.tilePadding
            let appIcon = Tile.icon(for: item)
            let icon = NSImageView(frame: NSRect(x: pad, y: pad + 3, width: 18, height: 18))
            icon.image = appIcon
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            let title = NSTextField(labelWithString: item.title.isEmpty ? item.appName : item.title)
            title.font = .systemFont(ofSize: 12)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: pad + 24, y: pad + 3, width: size.width - pad * 2 - 24, height: 18)
            addSubview(title)

            let thumbFrame = NSRect(x: pad, y: pad + SwitcherPanel.headerHeight, width: thumbWidth, height: thumbHeight)
            placeholder.frame = thumbFrame.insetBy(dx: thumbWidth / 2 - 32, dy: thumbHeight / 2 - 32)
            placeholder.image = appIcon
            placeholder.imageScaling = .scaleProportionallyUpOrDown
            addSubview(placeholder)
            picture.frame = thumbFrame
            picture.imageScaling = .scaleProportionallyDown
            picture.wantsLayer = true
            picture.layer?.cornerRadius = 6
            picture.layer?.masksToBounds = true
            addSubview(picture)
            if let thumbnail { setThumbnail(thumbnail) }
            if item.isMinimized { picture.alphaValue = 0.75 }
        }

        public required init?(coder: NSCoder) { fatalError() }

        /// App icons, looked up once per app (Task View and Alt+Tab build many tiles).
        nonisolated(unsafe) private static var icons: [String: NSImage] = [:]
        public static func icon(for item: ManagedWindow) -> NSImage {
            let key = item.bundleID ?? "pid:\(item.pid)"
            if let cached = icons[key] { return cached }
            let icon = item.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
            icons[key] = icon
            return icon
        }

        public func setThumbnail(_ image: NSImage) {
            picture.image = image
            placeholder.isHidden = true
            hasThumbnail = true
            setAccessibilityValue("preview")
        }

        public override func draw(_ dirtyRect: NSRect) {
            let plate = bounds.insetBy(dx: 1, dy: 1)
            if isSelected {
                NSColor.tertiarySystemFill.setFill()
                NSBezierPath(roundedRect: plate, xRadius: 10, yRadius: 10).fill()
                let ring = NSBezierPath(roundedRect: plate.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            } else if hovering {
                NSColor.quaternarySystemFill.setFill()
                NSBezierPath(roundedRect: plate, xRadius: 10, yRadius: 10).fill()
            }
            if hovering, onClose != nil {
                NSColor.systemRed.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: closeRect, xRadius: 6, yRadius: 6).fill()
                let mark = NSBezierPath()
                let r = closeRect.insetBy(dx: 7, dy: 7)
                mark.move(to: NSPoint(x: r.minX, y: r.minY)); mark.line(to: NSPoint(x: r.maxX, y: r.maxY))
                mark.move(to: NSPoint(x: r.maxX, y: r.minY)); mark.line(to: NSPoint(x: r.minX, y: r.maxY))
                mark.lineWidth = 1.5
                NSColor.white.setStroke()
                mark.stroke()
            }
        }

        /// The × (Task View), top right, shown on hover.
        public var closeRect: NSRect { NSRect(x: bounds.maxX - 30, y: 6, width: 22, height: 22) }


        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackMouse([.mouseMoved])
        }
        public override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(index) }
        public override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?(index) } }
        public override func mouseExited(with event: NSEvent) { hovering = false }
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        public override func mouseDown(with event: NSEvent) {
            let start = convert(event.locationInWindow, from: nil)
            if onClose != nil, closeRect.contains(start) { onClose?(index); return }
            guard onDragEnd != nil, let window else { onClick?(index); return }
            // A click, or a drag (> 6 pt) that carries the window to a desktop tile.
            var dragging = false
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let p = convert(next.locationInWindow, from: nil)
                let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
                if next.type == .leftMouseDragged {
                    if !dragging, hypot(d.x, d.y) > 6 {
                        dragging = true
                        wantsLayer = true
                        layer?.zPosition = 10
                        alphaValue = 0.8
                    }
                    if dragging {
                        layer?.setAffineTransform(CGAffineTransform(translationX: d.x, y: d.y))
                        onDragMove?(window.convertPoint(toScreen: next.locationInWindow))
                    }
                    continue
                }
                if dragging {
                    layer?.setAffineTransform(.identity)
                    layer?.zPosition = 0
                    alphaValue = 1
                    onDragEnd?(index, window.convertPoint(toScreen: next.locationInWindow))
                } else {
                    onClick?(index)
                }
                return
            }
        }
    }
}
