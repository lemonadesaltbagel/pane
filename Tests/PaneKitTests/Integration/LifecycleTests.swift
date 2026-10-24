// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 2: closing the last window quits the app (emulated from outside: observe → verify → terminate).
    @Suite("2 · Quit on last window")
    struct LifecycleTests {
        @Test func closingTheLastWindowQuitsTheApp() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let wid = try #require(f.wid("A"))
            let watcher = try WindowWatcher(pid: f.pid)
            defer { watcher.stop() }
            #expect(watcher.trackedCount == 1)

            #expect(try f.close("A") == .success)
            let latency = await timeUntil(timeout: 3) { watcher.records.contains { $0.event == .closed(wid) } }
            let trigger = watcher.records.first { $0.event == .closed(wid) }?.trigger ?? "-"
            Report.record("2 Lifecycle · close detected", latency.map { String(format: "%.0f ms via %@", $0 * 1000, trigger) } ?? "never")
            #expect(latency != nil)

            // The fixture, like most Mac apps, keeps running with no windows.
            await settle(0.5)
            #expect(!f.app.isTerminated)

            let snapshot = AppWindowSnapshot.capture(pid: f.pid)
            let decision = LifecyclePolicy().decide(snapshot)
            Report.record("2 Lifecycle · after last close", "\(snapshot) → \(decision)")
            #expect(decision == .quit)
            f.app.terminate()
            #expect(await eventually(timeout: 3) { f.app.isTerminated })
        }

        enum CloseSignal: String, CaseIterable { case axNotificationsOnly, windowServerEvents, poll }

        /// How quickly each signal notices the LAST window closing (a non-last close is caught by
        /// AXFocusedWindowChanged in ~25 ms whatever the signal, since focus moves to the next window).
        /// Decides whether the private SkyLight stream is worth it over public AX + polling.
        @Test("Close detection latency", arguments: CloseSignal.allCases)
        func closeDetectionLatency(signal: CloseSignal) async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let wid = try #require(f.wid("A"))
            let watcher = try WindowWatcher(pid: f.pid, pollInterval: signal == .poll ? 1.0 : nil,
                                            windowServerEvents: signal == .windowServerEvents)
            defer { watcher.stop() }
            await settle(0.3)

            try f.close("A")
            let latency = await timeUntil(timeout: 3) { watcher.records.contains { $0.event == .closed(wid) } }
            let trigger = watcher.records.first { $0.event == .closed(wid) }?.trigger ?? "-"
            Report.record("2 Lifecycle · close latency · \(signal)", latency.map { String(format: "%.0f ms via %@", $0 * 1000, trigger) } ?? "not detected within 3 s")
            if signal != .axNotificationsOnly { #expect(latency != nil) }
            if signal == .windowServerEvents { #expect((latency ?? 9) < 0.5) }
        }

        @Test func aFloatingPaletteDoesNotKeepTheAppAlive() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A"], panel: true)
            defer { f.quit() }
            let palette = try #require(f.window("Palette"))
            Report.record("2 Lifecycle · palette AX identity", "role=\(AX.role(palette) ?? "-") subrole=\(AX.subrole(palette) ?? "-")")

            try f.close("A")
            #expect(await eventually { f.window("A") == nil })
            let snapshot = AppWindowSnapshot.capture(pid: f.pid)
            #expect(snapshot.standardWindows == 0)
            #expect(snapshot.otherWindows >= 1)
            #expect(LifecyclePolicy().decide(snapshot) == .quit)
        }

        @Test func aMinimizedWindowKeepsTheAppAlive() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B"])
            defer { f.quit() }
            AX.set(try #require(f.window("A")), kAXMinimizedAttribute, kCFBooleanTrue)
            try f.close("B")
            #expect(await eventually { f.window("B") == nil })
            let snapshot = AppWindowSnapshot.capture(pid: f.pid)
            #expect(snapshot.standardWindows == 1)
            #expect(LifecyclePolicy().decide(snapshot) == .keep(.hasWindows))
        }

        /// The conservative "WindowServer has windows AX can't see" rule is useless if it fires on a normal
        /// app with nothing hidden. This checks for false positives (closed windows lingering in CGWindowList).
        @Test func windowServerCrossCheckHasNoFalsePositives() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B"])
            defer { f.quit() }
            #expect(AppWindowSnapshot.capture(pid: f.pid).unaccountedWindowServerWindows == 0)
            try f.close("B")
            #expect(await eventually { f.window("B") == nil })
            await settle(0.5)
            let leftovers = AppWindowSnapshot.capture(pid: f.pid).unaccountedWindowServerWindows
            let lingering = WindowServer.windows(onScreenOnly: false).filter { $0.pid == f.pid && $0.layer == 0 && $0.bounds.height > 100 }
            Report.record("2 Lifecycle · CG after close", "unaccounted-on-a-Space=\(leftovers); app's large CG windows: " +
                lingering.map { "\($0.id) onscreen=\($0.isOnScreen) spaces=\(PrivateAPI.spaces(of: $0.id))" }.joined(separator: ", "))
            #expect(leftovers == 0)
        }

        /// The swiftquit bug: kAXWindows omits windows on Spaces that aren't shown, so an AX-only rule would
        /// quit an app whose windows are on another desktop. Only meaningful when the fixture's windows land
        /// on a Space we're not looking at (e.g. the run started from a fullscreen Terminal); otherwise it
        /// records "not applicable".
        @Test func windowsOnAnotherSpaceKeepTheAppAlive() async throws {
            let f = try await Fixture.launch(label: "S", windows: ["A"], activate: false, requireVisibleInAX: false)
            defer { f.quit() }
            await settle(0.5)
            let axCount = AX.windows(of: f.pid).count
            guard axCount == 0 else {
                Report.record("2 Lifecycle · other-Space window", "not applicable: fixture window is on the current Space (AX sees \(axCount))")
                return
            }
            let snapshot = AppWindowSnapshot.capture(pid: f.pid)
            let decision = LifecyclePolicy().decide(snapshot)
            Report.record("2 Lifecycle · other-Space window", "AX sees 0 windows; \(snapshot) → \(decision)")
            #expect(snapshot.unaccountedWindowServerWindows >= 1)
            #expect(decision == .keep(.possiblyHiddenWindows))
        }
    }
}
