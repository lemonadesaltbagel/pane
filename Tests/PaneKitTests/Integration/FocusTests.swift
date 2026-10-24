// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 1: activating a window raises only that window, not the whole app.
    ///
    /// Setup: app F has windows A, B, C; app O has one window "Other" in front of all of them.
    /// Act: focus F's B. Windows semantics = F is frontmost, B is key and above Other, while A and C stay
    /// behind Other. macOS semantics = A and C jump above Other too.
    @Suite("1 · Per-window activation")
    struct FocusTests {
        struct Outcome: CustomStringConvertible {
            var frontmost: Bool
            var targetIsFocused: Bool
            var targetAboveOther: Bool
            var siblingsStayedBehind: Bool
            var windowsSemantics: Bool { frontmost && targetIsFocused && targetAboveOther && siblingsStayedBehind }
            var description: String {
                "frontmost=\(frontmost) focused=\(targetIsFocused) aboveOther=\(targetAboveOther) " +
                    "siblingsBehind=\(siblingsStayedBehind) → \(windowsSemantics ? "WINDOWS semantics" : "not Windows semantics")"
            }
        }

        static let trials = ["B", "A", "C", "B", "C", "A"]

        /// Puts O's "Other" window in front of every F window. Retries because F may still re-order its own
        /// windows (e.g. after a minimize animation) and macOS may have switched to another app's Space.
        static func frontOther(_ f: Fixture, _ o: Fixture) async throws {
            let other = try #require(o.wid("Other"))
            let siblings = ["A", "B", "C"].compactMap(f.wid)
            // Minimized siblings aren't in the on-screen order at all, so only on-screen ones can be compared.
            let inFront = { () -> Bool in
                let order = WindowServer.zOrder()
                return AX.frontmostPID() == o.pid && siblings.filter(order.contains).allSatisfy { WindowServer.isAbove(other, $0, in: order) == true }
            }
            for _ in 1...3 {
                Focus.focus(wid: other, pid: o.pid) // by wid: works even when AX can't see the window
                if let window = o.window("Other") { Focus.focus(window, using: .skyLight) }
                if await eventually(timeout: 1, inFront) { return }
            }
            try #require(inFront(), "precondition: Other should be in front of every F window. \(state(f, o))")
        }

        static func state(_ f: Fixture, _ o: Fixture) -> String {
            let order = WindowServer.windows(onScreenOnly: false).filter { ($0.pid == f.pid || $0.pid == o.pid) && $0.layer == 0 && $0.bounds.height > 100 }
            let front = AX.frontmostPID().map { $0 == f.pid ? "F" : $0 == o.pid ? "O" : "pid \($0)" } ?? "?"
            return "frontmost=\(front) space=\(PrivateAPI.activeSpace().map { "\($0.id) \($0.kind)" } ?? "?") " +
                "axF=\(AX.windows(of: f.pid).count) axO=\(AX.windows(of: o.pid).count) order(front→back)=" +
                order.map { "\($0.pid == f.pid ? "F" : "O"):\($0.id)\($0.isOnScreen ? "" : "(off)")" }.joined(separator: ",")
        }

        static func outcome(_ f: Fixture, _ o: Fixture, target: String, siblings: [String]) throws -> Outcome {
            let order = WindowServer.zOrder()
            let other = try #require(o.wid("Other")), wid = try #require(f.wid(target))
            return Outcome(
                frontmost: AX.frontmostPID() == f.pid,
                targetIsFocused: AX.focusedWindow(of: f.pid).flatMap(PrivateAPI.windowID) == wid,
                targetAboveOther: WindowServer.isAbove(wid, other, in: order) == true,
                siblingsStayedBehind: try siblings.allSatisfy { WindowServer.isAbove(other, try #require(f.wid($0)), in: order) == true }
            )
        }

        static func summary(_ outcomes: [(String, Outcome)]) -> String {
            let ok = outcomes.filter { $0.1.windowsSemantics }.count
            let failures = outcomes.filter { !$0.1.windowsSemantics }.map { "[\($0.0): \($0.1)]" }
            return "\(ok)/\(outcomes.count) trials gave Windows semantics" + (failures.isEmpty ? "" : "; failures: " + failures.joined(separator: " "))
        }

        @Test("Focus one window", arguments: FocusStrategy.allCases)
        func focusOneWindow(strategy: FocusStrategy) async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B", "C"])
            defer { f.quit() }
            let o = try await Fixture.launch(label: "O", windows: ["Other"], frame: Fixture.defaultFrame.insetBy(dx: -60, dy: -60))
            defer { o.quit() }

            var outcomes: [(String, Outcome)] = []
            for target in Self.trials {
                try await Self.frontOther(f, o)
                Focus.focus(try f.requireWindow(target), using: strategy)
                _ = await eventually(timeout: 1) { AX.frontmostPID() == f.pid }
                await settle(0.3)
                outcomes.append((target, try Self.outcome(f, o, target: target, siblings: ["A", "B", "C"].filter { $0 != target })))
            }
            Report.record("1 Focus · \(strategy)", Self.summary(outcomes))
            if strategy == .skyLight {
                #expect(outcomes.allSatisfy { $0.1.windowsSemantics }, "\(Self.summary(outcomes))")
            }
        }

        @Test("Focus a minimized window", arguments: [FocusStrategy.publicActivate, .skyLight])
        func focusingAMinimizedWindowRestoresOnlyIt(strategy: FocusStrategy) async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B", "C"])
            defer { f.quit() }
            let o = try await Fixture.launch(label: "O", windows: ["Other"], frame: Fixture.defaultFrame.insetBy(dx: -60, dy: -60))
            defer { o.quit() }
            let other = try #require(o.wid("Other"))

            var outcomes: [(String, Outcome)] = []
            for target in ["B", "A", "C", "B"] {
                let window = try f.requireWindow(target), wid = try #require(f.wid(target))
                AX.set(window, kAXMinimizedAttribute, kCFBooleanTrue)
                try #require(await eventually { !WindowServer.zOrder().contains(wid) })
                await settle(1.0) // minimize animation, after which F re-orders its remaining windows
                try await Self.frontOther(f, o)
                Focus.focus(window, using: strategy)
                _ = await eventually(timeout: 2) { WindowServer.isAbove(wid, other) == true }
                await settle(0.3)
                outcomes.append((target, try Self.outcome(f, o, target: target, siblings: ["A", "B", "C"].filter { $0 != target })))
            }
            Report.record("1 Focus · minimized · \(strategy)", Self.summary(outcomes))
            if strategy == .skyLight {
                #expect(outcomes.allSatisfy { $0.1.windowsSemantics }, "\(Self.summary(outcomes))")
            }
        }

        /// A window on another Space: X's window goes native fullscreen (its own Space, now current), then we
        /// focus F's B, which lives on the desktop. AX can't enumerate B from the fullscreen Space, so the
        /// element is the one cached while it was visible — which also tests that cached elements survive.
        @Test("Focus a window on another Space", arguments: [FocusStrategy.publicActivate, .skyLight])
        func focusAcrossSpaces(strategy: FocusStrategy) async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B", "C"])
            defer { f.quit() }
            let o = try await Fixture.launch(label: "O", windows: ["Other"], frame: Fixture.defaultFrame.insetBy(dx: -60, dy: -60))
            defer { o.quit() }
            try await Self.frontOther(f, o)
            let b = try f.requireWindow("B")
            let desktop = try #require(PrivateAPI.activeSpace())

            let x = try await Fixture.launch(label: "X", windows: ["Full"])
            defer { x.quit() }
            let full = try x.requireWindow("Full")
            AX.set(full, "AXFullScreen", kCFBooleanTrue)
            try #require(await eventually(timeout: 5) { PrivateAPI.activeSpace()?.kind == .fullscreen }, "X never entered fullscreen")
            await settle(1.0) // Space animation
            let axSeesBFromFullscreen = AX.windows(of: f.pid).contains { CFEqual($0, b) }

            Focus.focus(b, using: strategy)
            let switched = await eventually(timeout: 3) { PrivateAPI.activeSpace()?.id == desktop.id }
            await settle(1.0)
            let outcome = try Self.outcome(f, o, target: "B", siblings: ["A", "C"])
            Report.record("1 Focus · across Spaces · \(strategy)",
                          "AX lists B from the fullscreen Space=\(axSeesBFromFullscreen); switched to B's Space=\(switched); \(outcome)")
            AX.set(full, "AXFullScreen", kCFBooleanFalse)
            if strategy == .skyLight {
                #expect(switched)
                #expect(outcome.windowsSemantics, "\(outcome)")
            }
        }
    }
}
