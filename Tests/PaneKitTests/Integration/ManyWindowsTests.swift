// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneShell
import PaneTestKit

extension IntegrationTests {
    /// Robustness (PANE_STRESS=1): pane with 120+ windows open. Measures the window list, the taskbar update, Alt+Tab
    /// and Task View opening, and the agent's idle CPU and memory.
    @Suite("Robustness · many windows")
    struct ManyWindowsTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PANE_STRESS"] != nil)) func hundredTwentyWindows() async throws {
            var apps: [Fixture] = []
            let names = (1...24).map { "W\($0)" }
            for (i, label) in ["M1", "M2", "M3", "M4", "M5"].enumerated() {
                apps.append(try await Fixture.launch(label: label, windows: names, frame: CGRect(x: 120 + i * 60, y: 120 + i * 30, width: 420, height: 300)))
            }
            defer { apps.forEach { $0.quit() } }
            let pids = Set(apps.map(\.pid))
            let inventory = WindowInventory()
            var listed = 0
            _ = await eventually(timeout: 20) { listed = inventory.refreshNow().filter { pids.contains($0.pid) }.count; return listed >= 120 }
            // 1. The window list (WindowServer + AX), five times.
            var refreshMs: [Double] = []
            var all: [ManagedWindow] = []
            for _ in 0..<5 {
                let t = Date()
                all = inventory.refreshNow()
                refreshMs.append(Date().timeIntervalSince(t) * 1000)
            }
            // 2. The taskbar update with all of them (per-window buttons: the most work), in-process.
            let bar = await MainActor.run { TaskbarPanel(inventory: inventory, height: 48, mode: .never) }
            await MainActor.run { bar.show() }
            defer { Task { @MainActor in bar.close() } }
            var updateMs: [Double] = []
            for i in 0..<5 {
                let windows = all
                let ms = await MainActor.run { () -> Double in
                    if i > 0 { bar.update([]) } // force a full rebuild each time
                    let t = Date()
                    bar.update(windows)
                    return Date().timeIntervalSince(t) * 1000
                }
                updateMs.append(ms)
            }
            await MainActor.run { bar.close() }

            // 3. The agent with all these windows: Alt+Tab and Task View opening, idle CPU, memory.
            let pane = try Harness.launchAgent()
            defer { stopAgent(pane); SyntheticKeyboard.releaseAllModifiers() }
            _ = await eventually(timeout: 8) { MainActor.assumeIsolatedOrSync { DockReservation.bottomInset() == 48 } }
            _ = await eventually(timeout: 10) { ((try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "").contains("running (pid") }
            await settle(4)
            Focus.focus(try apps[0].requireWindow("W1"), using: .skyLight)
            _ = await eventually(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == apps[0].pid }
            func shown(_ title: String) -> Bool { AX.windows(of: pane.processIdentifier).contains { AX.title($0) == title } }
            SyntheticKeyboard.holdModifiers(.maskAlternate)
            var t = Date()
            SyntheticKeyboard.tapKey(kVK_Tab, flags: .maskAlternate)
            _ = await eventually(timeout: 3) { shown("Pane Switcher") }
            let switcherMs = Date().timeIntervalSince(t) * 1000
            SyntheticKeyboard.tapKey(kVK_Escape, flags: .maskAlternate)
            SyntheticKeyboard.releaseModifiers(.maskAlternate)
            await settle(0.8)
            guard await eventually(timeout: 2, { NSWorkspace.shared.frontmostApplication?.processIdentifier == apps[0].pid }) else { Issue.record("fixture not in front"); return }
            t = Date()
            SyntheticKeyboard.press(kVK_Tab, [.maskControl, .maskCommand])
            _ = await eventually(timeout: 4) { shown("Pane Task View") }
            let taskViewMs = Date().timeIntervalSince(t) * 1000
            SyntheticKeyboard.press(kVK_Escape) // Task View has the keys while open
            await settle(1.0)
            // Idle: CPU over 10 s, memory.
            func ps(_ field: String) -> Double {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
                p.arguments = ["-o", "\(field)=", "-p", "\(pane.processIdentifier)"]
                let out = Pipe(); p.standardOutput = out
                try? p.run(); p.waitUntilExit()
                return Double(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            }
            func cpuTime() -> Double { // "mm:ss.cc" cumulative
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
                p.arguments = ["-o", "time=", "-p", "\(pane.processIdentifier)"]
                let out = Pipe(); p.standardOutput = out
                try? p.run(); p.waitUntilExit()
                let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let parts = s.split(separator: ":").compactMap { Double($0) }
                return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
            }
            let c0 = cpuTime()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let idleCPU = (cpuTime() - c0) / 10 * 100
            let rssMB = ps("rss") / 1024
            func stats(_ v: [Double]) -> String { "median \(Int(v.sorted()[v.count / 2])) ms, max \(Int(v.max() ?? 0)) ms" }
            let note = "\(listed) fixture windows (\(all.count) in all): window list \(stats(refreshMs)); taskbar update (per-window buttons) \(stats(updateMs)); Alt+Tab opened in \(Int(switcherMs)) ms, Task View in \(Int(taskViewMs)) ms; agent idle CPU \(String(format: "%.1f", idleCPU))%, memory \(Int(rssMB)) MB"
            Report.record("Robustness · 120 windows", note)
            print("MANY: " + note)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }
    }
}
