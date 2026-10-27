// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import PaneKit
import UniformTypeIdentifiers

/// Helpers for tests that change a running agent's settings (live settings, Alt+Tab, drag snapping).
public protocol LiveSettingsHarness {}

public extension LiveSettingsHarness {
    static func ready() async {
        _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
        _ = await eventually(timeout: 10) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("running (pid") }
        await settle(2.5)
    }

    /// Changes the agent's (test) config while it runs: it watches the file.
    @MainActor static func change(_ edit: (SettingsStore) -> Void) { edit(SettingsStore(url: Harness.testConfig)) }

    /// Opens Alt+Tab with ⌥ held, reads its tiles after `wait`, then cancels with Esc (the switcher has the keys).
    static func peekSwitcher(_ pane: Process, front f: Fixture, wait: Double = 1.5) async -> [String: Bool]? {
        guard await eventually(timeout: 2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }) else { return nil }
        SyntheticKeyboard.holdModifiers(.maskAlternate)
        SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
        _ = await eventually(timeout: 2) { !switcherTiles(pane.processIdentifier).isEmpty }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) // time for thumbnails to arrive (if any)
        let tiles = switcherTiles(pane.processIdentifier)
        SyntheticKeyboard.tapKey(kVK_Escape, flags: .maskAlternate)
        SyntheticKeyboard.releaseModifiers(.maskAlternate)
        return tiles
    }

    /// The Alt+Tab switcher's tiles right now (title → has a thumbnail).
    static func switcherTiles(_ pid: pid_t) -> [String: Bool] {
        guard let sw = AX.windows(of: pid).first(where: { AX.title($0) == "Pane Switcher" }) else { return [:] }
        var tiles: [String: Bool] = [:]
        func walk(_ e: AXUIElement) {
            if let t = AX.title(e), t.hasPrefix("switcher: ") { tiles[t] = (AX.get(e, kAXValueAttribute) as String?) == "preview" }
            for c in (AX.get(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c) }
        }
        walk(sw)
        return tiles
    }

    /// A drag along `path` with the button held (title-bar drags), pausing `waits[i]` after reaching point i.
    static func drag(_ path: [CGPoint], waits: [Double] = [], steps: Int = 14) async {
        guard let first = path.first else { return }
        func post(_ type: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        post(.mouseMoved, first); try? await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseDown, first); try? await Task.sleep(nanoseconds: 120_000_000)
        var current = first
        for (index, target) in path.dropFirst().enumerated() {
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: current.x + (target.x - current.x) * t, y: current.y + (target.y - current.y) * t))
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            current = target
            if index < waits.count { try? await Task.sleep(nanoseconds: UInt64(waits[index] * 1_000_000_000)) }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        post(.leftMouseUp, current)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static func titleBar(_ w: AXUIElement) -> CGPoint? { AX.frame(w).map { CGPoint(x: $0.midX, y: $0.minY + 12) } }

    static var work: CGRect { Geometry.cocoaToAX(NSScreen.screens[0].visibleFrame, primaryHeight: Geometry.primaryHeight) }
}

/// Window previews need the capture helper or Screen Recording.
public enum PreviewGate {
    public static var enabled: Bool {
        if Capture.hasScreenRecording { return true }
        if PreviewClient.helperStatus().permitted { return true }
        // Try starting an installed helper once.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { _ = await PreviewClient.launchHelper(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
        return PreviewClient.helperStatus().permitted
    }

    public static let directory: URL = {
        // The package being tested (scripts/test.sh runs from its root; this library may be a dependency's checkout).
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("test-results/previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static func save(_ image: CGImage, _ name: String) -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return url
    }

    /// Distinct colors in a coarse sample — a blank/black capture has ~1.
    public static func colorVariety(_ image: CGImage) -> Int {
        let size = 32
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt32.self, capacity: size * size)
        return Set((0..<(size * size)).map { pixels[$0] >> 4 & 0x0F0F0F0F }).count
    }
}
