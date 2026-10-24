// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Experiment (PANE_STRESS=1): resize the Dock live (private CoreDock calls) instead of restarting it. Restarting
    /// the Dock un-minimizes every minimized window (measured: StartupAdoptionTests). Does the live path keep them, and
    /// does it move the screen's visible frame like a restart does?
    @Suite("Experiments · live Dock resize")
    struct CoreDockExperimentTests {
        typealias GetF = @convention(c) () -> Float
        typealias SetF = @convention(c) (Double) -> Void

        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func liveResizeKeepsMinimizedWindows() async throws {
            let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
            let get = unsafeBitCast(try #require(dlsym(h, "CoreDockGetTileSize")), to: GetF.self)
            let set = unsafeBitCast(try #require(dlsym(h, "CoreDockSetTileSize")), to: SetF.self)
            let f = try await Fixture.launch(label: "K", windows: ["A"], frame: CGRect(x: 200, y: 200, width: 400, height: 300))
            defer { f.quit() }
            let w = try f.requireWindow("A")
            AX.set(w, kAXMinimizedAttribute, kCFBooleanTrue)
            _ = await eventually { AX.get(w, kAXMinimizedAttribute) == true }
            await settle(1)
            let original = get()
            let insetBefore = await MainActor.run { DockReservation.bottomInset() }
            let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            let target: Double = (28 - 16) / (128 - 16)
            let start = Date()
            set(target)
            let moved = await eventually(timeout: 4) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() != insetBefore } }
            let took = Date().timeIntervalSince(start)
            await settle(0.8)
            let insetSmall = await MainActor.run { DockReservation.bottomInset() }
            let stillMinimized = AX.get(w, kAXMinimizedAttribute) == true
            let samePID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier == dockPID
            let pref = UserDefaults(suiteName: "com.apple.dock")?.integer(forKey: "tilesize")
            set(Double(original))
            _ = await eventually(timeout: 4) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == insetBefore } }
            await settle(0.5)
            let restored = await MainActor.run { DockReservation.bottomInset() } == insetBefore
            let note = "tile \(original) → \(target): visible frame moved \(moved) in \(Int(took * 1000)) ms, inset \(Int(insetBefore)) → \(Int(insetSmall)); Dock not restarted \(samePID); minimized window still minimized \(stillMinimized); tilesize pref now \(pref ?? -1); restored \(restored)"
            Report.record("Live Dock resize", note)
            print("COREDOCK: " + note)
        }
    }
}
