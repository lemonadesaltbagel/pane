// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// M1 services as pane runs them.
    @Suite("M1 · Services")
    struct ServiceTests {
        @Test func snapServiceDragPreviewUnsnapAndArrows() async throws {
            // As pane runs: native edge tiling off (decision 4), restored afterwards.
            TestSystemSettings.recoverIfNeeded()
            let settings = SystemSettings(backupURL: TestSystemSettings.url)
            try settings.apply(NativeTakeover.changes)
            defer { settings.restore() }
            let f = try await Fixture.launch(label: "S", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            let original = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: original))
            let service = SnapService()
            let lock = NSLock()
            var previews: [CGRect?] = []
            service.onPreview = { rect in lock.withLock { previews.append(rect) } }
            try service.start()
            defer { service.stop() }

            // Drag to the left edge: a left-half preview appears while dragging, the snap applies on release.
            SyntheticMouse.drag(from: try MouseTests.titleBarPoint(window), to: CGPoint(x: work.minX, y: work.midY), hold: 0.2)
            let left = Geometry.rect(for: .leftHalf, in: work)
            let snapped = await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, left) } ?? false }
            let sawPreview = lock.withLock { previews.contains { $0.map { Geometry.approximatelyEqual($0, left) } ?? false } }
            let clearedPreview = await eventually { lock.withLock { previews.last.map { $0 == nil } ?? false } }

            // Drag the snapped window to the middle: its free size comes back (Windows unsnap-on-drag).
            let midTarget = CGPoint(x: work.midX, y: work.midY)
            SyntheticMouse.drag(from: try MouseTests.titleBarPoint(window), to: midTarget, hold: 0.2)
            await settle(0.5)
            let unsnapped = try #require(AX.frame(window))
            let sizeBack = abs(unsnapped.width - original.width) <= 2 && abs(unsnapped.height - original.height) <= 2
            Report.record("M1 Services · drag", "snapped=\(snapped) preview=\(sawPreview) previewCleared=\(clearedPreview); drag snapped window → size restored=\(sizeBack) (\(Int(unsnapped.width))x\(Int(unsnapped.height)))")
            #expect(snapped)
            #expect(sawPreview)
            #expect(clearedPreview)
            #expect(sizeBack)

            // Win+Arrow sequence through the service API: left, up (top-left), down (left), right (restore).
            let free = try #require(AX.frame(window))
            service.arrow(.left, on: window); await settle(0.2)
            let a = AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false
            service.arrow(.up, on: window); await settle(0.2)
            let b = AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .topLeft, in: work)) } ?? false
            service.arrow(.down, on: window); await settle(0.2)
            let c = AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false
            service.arrow(.right, on: window); await settle(0.2)
            let d = AX.frame(window).map { Geometry.approximatelyEqual($0, free) } ?? false
            Report.record("M1 Services · Win+Arrow sequence", "left=\(a) up→topLeft=\(b) down→left=\(c) right→restore=\(d)")
            #expect(a && b && c && d)
        }

        @Test func hotkeyServiceWinArrowWhenEnabled() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            Focus.focus(window, using: .skyLight)
            let start = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: start))
            let snap = SnapService()
            var options = HotkeyService.Options()
            options.winArrows = true
            let hotkeys = HotkeyService(options: options, snap: snap)
            try hotkeys.start()
            defer { hotkeys.stop(); SyntheticKeyboard.releaseAllModifiers() }
            SyntheticKeyboard.press(kVK_LeftArrow, .maskCommand)
            let ok = await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false }
            Report.record("M1 Services · ⌘← via HotkeyService", "left half=\(ok)")
            #expect(ok)
        }

        /// The Mac chords are on by default: ⌃⌥← snaps left with no options set, and ⌘← stays text navigation.
        @Test func hotkeyServiceMacChordsByDefault() async throws {
            let f = try await Fixture.launch(label: "H", windows: ["A"])
            defer { f.quit() }
            let window = try f.requireWindow("A")
            Focus.focus(window, using: .skyLight)
            let start = try #require(AX.frame(window))
            let work = try #require(Geometry.workArea(for: start))
            let hotkeys = HotkeyService(options: HotkeyService.Options(), snap: SnapService())
            try hotkeys.start()
            defer { hotkeys.stop(); SyntheticKeyboard.releaseAllModifiers() }
            SyntheticKeyboard.press(kVK_LeftArrow, .maskCommand)
            let commandLeftIgnored = !(await eventually(timeout: 0.8) { AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false })
            SyntheticKeyboard.press(kVK_LeftArrow, [.maskControl, .maskAlternate])
            let snapped = await eventually { AX.frame(window).map { Geometry.approximatelyEqual($0, Geometry.rect(for: .leftHalf, in: work)) } ?? false }
            Report.record("M1 Services · ⌃⌥← by default", "⌘← left alone \(commandLeftIgnored); ⌃⌥← left half \(snapped)")
            #expect(commandLeftIgnored && snapped)
        }

        /// Win+Shift+S: no chord in the Mac keyboard; a chord you set calls the screenshot handler (the real tool is
        /// faked in tests).
        @Test func screenshotShortcut() async throws {
            #expect(HotkeyService.Options().binding(.screenshot) == nil)
            let fake = FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-screenshot-\(UUID().uuidString).txt")
            setenv("PANE_FAKE_SCREENSHOT", fake.path, 1)
            defer { unsetenv("PANE_FAKE_SCREENSHOT"); try? FileManager.default.removeItem(at: fake) }
            let f = try await Fixture.launch(label: "Sc", windows: ["A"])
            defer { f.quit() }
            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            var options = HotkeyService.Options()
            options.bindings[.screenshot] = KeyBinding([.ctrl, .cmd, .shift], "s")
            let hotkeys = HotkeyService(options: options, snap: nil)
            hotkeys.onScreenshot = { _ = Screenshot.perform() }
            try hotkeys.start()
            defer { hotkeys.stop(); SyntheticKeyboard.releaseAllModifiers() }
            _ = await eventually { NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid }
            SyntheticKeyboard.press(kVK_ANSI_S, [.maskControl, .maskCommand, .maskShift])
            let taken = await eventually(timeout: 2) { ((try? String(contentsOf: fake, encoding: .utf8)) ?? "") == "screenshot\n" }
            Report.record("M1 Services · Win+Shift+S", "handler called with a chord set \(taken)")
            #expect(taken)
        }

        @Test func lifecycleServiceQuitsOnLastCloseButRespectsOptOutAndHide() async throws {
            let inventory = WindowInventory()
            let service = LifecycleService()
            service.scope = [FixtureBundle.bundleID] // never touch real apps from tests
            service.debounce = 0.5
            let lock = NSLock()
            var decisions: [(pid_t, LifecyclePolicy.Decision)] = []
            service.onDecision = { pid, _, decision in lock.withLock { decisions.append((pid, decision)) } }
            inventory.onChange = { service.inventoryChanged($0) }
            await MainActor.run { inventory.start() }
            defer { inventory.stop() }

            // 1. Last window closed → quit.
            let quitter = try await Fixture.launch(label: "Q", windows: ["A"])
            defer { quitter.quit() }
            _ = await eventually { inventory.windows.contains { $0.pid == quitter.pid } }
            try quitter.close("A")
            let quitLatency = await timeUntil(timeout: 5) { quitter.app.isTerminated }

            // 2. Hidden with ⌘H → kept.
            let hidden = try await Fixture.launch(label: "Hd", windows: ["A"])
            defer { hidden.quit() }
            _ = await eventually { inventory.windows.contains { $0.pid == hidden.pid } }
            hidden.app.hide()
            await settle(2.5)
            let hiddenAlive = !hidden.app.isTerminated

            // 3. Opted out → kept.
            service.optOut = [FixtureBundle.bundleID]
            let kept = try await Fixture.launch(label: "O", windows: ["A"])
            defer { kept.quit() }
            _ = await eventually { inventory.windows.contains { $0.pid == kept.pid } }
            try kept.close("A")
            await settle(2.5)
            let optOutAlive = !kept.app.isTerminated

            let log = lock.withLock { decisions.map { "\($0.0 == quitter.pid ? "Q" : $0.0 == hidden.pid ? "Hd" : $0.0 == kept.pid ? "O" : "?"):\($0.1)" } }
            Report.record("M1 Services · lifecycle", "quit after last close in \(quitLatency.map { String(format: "%.1f s", $0) } ?? "never"); hidden kept=\(hiddenAlive); opt-out kept=\(optOutAlive); decisions=\(log)")
            #expect(quitLatency != nil)
            #expect(hiddenAlive)
            #expect(optOutAlive)
        }
    }
}
