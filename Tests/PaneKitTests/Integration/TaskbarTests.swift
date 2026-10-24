// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 5 (taskbar inventory + thumbnails) and feature 6 (multiple instances).
    @Suite("5 · Taskbar inventory, 6 · Instances")
    struct TaskbarTests {
        @Test func everyAXWindowMapsToAWindowServerWindow() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B", "C"])
            defer { f.quit() }
            let server = WindowServer.windows().filter { $0.pid == f.pid && $0.layer == 0 }
            for window in f.standardWindows {
                let wid = try #require(PrivateAPI.windowID(of: window))
                #expect(server.contains { $0.id == wid }, "AX window \(AX.title(window) ?? "?") (\(wid)) not in CGWindowList")
            }
            let titled = server.filter { $0.name != nil }.count
            Report.record("5 Taskbar · CGWindowList titles", "\(titled)/\(server.count) windows have kCGWindowName (needs Screen Recording); use AX titles otherwise")
        }

        @Test func titleChangesAreVisibleThroughAX() async throws {
            // The taskbar label source. (Live title events come from kAXTitleChangedNotification per window.)
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            #expect(AX.title(try #require(f.window("A"))) == "F A")
        }

        @Test(.enabled(if: PreviewGate.enabled, "Needs the PanePreview helper (scripts/install-preview-helper.sh)"))
        func thumbnailsOfVisibleAndMinimizedWindows() async throws {
            let f = try await Fixture.launch(label: "F", windows: ["A", "B"])
            defer { f.quit() }
            let a = try #require(f.wid("A")), b = try #require(f.wid("B"))

            let (sck, _) = try #require(await PreviewClient.thumbnail(a))
            #expect(sck.width > 0 && sck.width <= 320)

            AX.set(try #require(f.window("B")), kAXMinimizedAttribute, kCFBooleanTrue)
            try #require(await eventually { !WindowServer.zOrder().contains(b) })
            await settle(0.8) // minimize animation
            let minimized = await PreviewClient.thumbnail(b)
            Report.record("5 Taskbar · minimized thumbnail", "via helper: \(minimized.map { "\($0.0.width)x\($0.0.height) (\($0.1.rawValue))" } ?? "nil")")
            #expect(minimized != nil)
        }

        @Test func launchingAgainWithNewInstanceGivesASecondProcess() async throws {
            let first = try await Fixture.launch(label: "P", windows: ["A"])
            defer { first.quit() }
            let second = try await Fixture.launch(label: "Q", windows: ["A"], newInstance: true)
            defer { second.quit() }
            #expect(first.pid != second.pid)
            #expect(NSRunningApplication.runningApplications(withBundleIdentifier: FixtureBundle.bundleID).count >= 2)
        }

        @Test func launchingAgainWithoutNewInstanceReusesTheProcess() async throws {
            let first = try await Fixture.launch(label: "P", windows: ["A"])
            defer { first.quit() }
            let again = try await Launcher.open(FixtureBundle.url, newInstance: false, activate: false)
            #expect(again.processIdentifier == first.pid)
        }

        /// The macOS-faithful "launch again": a new window in the running process via its own menu,
        /// pressed through AX while the app is in the background.
        @Test func newWindowThroughTheAppMenuWhileInBackground() async throws {
            // Launching inactive would put the windows on a Space AX can't see when the run starts from a
            // fullscreen Space, so: launch active, then push it to the background with a second app.
            let f = try await Fixture.launch(label: "F", windows: ["A"])
            defer { f.quit() }
            let o = try await Fixture.launch(label: "O", windows: ["Other"])
            defer { o.quit() }
            try #require(await eventually { AX.frontmostPID() == o.pid })
            let before = f.standardWindows.count
            #expect(Launcher.pressNewWindow(pid: f.pid))
            #expect(await eventually { f.standardWindows.count == before + 1 })
            #expect(AX.frontmostPID() == o.pid, "pressing the menu item through AX shouldn't activate the app")
        }

        /// Native tabs (feature 5 grouping): every tab is its own WindowServer window, but only the selected
        /// one is on a Space and in kAXWindows. Background tabs look exactly like closed-but-alive windows
        /// (ordered out, no Space), so a taskbar needs AXTabGroup / tab-group info to show them.
        @Test func nativeTabsAreSeparateWindowsButOneAXWindow() async throws {
            let f = try await Fixture.launch(label: "T", windows: ["A", "B", "C"], tabs: true, requireVisibleInAX: false)
            defer { f.quit() }
            if let wid = f.firstWindowServerWindow() { Focus.focus(wid: wid, pid: f.pid) }
            _ = await f.waitUntilVisibleInAX([])
            await settle(0.5)
            let ax = AX.windows(of: f.pid)
            let cg = WindowServer.windows(onScreenOnly: false).filter { $0.pid == f.pid && $0.layer == 0 && $0.bounds.height > 100 }
            let onSpace = cg.filter { !PrivateAPI.spaces(of: $0.id).isEmpty }
            let tabGroup = ax.first.flatMap { window -> AXUIElement? in
                (AX.get(window, kAXChildrenAttribute) as [AXUIElement]?)?.first { AX.role($0) == kAXTabGroupRole }
            }
            let tabCount = tabGroup.flatMap { (AX.get($0, kAXTabsAttribute) as [AXUIElement]?)?.count ?? (AX.get($0, kAXChildrenAttribute) as [AXUIElement]?)?.count }
            Report.record("5 Taskbar · native tabs", "3 tabs → AX windows=\(ax.count), CG windows=\(cg.count), on a Space=\(onSpace.count), AXTabGroup children=\(tabCount.map(String.init) ?? "-")")
            #expect(ax.count == 1)
            #expect(cg.count == 3)
            #expect(onSpace.count == 1)
        }
    }
}
