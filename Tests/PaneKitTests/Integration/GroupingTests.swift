// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// Windows "combine taskbar buttons" end to end: one group button for an app's windows, the flyout with live
    /// previews (helper), ⌃-click cycling, ⇧-right-click group commands, hover. The flyout is captured to
    /// test-results/previews/group-flyout.png for checking by eye.
    @Suite("Taskbar grouping")
    struct GroupingTests {
        @Test func groupButtonFlyoutCycleAndCommands() async throws {
            FixtureBundle.killStrays()
            // A window that stays on the desktop (different bundle not needed: it only anchors the Space).
            let anchor = try await Fixture.launch(label: "Anchor", windows: ["Desk"], frame: CGRect(x: 900, y: 500, width: 300, height: 200))
            defer { anchor.quit() }
            let anchorWID = try #require(anchor.wid("Desk"))
            let f = try await Fixture.launch(label: "G", windows: ["A", "B", "C"])
            defer { f.quit() }
            let inventory = WindowInventory()
            let history = FocusHistory()
            let bar = await MainActor.run { TaskbarPanel(inventory: inventory, height: 48, history: history, mode: .always) }
            await MainActor.run {
                bar.includedPIDs = [f.pid] // the anchor fixture shares the bundle; keep the group to G's 3 windows
                inventory.onChange = { windows in MainActor.assumeIsolated { history.update(windows); bar.update(windows) } }
                inventory.start()
                bar.show()
            }
            defer { Task { @MainActor in bar.close(); inventory.stop() } }
            defer { SyntheticKeyboard.releaseAllModifiers() }
            let groupTitle = "group: PaneFixture (3)"
            let grouped = await eventually(timeout: 4) { MainActor.assumeIsolatedOrSync { Harness.center(of: groupTitle, in: bar.panel) != nil } }
            try #require(grouped, "no combined button for the fixture's 3 windows")
            let buttonsForApp = await MainActor.run { bar.presentation.buttons.filter { $0.groupKey.raw == FixtureBundle.bundleID }.count }

            // Click → flyout with 3 entries and previews.
            let groupPoint = try #require(await MainActor.run { Harness.center(of: groupTitle, in: bar.panel) })
            SyntheticMouse.click(at: groupPoint)
            let flyoutShown = await eventually { MainActor.assumeIsolatedOrSync { bar.flyoutPanel.isShown && bar.flyoutPanel.flyout?.entries.count == 3 } }
            let presentation = await MainActor.run { bar.flyoutPanel.flyout?.presentation }
            let previewLatency = await timeUntil(timeout: 4) { MainActor.assumeIsolatedOrSync { bar.flyoutPanel.imagesLoaded == 3 } }
            let previewsLoaded = previewLatency != nil
            await settle(0.3)
            let previewed = await MainActor.run { bar.flyoutPanel.previewedWIDs }
            Report.record("Grouping · previewed tiles", "\(previewed) of \(await MainActor.run { bar.flyoutPanel.flyout?.entries.map(\.wid) ?? [] })")
            let flyoutWID = CGWindowID(await MainActor.run { bar.flyoutPanel.panel.windowNumber })
            if let (image, _) = await PreviewClient.thumbnail(flyoutWID, maxDimension: 1000) { _ = PreviewGate.save(image, "group-flyout") }
            var tileVariety: [String: Int] = [:]
            for name in ["A", "B", "C"] {
                if let wid = f.wid(name), let (image, _) = await PreviewClient.thumbnail(wid, maxDimension: 440) {
                    _ = PreviewGate.save(image, "group-\(name)")
                    tileVariety[name] = PreviewGate.colorVariety(image)
                }
            }
            Report.record("Grouping · tile previews", "\(tileVariety)")

            // Click entry B → B focused.
            let entryB = try #require(await MainActor.run { Harness.center(of: "flyout: G B", in: bar.flyoutPanel.panel) })
            SyntheticMouse.click(at: entryB)
            let focusedB = await eventually { AX.focusedWindow(of: f.pid).flatMap(AX.title) == "G B" }

            // ⌃-click → cycle: B is active and most recent, so C, then A, then B (seat order).
            await settle(0.4) // let the app switch from the entry click finish (a click mid-switch can be dropped)
            var cycled: [String] = []
            for _ in 0..<3 {
                let point = try #require(await MainActor.run { Harness.center(of: groupTitle, in: bar.panel) })
                let before = AX.focusedWindow(of: f.pid).flatMap(AX.title)
                SyntheticMouse.click(at: point, modifiers: .maskControl)
                // Every step moves focus; wait for it rather than reading at a fixed delay.
                _ = await eventually(timeout: 1.5) { AX.focusedWindow(of: f.pid).flatMap(AX.title) != before }
                await settle(0.15)
                cycled.append(AX.focusedWindow(of: f.pid).flatMap(AX.title) ?? "?")
            }

            // ⇧-right-click → group menu → Minimize all, then Restore all.
            func groupCommand(_ title: String) async throws {
                let point = try #require(await MainActor.run { Harness.center(of: groupTitle, in: bar.panel) })
                SyntheticMouse.rightClick(at: point, modifiers: .maskShift)
                let menuShown = await eventually { MainActor.assumeIsolatedOrSync { ChoicePanel.shared.isShown } }
                if !menuShown {
                    let barWID = CGWindowID(await MainActor.run { bar.panel.windowNumber })
                    let barWindow = WindowServer.windows(onScreenOnly: false).first { $0.id == barWID }
                    let top = WindowServer.windows().first { $0.bounds.contains(point) && $0.layer >= 0 }
                    Report.record("Grouping · lost menu click", "\(title): point \(point); bar onscreen=\(barWindow?.isOnScreen ?? false) bounds=\(barWindow?.bounds ?? .zero); space=\(PrivateAPI.activeSpace().map { "\($0.kind)" } ?? "?"); topmost at point=\(top.map { "\($0.ownerName ?? "?") layer \($0.layer) \($0.bounds)" } ?? "none"); frontmost=\(AX.frontmostPID().flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?")")
                }
                await settle(0.2) // let the WindowServer place the panel before clicking into it
                let choice = try #require(await MainActor.run { Harness.center(of: title, in: ChoicePanelAccess.window) })
                SyntheticMouse.click(at: choice)
            }
            try await groupCommand("Minimize all windows")
            // (Minimized windows report subrole AXDialog, so check every AX window, not just standard ones.)
            let allMinimized = await eventually(timeout: 6) { let all = AX.windows(of: f.pid); return all.count == 3 && all.allSatisfy(AX.isMinimized) }
            try await groupCommand("Restore all windows")
            let allRestored = await eventually(timeout: 6) { let all = AX.windows(of: f.pid); return all.count == 3 && !all.contains(where: AX.isMinimized) }

            // Hover → flyout after ~0.4 s.
            await MainActor.run { bar.flyoutPanel.hide() }
            let hoverPoint = try #require(await MainActor.run { Harness.center(of: groupTitle, in: bar.panel) })
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: hoverPoint.x, y: hoverPoint.y - 200), mouseButton: .left)?.post(tap: .cghidEventTap)
            await settle(0.2)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: hoverPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            let hoverLatency = await timeUntil(timeout: 2) { MainActor.assumeIsolatedOrSync { bar.flyoutPanel.isShown } }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: hoverPoint.x, y: hoverPoint.y - 400), mouseButton: .left)?.post(tap: .cghidEventTap)
            await MainActor.run { bar.flyoutPanel.hide() }

            Report.record("Grouping", "buttons for 3 windows=\(buttonsForApp); click→flyout=\(flyoutShown) (\(presentation.map { "\($0)" } ?? "-")), previews loaded=\(previewsLoaded) in \(previewLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "-"); entry B→focused=\(focusedB); ⌃-click cycle=\(cycled); minimize all=\(allMinimized), restore all=\(allRestored); hover→flyout in \(hoverLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "never")")
            #expect(buttonsForApp == 1)
            // Thumbnails come from an extension (pane Pro's live previews); without one the flyout is a list of titles.
            let thumbnails = await MainActor.run { WindowThumbnails.provider != nil }
            #expect(flyoutShown && presentation == (thumbnails ? .thumbnails : .list))
            #expect(previewsLoaded || !thumbnails)
            #expect(focusedB)
            #expect(cycled == ["G C", "G A", "G B"])
            #expect(allMinimized && allRestored)
            #expect(hoverLatency != nil)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty, "synthesized input left a modifier held system-wide")
        }
    }
}
