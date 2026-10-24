// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// Ways to bring a window forward. The point of having several is to measure, on the user's macOS
/// version, which ones give Windows semantics (only the target window comes forward).
public enum FocusStrategy: String, CaseIterable, CustomStringConvertible {
    /// Public API only: AXMain + AXRaise + NSRunningApplication.activate (AeroSpace's fallback).
    case publicActivate
    /// AX only: AXFrontmost on the app element + AXMain + AXRaise.
    case axFrontmost
    /// AltTab/yabai/Loop recipe: _SLPSSetFrontProcessWithOptions(wid, userGenerated) + make-key event
    /// record + AXRaise, then AltTab's settle check (re-raise if still covered after ~150ms).
    case skyLight

    public var description: String { rawValue }
}

public enum Focus {
    /// Blocks for up to ~0.7s (unminimize wait + settle check), so call it off the main thread.
    @discardableResult
    public static func focus(_ window: AXUIElement, using strategy: FocusStrategy) -> Bool {
        guard let pid = AX.pid(of: window) else { return false }
        if strategy != .skyLight && AX.isMinimized(window) {
            AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
            if let wid = PrivateAPI.windowID(of: window) { waitUntil(timeout: 0.6) { WindowServer.zOrder().contains(wid) } }
        }
        switch strategy {
        case .publicActivate:
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
            AX.perform(window, kAXRaiseAction)
            return NSRunningApplication(processIdentifier: pid)?.activate() ?? false
        case .axFrontmost:
            let app = AX.app(pid)
            let fronted = AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue) == .success
            AX.set(window, kAXMainAttribute, kCFBooleanTrue)
            AX.perform(window, kAXRaiseAction)
            return fronted
        case .skyLight:
            guard let wid = PrivateAPI.windowID(of: window) else { return false }
            if AX.isMinimized(window) {
                AX.set(window, kAXMinimizedAttribute, kCFBooleanFalse)
                // Fronting while the window is still animating out of the Dock lets macOS raise the app's
                // other windows too, so wait until it's back on screen.
                waitUntil(timeout: 0.6) { WindowServer.zOrder().contains(wid) }
            }
            guard PrivateAPI.setFrontProcess(pid: pid, wid: wid, mode: .userGenerated) else { return false }
            PrivateAPI.makeKeyWindow(pid: pid, wid: wid)
            AX.perform(window, kAXRaiseAction)
            // AltTab `verifyNotCovered`: every step can report success while another app's window still
            // sits above the target; a second raise fixes it.
            Thread.sleep(forTimeInterval: 0.15)
            if isCovered(wid) { AX.perform(window, kAXRaiseAction) }
            return true
        }
    }

    /// The production path: public `activate()` + AXRaise (6/6 in tests), falling back to SkyLight if the app
    /// didn't come forward (activation requests can be refused).
    @discardableResult
    public static func focusBest(_ window: AXUIElement) -> Bool {
        guard let pid = AX.pid(of: window) else { return false }
        _ = focus(window, using: .publicActivate)
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if AX.frontmostPID() == pid { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return focus(window, using: .skyLight)
    }

    /// Makes `pid` the frontmost app without raising or keying any of its windows (SkyLight "no windows" mode).
    /// pane uses it on itself to take focus away from every window — Windows focusing an empty desktop.
    /// (`NSApp.activate` is only a request on macOS 14+ and is refused for a background agent: measured in the soak.)
    @discardableResult
    public static func frontWithoutWindows(pid: pid_t) -> Bool {
        PrivateAPI.setFrontProcess(pid: pid, wid: 0, mode: .noWindows)
    }

    /// The click-through path: front exactly this window with no settle/verify pause (the caller waits for the
    /// app to report it focused). SkyLight first — `activate()` can be refused for a background app.
    @discardableResult
    public static func focusFast(_ window: AXUIElement) -> Bool {
        guard let pid = AX.pid(of: window), let wid = PrivateAPI.windowID(of: window) else { return false }
        guard PrivateAPI.setFrontProcess(pid: pid, wid: wid, mode: .userGenerated) else { return focusBest(window) }
        PrivateAPI.makeKeyWindow(pid: pid, wid: wid)
        AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        AX.perform(window, kAXRaiseAction)
        return true
    }

    /// Focus a window wherever it is — including another Space or a fullscreen Space, where kAXWindows can't see
    /// it and focusing by window id alone does NOT switch Spaces (measured). Order: the AX element (given, or
    /// found through the remote-token sweep) via the normal path, which switches Spaces; else activate the app.
    @discardableResult
    public static func focusAnywhere(wid: CGWindowID, pid: pid_t, element: AXUIElement? = nil) -> Bool {
        if let element = element ?? PrivateAPI.windowElement(pid: pid, wid: wid) {
            return focusBest(element)
        }
        let activated = NSRunningApplication(processIdentifier: pid)?.activate() ?? false
        return activated || focus(wid: wid, pid: pid)
    }

    /// Focus by WindowServer id alone, no AX element needed. This is the only way to reach windows on a Space
    /// that isn't shown (kAXWindows omits them); for such a target macOS switches to its Space (AltTab step 1).
    @discardableResult
    public static func focus(wid: CGWindowID, pid: pid_t) -> Bool {
        guard PrivateAPI.setFrontProcess(pid: pid, wid: wid, mode: .userGenerated) else { return false }
        return PrivateAPI.makeKeyWindow(pid: pid, wid: wid)
    }

    /// True when some normal window in front of `wid` overlaps it.
    static func isCovered(_ wid: CGWindowID) -> Bool {
        let order = WindowServer.windows().filter { $0.layer == 0 }
        guard let index = order.firstIndex(where: { $0.id == wid }) else { return false }
        return order[..<index].contains { $0.bounds.intersects(order[index].bounds) }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
}
