// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit

/// Minimal drag-snap preview (harness): a translucent, click-through rectangle where the window will land.
@MainActor
public final class SnapPreviewOverlay {
    private let window: NSWindow

    public init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        window.contentView = view
    }

    /// `rect` in AX coordinates; nil hides the preview.
    public func show(_ rect: CGRect?) {
        guard let rect else { window.orderOut(nil); return }
        window.setFrame(Geometry.axToCocoa(rect.insetBy(dx: 6, dy: 6), primaryHeight: Geometry.primaryHeight), display: true)
        window.orderFrontRegardless()
    }
}
