// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import ApplicationServices
import CoreGraphics

/// Thin helpers over the Accessibility API. Geometry here is always in AX coordinates
/// (origin at the top-left of the primary screen, y grows downward).
public enum AX {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func app(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        // A hung app would otherwise block us for the 6s default (yabai uses 1s globally).
        AXUIElementSetMessagingTimeout(element, 1.0)
        return element
    }

    public static func get<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    public static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    // MARK: Windows

    public static func windows(of pid: pid_t) -> [AXUIElement] {
        get(app(pid), kAXWindowsAttribute) ?? []
    }

    public static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        get(app(pid), kAXFocusedWindowAttribute)
    }

    public static func title(_ window: AXUIElement) -> String? { get(window, kAXTitleAttribute) }
    public static func role(_ element: AXUIElement) -> String? { get(element, kAXRoleAttribute) }
    public static func subrole(_ element: AXUIElement) -> String? { get(element, kAXSubroleAttribute) }
    public static func isMinimized(_ window: AXUIElement) -> Bool { get(window, kAXMinimizedAttribute) ?? false }

    /// The pid that owns the menu bar right now, read from the system-wide element. Unlike
    /// `NSWorkspace.frontmostApplication` this doesn't depend on our own run loop delivering KVO updates.
    public static func frontmostPID() -> pid_t? {
        guard let app: AXUIElement = get(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        return pid(of: app)
    }

    // MARK: Geometry

    public static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position: AXValue = get(window, kAXPositionAttribute),
              let size: AXValue = get(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    @discardableResult
    public static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        return set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
    }

    @discardableResult
    public static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        return set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
    }

    /// Size → position → size, the order Rectangle/Amethyst/AeroSpace use: the first size keeps the window
    /// from being clamped while it moves across a display edge, the second applies the size the app may
    /// have rejected at the old position. `AXEnhancedUserInterface` is switched off around the writes
    /// because Chromium/Electron animate (and drop) frame changes while it's on.
    @discardableResult
    public static func setFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        let app = pid(of: window).map(app)
        let enhanced: Bool? = app.flatMap { get($0, "AXEnhancedUserInterface") }
        if enhanced == true, let app { set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced == true, let app { set(app, "AXEnhancedUserInterface", kCFBooleanTrue) } }
        setSize(window, frame.size)
        setPosition(window, frame.origin)
        return setSize(window, frame.size) == .success
    }

    // MARK: Buttons and menus

    public static func button(_ window: AXUIElement, _ attribute: String) -> AXUIElement? {
        get(window, attribute)
    }

    /// Top-level menus of an app's menu bar, as (title, element).
    public static func menuBarItems(of pid: pid_t) -> [(String, AXUIElement)] {
        guard let bar: AXUIElement = get(app(pid), kAXMenuBarAttribute),
              let items: [AXUIElement] = get(bar, kAXChildrenAttribute) else { return [] }
        return items.map { (title($0) ?? "", $0) }
    }

    /// Finds a menu item by path, e.g. ["File", "New Window"], walking AXMenuBarItem → AXMenu → AXMenuItem
    /// the way Menu-Bar-Search and menuffy do.
    public static func menuItem(of pid: pid_t, path: [String]) -> AXUIElement? {
        guard let first = path.first,
              var current = menuBarItems(of: pid).first(where: { $0.0 == first })?.1 else { return nil }
        for name in path.dropFirst() {
            guard let menus: [AXUIElement] = get(current, kAXChildrenAttribute),
                  let menu = menus.first,
                  let items: [AXUIElement] = get(menu, kAXChildrenAttribute),
                  let next = items.first(where: { title($0) == name }) else { return nil }
            current = next
        }
        return current
    }
}
