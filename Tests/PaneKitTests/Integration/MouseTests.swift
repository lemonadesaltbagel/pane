// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 4, mouse side: title-bar double-click, green button and drag-to-edge, driven by synthesized
    /// HID events. First records what macOS does natively, then checks pane's MouseTap overrides.
    /// Moves the real cursor.
    @Suite("4b · Mouse: double-click, green button, drag snap")
    struct MouseTests {
        static func titleBarPoint(_ window: AXUIElement) throws -> CGPoint {
            let frame = try #require(AX.frame(window))
            return CGPoint(x: frame.midX, y: frame.minY + 12)
        }

        static func greenButtonPoint(_ window: AXUIElement) throws -> CGPoint {
            let button = try #require(AX.button(window, kAXFullScreenButtonAttribute))
            let frame = try #require(AX.frame(button))
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        static func describe(_ r: CGRect?) -> String {
            guard let r else { return "-" }
            return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        }

        @Test func nativeBaseline() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))

            SyntheticMouse.doubleClick(at: try Self.titleBarPoint(window))
            await settle(1.0)
            let afterDoubleClick = AX.frame(window)
            Report.record("4b Mouse · native title-bar double-click", "\(Self.describe(original)) → \(Self.describe(afterDoubleClick)) (work area \(Self.describe(work)))")
            AX.setFrame(window, original)
            await settle(0.5)

            SyntheticMouse.drag(from: try Self.titleBarPoint(window), to: CGPoint(x: work.minX, y: work.midY), hold: 0.8)
            await settle(1.2)
            let afterDrag = AX.frame(window)
            let tiled = afterDrag.map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work), tolerance: 12) } ?? false
            Report.record("4b Mouse · native drag to left edge", "→ \(Self.describe(afterDrag)); looks like macOS edge tiling=\(tiled)")
            AX.setFrame(window, original)
            await settle(0.5)

            let desktop = PrivateAPI.activeSpace()?.id
            SyntheticMouse.click(at: try Self.greenButtonPoint(window))
            let wentFullscreen = await eventually(timeout: 3) { PrivateAPI.activeSpace()?.id != desktop }
            Report.record("4b Mouse · native green button", "entered a fullscreen Space=\(wentFullscreen)")
            if wentFullscreen {
                AX.set(window, "AXFullScreen", kCFBooleanFalse)
                _ = await eventually(timeout: 4) { PrivateAPI.activeSpace()?.id == desktop }
                await settle(1.0)
            }
        }

        @Test func paneOverridesDoubleClickGreenButtonAndDrag() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A"), wid = try #require(f.wid("A"))
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))

            let lock = NSLock()
            var store = PlacementStore()
            var handled: [String] = []
            var preMaximize: CGRect?
            let tap = try MouseTap()
            defer { tap.stop() }
            let apply: (String, AXUIElement, (inout PlacementStore, CGRect) -> CGRect?) -> Void = { name, target, decide in
                guard let current = AX.frame(target), let frame = lock.withLock({ decide(&store, current) }) else { return }
                lock.withLock { if preMaximize == nil { preMaximize = current } }
                AX.setFrame(target, frame)
                lock.withLock { handled.append("\(name)[\(Self.describe(current))→\(Self.describe(frame))]") }
            }
            tap.onTitleBarDoubleClick = { target in apply("doubleClick", target) { $0.toggleMaximize(wid, currentFrame: $1, workArea: work) } }
            tap.onGreenButton = { target in apply("greenButton", target) { $0.toggleMaximize(wid, currentFrame: $1, workArea: work) } }
            tap.onDragEnded = { target, point in
                apply("drag", target) { store, current in
                    SnapZones.zone(for: point, in: Geometry.cocoaToAX(NSScreen.screens[0].frame, primaryHeight: Geometry.primaryHeight))
                        .map { store.snap(wid, currentFrame: current, to: $0, workArea: work) }
                }
            }

            // Double-click → maximize; again → exact restore.
            SyntheticMouse.doubleClick(at: try Self.titleBarPoint(window))
            let maximized = await eventually(timeout: 2) { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
            await settle(0.4)
            SyntheticMouse.doubleClick(at: try Self.titleBarPoint(window))
            let expected = lock.withLock { preMaximize } ?? original
            let restored = await eventually(timeout: 2) { AX.frame(window).map { Geometry.approximatelyEqual($0, expected) } ?? false }
            Report.record("4b Mouse · pane double-click", "maximized=\(maximized) restored-exactly=\(restored) pre-maximize=\(Self.describe(expected)) now=\(Self.describe(AX.frame(window))) handlers=\(lock.withLock { handled })")
            #expect(maximized)
            #expect(restored)
            await settle(0.4)

            // Green button → maximize, no fullscreen Space.
            let desktop = PrivateAPI.activeSpace()?.id
            SyntheticMouse.click(at: try Self.greenButtonPoint(window))
            let greenMaximized = await eventually(timeout: 2) { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
            await settle(1.0)
            let stayedOnDesktop = PrivateAPI.activeSpace()?.id == desktop
            Report.record("4b Mouse · pane green button", "maximized=\(greenMaximized) stayed out of fullscreen=\(stayedOnDesktop)")
            #expect(greenMaximized)
            #expect(stayedOnDesktop)
            AX.setFrame(window, original)
            lock.withLock { store.forget(wid) }
            await settle(0.5)

            // Drag to the left edge → left half (macOS edge tiling may also act on the same drag).
            SyntheticMouse.drag(from: try Self.titleBarPoint(window), to: CGPoint(x: work.minX, y: work.midY), hold: 0.1)
            let left = Geometry.rect(for: .leftHalf, in: work)
            let snapped = await eventually(timeout: 2) { AX.frame(window).map { Geometry.approximatelyEqual($0, left) } ?? false }
            await settle(1.0)
            let final = AX.frame(window)
            Report.record("4b Mouse · pane drag snap", "snapped to left half=\(snapped); final \(Self.describe(final)); handlers=\(lock.withLock { handled })")
            #expect(snapped)
        }
    }
}
