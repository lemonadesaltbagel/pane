// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// E9/E11: the ways into pane's Settings besides starting it again (AgentLifecycleTests): its optional menu-bar
    /// icon, the Settings shortcut (Win+I: ⌃⌘I in the Mac keyboard) and "Taskbar settings" on the bar's right-click.
    /// The Settings window itself is Phase 2: the agent logs "open settings".
    @Suite("Agent · ways into Settings")
    struct EntryPointsTests {
        static func log() -> String { (try? String(contentsOf: Harness.agentLog, encoding: .utf8)) ?? "" }

        static func icon(_ pid: pid_t) -> AXUIElement? {
            guard let bar: AXUIElement = AX.get(AX.app(pid), "AXExtrasMenuBar") else { return nil }
            return ((AX.get(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []).first {
                AX.title($0) == "Pane" || (AX.get($0, kAXDescriptionAttribute) as String?) == "pane"
            }
        }

        static func menuItem(_ root: AXUIElement, _ title: String) -> AXUIElement? {
            if AX.role(root) == kAXMenuItemRole, AX.title(root) == title { return root }
            for c in (AX.get(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let e = menuItem(c, title) { return e } }
            return nil
        }

        static func setIcon(_ on: Bool) {
            MainActor.assumeIsolatedOrSync { try? SettingsStore(url: Harness.testConfig).set(PaneSettings.showMenuBarIcon, on) }
        }

        /// The icon is on screen (right of the tray's divider, so not hidden with the other apps' icons), its menu
        /// opens Settings, and it comes and goes with the setting, live.
        @Test func menuBarIconFollowsTheSetting() async throws {
            let pane = try Harness.launchAgent { store in
                try? store.set(PaneSettings.showMenuBarIcon, true)
            }
            defer { stopAgent(pane) }
            _ = await eventually(timeout: 10) { Self.log().contains("running (pid") }
            // A new status item's window starts at the screen's bottom-left until macOS places it in the menu bar.
            let shown = await eventually(timeout: 10) { (Self.icon(pane.processIdentifier).flatMap(AX.frame)?.minY ?? .infinity) < 40 }
            let frame = Self.icon(pane.processIdentifier).flatMap(AX.frame) ?? .zero
            let screen = NSScreen.screens[0].frame
            let onScreen = frame.width > 0 && frame.minX >= screen.minX && frame.maxX <= screen.maxX && frame.minY < 40

            var chose = false
            if onScreen {
                // AXPress, as the tray tests press pane's chevron: the menu bar may be hidden (full-screen Spaces).
                if let icon = Self.icon(pane.processIdentifier) { _ = AX.perform(icon, kAXPressAction) }
                if await eventually(timeout: 3, { Self.icon(pane.processIdentifier).flatMap { Self.menuItem($0, "pane Settings…") } != nil }),
                   let item = Self.icon(pane.processIdentifier).flatMap({ Self.menuItem($0, "pane Settings…") }) {
                    _ = AX.perform(item, kAXPressAction)
                    chose = await eventually(timeout: 3) { Self.log().contains("open settings") }
                }
            }

            Self.setIcon(false)
            let hidden = await eventually(timeout: 3) { Self.icon(pane.processIdentifier) == nil }
            Self.setIcon(true)
            let back = await eventually(timeout: 3) { Self.icon(pane.processIdentifier) != nil }
            let note = "icon shown \(shown) at \(frame) on screen \(onScreen); menu opened Settings \(chose); setting off hides it \(hidden), on shows it \(back)"
            Report.record("Agent · menu-bar icon", note)
            print("MENUBARICON: " + note)
            #expect(shown && onScreen && chose && hidden && back)
        }

        /// Win+I (⌃⌘I in the Mac keyboard) and the bar's right-click → "Taskbar settings".
        @Test func shortcutAndTaskbarMenuOpenSettings() async throws {
            let f = try await Fixture.launch(label: "I", windows: ["A"], frame: CGRect(x: 220, y: 220, width: 420, height: 300))
            defer { f.quit() }
            let pane = try Harness.launchAgent { store in
                try? store.set(Shortcut.settings.setting, KeyBinding([.ctrl, .cmd], "i"))
                try? store.set(PaneSettings.alignment, "center")
            }
            defer { stopAgent(pane); SyntheticKeyboard.releaseAllModifiers() }
            await Harness.agentReady()

            Focus.focus(try f.requireWindow("A"), using: .skyLight)
            let pressed = await Harness.press(kVK_ANSI_I, [.maskControl, .maskCommand], frontmost: f.pid)
            let byShortcut = pressed ? await eventually(timeout: 3) { Self.log().contains("open settings") } : false

            // The bar's empty left part (centred alignment: Start and the apps sit in the middle).
            let screen = NSScreen.screens[0].frame
            SyntheticMouse.rightClick(at: CGPoint(x: screen.minX + 120, y: screen.maxY - 24))
            var byMenu = false
            if await eventually(timeout: 3, { TaskbarPinTests.choice(pane.processIdentifier, "Taskbar settings") != nil }),
               let item = TaskbarPinTests.choice(pane.processIdentifier, "Taskbar settings") {
                SyntheticMouse.click(at: item)
                byMenu = await eventually(timeout: 3) { Self.log().contains("open settings (taskbar)") }
            }
            let note = "⌃⌘I opened Settings \(byShortcut) (pressed \(pressed)); bar right-click → Taskbar settings \(byMenu)"
            Report.record("Agent · Settings shortcut and taskbar menu", note)
            print("ENTRYPOINTS: " + note)
            #expect(byShortcut && byMenu)
            #expect(SyntheticKeyboard.heldModifiers.isEmpty)
        }
    }
}
