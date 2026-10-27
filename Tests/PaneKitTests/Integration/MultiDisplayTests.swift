// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Multiple displays, Windows 11's way (research/plan-multi-display.md), with a virtual second display: a taskbar on
    /// it, maximize and snaps in its work area, windows moved between displays, which bar lists what, and the bar going
    /// when the display does.
    @Suite("Multiple displays")
    struct MultiDisplayTests: AgentHarness, LiveSettingsHarness {
        static func bar(_ pid: pid_t, on display: CGDirectDisplayID) -> AXUIElement? {
            AX.windows(of: pid).first { AX.title($0) == "Pane Taskbar \(display)" }
        }

        static func secondDisplayID() -> CGDirectDisplayID? { NSScreen.screens.dropFirst().first?.displayID }

        static func describe(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-" }

        @Test func taskbarWorkAreaAndMoves() async throws {
            let f = try await Fixture.launch(label: "M", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 600, height: 400))
            defer { f.quit() }
            let pane = try Self.launchAgent()
            defer { stopAgent(pane) }
            await Self.agentReady()
            let pid = pane.processIdentifier
            var notes: [String] = []
            try await SecondDisplay.with { second in
                let id = try #require(Self.secondDisplayID())
                // D4: a bar on the second display, at its bottom, with Start, the clock and show desktop, no tray.
                let appeared = await eventually(timeout: 5) { Self.bar(pid, on: id) != nil }
                let bar = try #require(Self.bar(pid, on: id), "no taskbar on the second display")
                let barFrame = try #require(AX.frame(bar))
                let atBottom = Geometry.approximatelyEqual(CGRect(x: second.minX, y: second.maxY - barFrame.height, width: second.width, height: barFrame.height), barFrame)
                let titles = Harness.taskbarButtons(pid, bar: "Pane Taskbar \(id)").map(\.0)
                let parts = titles.contains("Start") && SettingsUI.element(bar, "taskbar.clock") != nil && titles.contains("Show desktop") && !titles.contains("tray overflow")
                notes.append("D4 bar on the second display \(appeared) at its bottom \(atBottom) (\(Self.describe(barFrame))), Start, clock, show desktop and no tray \(parts)")
                #expect(appeared && atBottom && parts)

                // D1: maximize there stops above its bar and below its menu bar.
                let window = try f.requireWindow("A")
                AX.setFrame(window, CGRect(x: second.minX + 100, y: second.minY + 120, width: 600, height: 400))
                Focus.focus(window, using: .skyLight)
                _ = await eventually { AX.frontmostPID() == f.pid }
                await settle(0.5)
                let screen = try #require(NSScreen.screens.first { $0.displayID == id })
                let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
                let work = CGRect(x: second.minX, y: second.minY + menuBar, width: second.width, height: second.height - menuBar - barFrame.height)
                SyntheticKeyboard.press(kVK_UpArrow, [.maskControl, .maskAlternate])
                let maximized = await eventually(timeout: 3) { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
                notes.append("D1 maximized on the second display \(maximized) (\(Self.describe(AX.frame(window))), want \(Self.describe(work)))")
                #expect(maximized)

                // D3: ⌃⌥⌘← moves it to the main display, still maximized; ⌃⌥⌘→ brings it back.
                let mainWork = try #require(Geometry.workArea(for: CGRect(x: 10, y: 100, width: 10, height: 10)))
                SyntheticKeyboard.press(kVK_LeftArrow, [.maskControl, .maskAlternate, .maskCommand])
                let onMain = await eventually(timeout: 3) { AX.frame(window).map { Geometry.approximatelyEqual($0, mainWork) } ?? false }
                SyntheticKeyboard.press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand])
                let back = await eventually(timeout: 3) { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
                // A free window keeps its size.
                SyntheticKeyboard.press(kVK_DownArrow, [.maskControl, .maskAlternate]) // restore
                _ = await eventually(timeout: 3) { AX.frame(window).map { $0.width < work.width } ?? false }
                let free = AX.frame(window)
                SyntheticKeyboard.press(kVK_LeftArrow, [.maskControl, .maskAlternate, .maskCommand])
                let movedFree = await eventually(timeout: 3) {
                    guard let now = AX.frame(window), let free else { return false }
                    return now.maxX <= mainWork.maxX + 1 && abs(now.width - free.width) < 2
                }
                notes.append("D3 to the main display maximized \(onMain), back \(back); a free window moved keeping its size \(movedFree) (\(Self.describe(free)) → \(Self.describe(AX.frame(window))))")
                #expect(onMain && back && movedFree)

                // D5: "Taskbar where window is open": the window's button only on its display's bar.
                func listed(_ title: String) -> Bool { Harness.taskbarButtons(pid, bar: title).contains { $0.0.contains("PaneFixture") || $0.0.hasPrefix("M ") } }
                await MainActor.run { Self.change { try? $0.set(PaneSettings.multiDisplayApps, "own") } }
                let ownMain = await eventually(timeout: 3) { listed("Pane Taskbar") && !listed("Pane Taskbar \(id)") }
                SyntheticKeyboard.press(kVK_RightArrow, [.maskControl, .maskAlternate, .maskCommand])
                let ownSecond = await eventually(timeout: 3) { !listed("Pane Taskbar") && listed("Pane Taskbar \(id)") }
                await MainActor.run { Self.change { try? $0.set(PaneSettings.multiDisplayApps, "all") } }
                let all = await eventually(timeout: 3) { listed("Pane Taskbar") && listed("Pane Taskbar \(id)") }
                notes.append("D5 own: only the main bar while it's there \(ownMain), only the second's after moving \(ownSecond); all: both \(all)")
                #expect(ownMain && ownSecond && all)

                // D4: switched off, the second bar goes; on again, it's back.
                await MainActor.run { Self.change { try? $0.set(PaneSettings.allDisplays, false) } }
                let gone = await eventually(timeout: 3) { Self.bar(pid, on: id) == nil }
                await MainActor.run { Self.change { try? $0.set(PaneSettings.allDisplays, true) } }
                let again = await eventually(timeout: 3) { Self.bar(pid, on: id) != nil }
                notes.append("D4 setting off: bar gone \(gone); on: back \(again)")
                #expect(gone && again)
            }
            // D7: the display went: its bar goes, the window is on the main display.
            let barGone = await eventually(timeout: 5) { !AX.windows(of: pid).contains { (AX.title($0) ?? "").hasPrefix("Pane Taskbar ") } }
            let mainFrame = Geometry.screenFramesAX[0]
            let windowBack = await eventually(timeout: 5) { f.window("A").flatMap(AX.frame).map { mainFrame.intersects($0) } ?? false }
            notes.append("D7 display removed: its bar gone \(barGone), the window on the main display \(windowBack) (\(Self.describe(f.window("A").flatMap(AX.frame))))")
            #expect(barGone && windowBack)
            let note = notes.joined(separator: "; ")
            Report.record("Multiple displays · taskbar, work area, moves", note)
            print("MULTI-DISPLAY: " + note)
        }

        /// D2, D6, D7: drag snapping at the outer edge but not the shared one; Start and the calendar open from the
        /// second bar on its display; a window maximized there is still maximized, on the main display, once it's gone.
        @Test func dragPopupsAndUnplug() async throws {
            let f = try await Fixture.launch(label: "N", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 600, height: 400))
            defer { f.quit() }
            let pane = try Self.launchAgent()
            defer { stopAgent(pane) }
            await Self.agentReady()
            let pid = pane.processIdentifier
            var notes: [String] = []
            try await SecondDisplay.with { second in
                let id = try #require(Self.secondDisplayID())
                _ = await eventually(timeout: 5) { Self.bar(pid, on: id) != nil }
                let bar = try #require(Self.bar(pid, on: id))
                let barHeight = AX.frame(bar)?.height ?? 48
                let screen = try #require(NSScreen.screens.first { $0.displayID == id })
                let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
                let work = CGRect(x: second.minX, y: second.minY + menuBar, width: second.width, height: second.height - menuBar - barHeight)
                let window = try f.requireWindow("A")
                AX.setFrame(window, CGRect(x: second.minX + 300, y: second.minY + 200, width: 600, height: 400))
                Focus.focus(window, using: .skyLight)
                await settle(0.6)

                // D2: the outer (right) edge snaps the right half; the shared (left) edge doesn't snap.
                func titleBar() -> CGPoint? { AX.frame(window).map { CGPoint(x: $0.midX, y: $0.minY + 12) } }
                let right = Geometry.rect(for: .rightHalf, in: work)
                if let start = titleBar() { SyntheticMouse.drag(from: start, to: CGPoint(x: second.maxX - 2, y: second.midY), hold: 0.8) }
                let snappedRight = await eventually(timeout: 3) { AX.frame(window).map { Geometry.approximatelyEqual($0, right) } ?? false }
                SyntheticKeyboard.press(kVK_DownArrow, [.maskControl, .maskAlternate]) // restore
                await settle(0.6)
                let left = Geometry.rect(for: .leftHalf, in: work)
                if let start = titleBar() { SyntheticMouse.drag(from: start, to: CGPoint(x: second.minX + 2, y: second.midY), hold: 0.8) }
                await settle(1.0)
                let notSnapped = AX.frame(window).map { !Geometry.approximatelyEqual($0, left) } ?? false
                notes.append("D2 outer edge snapped the right half \(snappedRight); the shared edge left it unsnapped \(notSnapped) (\(Self.describe(AX.frame(window))))")
                #expect(snappedRight && notSnapped)

                // D6: Start and the calendar from the second bar open on its display.
                let buttons = Harness.taskbarButtons(pid, bar: "Pane Taskbar \(id)")
                if let start = buttons.first(where: { $0.0 == "Start" }) { SyntheticMouse.click(at: start.1) }
                let startShown = await eventually(timeout: 3) { StartUI.window(pid) != nil }
                let startOnSecond = StartUI.window(pid).flatMap(AX.frame).map { second.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
                _ = AgentLink.send("start:hide")
                _ = await eventually(timeout: 2) { StartUI.window(pid) == nil }
                var calendarOnSecond = false
                if let clock = SettingsUI.element(bar, "taskbar.clock") {
                    AX.perform(clock, kAXPressAction)
                    _ = await eventually(timeout: 3) { AX.windows(of: pid).contains { AX.title($0) == "Pane Calendar" } }
                    calendarOnSecond = AX.windows(of: pid).first { AX.title($0) == "Pane Calendar" }.flatMap(AX.frame).map { second.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
                    AX.perform(clock, kAXPressAction)
                }
                notes.append("D6 Start from the second bar shown \(startShown) on its display \(startOnSecond); the calendar on its display \(calendarOnSecond)")
                #expect(startShown && startOnSecond && calendarOnSecond)

                // Maximized on the second display when it goes.
                AX.setFrame(window, CGRect(x: second.minX + 300, y: second.minY + 200, width: 600, height: 400))
                Focus.focus(window, using: .skyLight)
                await settle(0.5)
                SyntheticKeyboard.press(kVK_UpArrow, [.maskControl, .maskAlternate])
                _ = await eventually(timeout: 3) { AX.frame(window).map { Geometry.approximatelyEqual($0, work) } ?? false }
            }
            // D7: on the main display, still maximized.
            let mainWork = try #require(Geometry.workArea(for: CGRect(x: 10, y: 100, width: 10, height: 10)))
            let maximizedOnMain = await eventually(timeout: 5) { f.window("A").flatMap(AX.frame).map { Geometry.approximatelyEqual($0, mainWork) } ?? false }
            notes.append("D7 maximized on the second display when it went: maximized on the main one \(maximizedOnMain) (\(Self.describe(f.window("A").flatMap(AX.frame))))")
            #expect(maximizedOnMain)
            let note = notes.joined(separator: "; ")
            Report.record("Multiple displays · drag, pop-ups, unplug", note)
            print("MULTI-DISPLAY-2: " + note)
        }

        /// D8: the pointer held at the second display's bottom edge doesn't take the Dock (and with it the main display's
        /// reserved space) there.
        @Test(arguments: [true, false]) func dockStaysOnTheMainDisplay(barOnEveryDisplay: Bool) async throws {
            let pane = try Self.launchAgent { try? $0.set(PaneSettings.allDisplays, barOnEveryDisplay) }
            defer { stopAgent(pane) }
            await Self.agentReady()
            let before = DockReservation.bottomInset()
            var after: CGFloat = 0, secondInset: CGFloat = 0
            try await SecondDisplay.with { second in
                // A Dock started while both displays are up follows the pointer (one started before doesn't, for a
                // while): restart it, as a crash or login would.
                SystemSettings.restartOwner("com.apple.dock")
                _ = await eventually(timeout: 8) { DockReservation.bottomInset() == before }
                await settle(3)
                let edge = CGPoint(x: second.midX, y: second.maxY - 1)
                for _ in 0..<60 {
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edge, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                await settle(1.5)
                after = DockReservation.bottomInset()
                if let screen = NSScreen.screens.dropFirst().first { secondInset = screen.visibleFrame.minY - screen.frame.minY }
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let note = "\(barOnEveryDisplay ? "a bar on every display" : "one bar"): pointer held 3 s at the second display's bottom edge: main display's reserved space \(Int(before)) → \(Int(after)), the second's \(Int(secondInset))"
            Report.record("Multiple displays · the Dock stays", note)
            print("MULTI-DISPLAY-DOCK: " + note)
            #expect(after == before && secondInset == 0)
        }
    }
}
