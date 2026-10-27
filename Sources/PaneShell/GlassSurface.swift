// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// The background of pane's surfaces: Liquid Glass on macOS 26, a behind-window blur on
/// 14–25, an opaque fill under Reduce Transparency / Increase Contrast. The content goes *inside* the glass
/// (`contentView`), never beside it, so AppKit keeps text and icons legible on it.
///
/// `.bar` adds a wallpaper underlay: pane keeps the real Dock under the taskbar to reserve its space, so a see-through
/// bar would show the Dock's icons. The underlay paints the wallpaper slice that is under the bar, and the glass sits on
/// that: the bar shows the wallpaper the way the macOS 26 menu bar does.
@MainActor
public final class GlassSurface: NSView {
    public enum Role { case bar, popup, menu, switcher }

    public let role: Role
    public let content: NSView
    public var cornerRadius: CGFloat { didSet { rebuild() } }
    /// Always opaque (setting `appearance.material` = solid), as with Reduce Transparency.
    public var forceSolid = false { didSet { if forceSolid != oldValue { rebuild() } } }
    private let underlay = WallpaperUnderlay()
    private var background: NSView?
    private var observers: [NSObjectProtocol] = []

    public init(role: Role, cornerRadius: CGFloat = 0, content: NSView) {
        self.role = role
        self.cornerRadius = cornerRadius
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        if role == .bar {
            underlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underlay)
            pin(underlay)
        }
        rebuild()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
    }

    /// Makes `panel` see-through so the surface (and what's behind it) shows; call once per panel.
    public static func configure(_ panel: NSPanel, shadow: Bool) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        // A non-opaque window lets the mouse through its transparent pixels (and glass is transparent in the window's
        // own pixels: WindowServer draws it). Setting this to false explicitly makes the whole frame take the mouse.
        // Without it the real Dock under the taskbar saw the pointer and drew its app labels over the bar (measured).
        panel.ignoresMouseEvents = false
    }

    /// Re-renders the wallpaper slice (Space, screen or wallpaper changed). `.bar` only.
    public func refreshUnderlay(screenRect: CGRect) { underlay.refresh(screenRect: screenRect) }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private func pin(_ view: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuild() {
        content.removeFromSuperview()
        background?.removeFromSuperview()
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
        layer?.borderWidth = 0
        let view: NSView
        if Self.reduceTransparency || forceSolid {
            // Opaque: what macOS does to the menu bar and Dock with Reduce Transparency on.
            let solid = SolidView()
            solid.addSubview(content)
            view = solid
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                layer?.borderWidth = 1
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        } else if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            view = glass
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = role == .bar ? .withinWindow : .behindWindow // the bar blurs its own wallpaper underlay
            blur.state = .active // pane's panels are never key
            blur.material = switch role {
            case .bar, .menu: .menu
            case .popup: .popover
            case .switcher: .hudWindow
            }
            blur.addSubview(content)
            view = blur
        }
        if content.isDescendant(of: view) {
            // Fill the container (glass hosts its contentView in its own subview: pinning to the glass still works).
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.topAnchor.constraint(equalTo: view.topAnchor), content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        pin(view)
        background = view
        underlay.isHidden = Self.reduceTransparency || forceSolid
    }

    /// The window background colour, re-resolved for light/dark.
    final class SolidView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}

/// Paints the part of the desktop picture that lies under a screen rect: the real wallpaper captured through pane's
/// preview helper when it's running (exact, including dynamic wallpapers), else the wallpaper file laid out the way
/// the desktop shows it (fill, fit, stretch, center).
@MainActor
final class WallpaperUnderlay: NSView {
    private var slice: CGImage?
    private var renderedFor: (url: URL?, rect: CGRect, space: UInt64?, at: Date)?
    private var task: Task<Void, Never>?

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = slice
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor // until the slice is ready
    }

    func refresh(screenRect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(screenRect) }) ?? NSScreen.screens.first else { return }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let space = PrivateAPI.activeSpace()?.id
        // Same wallpaper, place and Space: keep it (re-captured every 10 min: dynamic wallpapers change through the day).
        if let done = renderedFor, done.url == url, done.rect == screenRect, done.space == space, slice != nil,
           Date().timeIntervalSince(done.at) < 600 { return }
        task?.cancel()
        task = Task { [weak self] in
            let image = await Self.capturedSlice(screen: screen, rect: screenRect) ?? Self.fileSlice(screen: screen, rect: screenRect, url: url)
            guard let self, !Task.isCancelled else { return }
            self.slice = image
            self.renderedFor = (url, screenRect, space, Date())
            self.needsDisplay = true
            self.updateLayer()
        }
    }

    /// The desktop-picture window (Dock-owned, desktop level, screen-sized), captured by the helper.
    static func capturedSlice(screen: NSScreen, rect: CGRect) async -> CGImage? {
        guard PreviewClient.isAvailable else { return nil }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let screenAX = Geometry.cocoaToAX(screen.frame, primaryHeight: Geometry.primaryHeight)
        guard let window = WindowServer.windows(onScreenOnly: true).first(where: {
            $0.layer == desktopLevel && abs($0.bounds.width - screenAX.width) < 2 && abs($0.bounds.height - screenAX.height) < 2
                && abs($0.bounds.minX - screenAX.minX) < 2 && abs($0.bounds.minY - screenAX.minY) < 2
        }) else { return nil }
        guard let (image, _) = await PreviewClient.thumbnail(window.id, maxDimension: max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor) else { return nil }
        return crop(image, full: screen.frame, to: rect)
    }

    /// The wallpaper file, laid out like the desktop (desktopImageOptions), cropped to `rect`.
    static func fileSlice(screen: NSScreen, rect: CGRect, url: URL?) -> CGImage? {
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (options[.fillColor] as? NSColor) ?? .black
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        let source = image.size
        var drawn = CGRect(origin: .zero, size: size)
        switch scaling {
        case .scaleAxesIndependently: break
        case .scaleNone:
            drawn = CGRect(x: (size.width - source.width) / 2, y: (size.height - source.height) / 2, width: source.width, height: source.height)
        default:
            let k = clipping ? max(size.width / source.width, size.height / source.height) : min(size.width / source.width, size.height / source.height)
            let w = source.width * k, h = source.height * k
            drawn = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
        // Only the slice: render the full layout into a bitmap the size of `rect`, shifted.
        let local = CGRect(x: rect.minX - screen.frame.minX, y: rect.minY - screen.frame.minY, width: rect.width, height: rect.height)
        let pixels = NSSize(width: local.width * scale, height: local.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = local.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSRect(origin: .zero, size: local.size).fill()
        image.draw(in: drawn.offsetBy(dx: -local.minX, dy: -local.minY), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Crops a capture of the whole screen (top-left origin image) to a Cocoa-coordinates rect on that screen.
    static func crop(_ image: CGImage, full: CGRect, to rect: CGRect) -> CGImage? {
        let kx = CGFloat(image.width) / full.width, ky = CGFloat(image.height) / full.height
        let local = CGRect(x: rect.minX - full.minX, y: full.maxY - rect.maxY, width: rect.width, height: rect.height) // flip to top-left
        return image.cropping(to: CGRect(x: local.minX * kx, y: local.minY * ky, width: local.width * kx, height: local.height * ky).integral)
    }
}

extension NSView {
    /// Hover tracking: one area over the view's visible rect, added once (`.inVisibleRect` keeps it current as the
    /// view resizes or scrolls).
    public func trackMouse(_ extra: NSTrackingArea.Options = []) {
        guard trackingAreas.isEmpty else { return }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options.union(extra), owner: self, userInfo: nil))
    }
}

/// Menu items that run a closure: the closure rides in `representedObject`, one shared target runs it.
public final class ClosureMenuTarget: NSObject {
    static let shared = ClosureMenuTarget()
    final class Box { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
    @objc func runClosure(_ sender: NSMenuItem) { (sender.representedObject as? Box)?.run() }

    public static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runClosure(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = Box(run)
        return item
    }
}

/// Window thumbnails (pane Pro's live previews). Without a provider, Alt+Tab, the taskbar's hover pop-up and Task View
/// show app icons and titles.
public enum WindowThumbnails {
    nonisolated(unsafe) public static var provider: (@Sendable (CGWindowID, CGFloat) async -> CGImage?)?
    /// Thumbnails can be had now (a provider, and the capture helper is permitted).
    public static var available: Bool { provider != nil && PreviewClient.isAvailable }
}
