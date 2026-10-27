// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Private symbols, resolved at runtime with dlsym so a symbol removed in a future macOS degrades to `nil`
/// instead of a launch-time crash (the approach Loop takes in `SkyLightSymbolLoader.swift`).
public enum PrivateAPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let pointer = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // -2 == RTLD_DEFAULT
        return unsafeBitCast(pointer, to: T.self)
    }

    // MARK: HIServices

    typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// AX element -> CGWindowID. Used by every project studied (AltTab, Rectangle, AeroSpace, yabai, ...).
    static let axUIElementGetWindow: AXUIElementGetWindowFn? = symbol("_AXUIElementGetWindow", in: nil)

    typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    /// Builds an AX element from a remote token — the only way to reach windows an app omits from kAXWindows
    /// (other Spaces, fullscreen Spaces, inactive tabs). AltTab `AXUIElement.swift:226-260`.
    static let createWithRemoteToken: CreateWithRemoteTokenFn? = symbol("_AXUIElementCreateWithRemoteToken", in: nil)

    /// Finds the AX element of window `wid` in `pid` by sweeping element IDs (AltTab's brute force), within a
    /// wall-clock budget. Off the main thread: one IPC per id.
    public static func windowElement(pid: pid_t, wid: CGWindowID, budget: TimeInterval = 0.3) -> AXUIElement? {
        guard let create = createWithRemoteToken, let token = CFDataCreateMutable(kCFAllocatorDefault, 20) else { return nil }
        CFDataSetLength(token, 20)
        guard let bytes = CFDataGetMutableBytePtr(token) else { return nil }
        memset(bytes, 0, 20)
        var pidField = pid
        memcpy(bytes, &pidField, 4)
        var magic = Int32(0x636f636f) // "coco"
        memcpy(bytes + 8, &magic, 4)
        let deadline = Date().addingTimeInterval(budget)
        var id: UInt64 = 0
        while Date() < deadline {
            var idField = id
            memcpy(bytes + 12, &idField, 8)
            id += 1
            guard let element = create(token)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard AX.role(element) == kAXWindowRole, windowID(of: element) == wid else { continue }
            return element
        }
        return nil
    }

    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    /// Deprecated public Carbon call; the SLPS functions are keyed by PSN, not pid.
    static let getProcessForPID: GetProcessForPIDFn? = symbol("GetProcessForPID", in: nil)

    // MARK: SkyLight

    typealias SLPSSetFrontProcessWithOptionsFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    static let slpsSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFn? = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight)

    typealias SLPSPostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    static let slpsPostEventRecordTo: SLPSPostEventRecordToFn? = symbol("SLPSPostEventRecordTo", in: skyLight)

    typealias CGSMainConnectionIDFn = @convention(c) () -> UInt32
    static let cgsMainConnectionID: CGSMainConnectionIDFn? = symbol("CGSMainConnectionID", in: skyLight)

    typealias CGSHWCaptureWindowListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    /// Window capture used by AltTab (< macOS 26) and DockDoor. Unlike ScreenCaptureKit it can capture
    /// minimized and other-Space windows. Needs Screen Recording permission.
    static let cgsHWCaptureWindowList: CGSHWCaptureWindowListFn? = symbol("CGSHWCaptureWindowList", in: skyLight)

    typealias CGSCopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    static let cgsCopySpacesForWindows: CGSCopySpacesForWindowsFn? = symbol("CGSCopySpacesForWindows", in: skyLight)

    /// Space IDs a window is assigned to (mask 0x7 = all spaces, as yabai uses). Ordered-out windows —
    /// closed-but-alive, pre-created, hidden helper windows — have none.
    public static func spaces(of wid: CGWindowID) -> [UInt64] {
        guard let connection = cgsMainConnectionID?(), let copy = cgsCopySpacesForWindows else { return [] }
        let ids = [NSNumber(value: wid)] as CFArray
        return (copy(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    typealias CGSGetActiveSpaceFn = @convention(c) (UInt32) -> UInt64
    static let cgsGetActiveSpace: CGSGetActiveSpaceFn? = symbol("CGSGetActiveSpace", in: skyLight)
    typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    static let cgsCopyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn? = symbol("CGSCopyManagedDisplaySpaces", in: skyLight)

    public enum SpaceKind: Equatable { case desktop, fullscreen, other(Int) }

    /// The active Space and whether it's a desktop or a fullscreen-app Space.
    public static func activeSpace() -> (id: UInt64, kind: SpaceKind)? {
        guard let connection = cgsMainConnectionID?(), let active = cgsGetActiveSpace?(connection),
              let displays = cgsCopyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] where (space["id64"] as? NSNumber)?.uint64Value == active {
                let type = (space["type"] as? NSNumber)?.intValue ?? -1
                return (active, type == 0 ? .desktop : type == 4 ? .fullscreen : .other(type))
            }
        }
        return (active, .other(-1))
    }

    /// The Space currently shown on each display.
    /// Ids of every fullscreen-app Space (macOS full screen, Split View).
    public static func fullscreenSpaces() -> Set<UInt64> {
        guard let connection = cgsMainConnectionID?(),
              let displays = cgsCopyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
            .filter { ($0["type"] as? NSNumber)?.intValue == 4 }
            .compactMap { ($0["id64"] as? NSNumber)?.uint64Value })
    }

    public static func visibleSpaces() -> Set<UInt64> {
        guard let connection = cgsMainConnectionID?(),
              let displays = cgsCopyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value })
    }

    /// The kind of Space a display is showing now (each display has its own while "Displays have separate Spaces" is on).
    public static func currentSpaceKind(displayID: CGDirectDisplayID) -> SpaceKind? {
        guard let connection = cgsMainConnectionID?(),
              let displays = cgsCopyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let id = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        // One entry per display, or a single "Main" one when the displays share their Spaces.
        guard let display = displays.first(where: { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(id) == .orderedSame })
                ?? (displays.count == 1 ? displays.first : nil),
              let current = display["Current Space"] as? [String: Any] else { return nil }
        let type = (current["type"] as? NSNumber)?.intValue ?? -1
        return type == 0 ? .desktop : type == 4 ? .fullscreen : .other(type)
    }

    /// Each display's Spaces, for diagnostics: "<display uuid prefix>: current <id>, <n> Spaces".
    public static func displaySpacesSummary() -> [String] {
        guard let connection = cgsMainConnectionID?(),
              let displays = cgsCopyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.map { display in
            let id = (display["Display Identifier"] as? String).map { String($0.prefix(8)) } ?? "?"
            let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
            return "\(id): current \(current), \((display["Spaces"] as? [Any])?.count ?? 0) Spaces"
        }
    }

    /// DockDoor's options: ignoreGlobalClipShape | nominalResolution | fullSize (Stage Manager-safe).
    public static func captureWindow(_ wid: CGWindowID) -> CGImage? {
        guard let connection = cgsMainConnectionID?(), let capture = cgsHWCaptureWindowList else { return nil }
        var wid = wid
        let options: UInt32 = (1 << 11) | (1 << 9) | (1 << 19)
        guard let images = capture(connection, &wid, 1, options)?.takeRetainedValue() as? [CGImage] else { return nil }
        return images.first
    }

    /// Flags for `_SLPSSetFrontProcessWithOptions` (yabai's `kCPS*`).
    public enum FrontMode: UInt32 {
        case allWindows = 0x100
        case userGenerated = 0x200
        case noWindows = 0x400
    }

    public static var availability: [String: Bool] {
        [
            "_AXUIElementGetWindow": axUIElementGetWindow != nil,
            "GetProcessForPID": getProcessForPID != nil,
            "_AXUIElementCreateWithRemoteToken": createWithRemoteToken != nil,
            "_SLPSSetFrontProcessWithOptions": slpsSetFrontProcessWithOptions != nil,
            "SLPSPostEventRecordTo": slpsPostEventRecordTo != nil,
            "CGSMainConnectionID": cgsMainConnectionID != nil,
            "CGSHWCaptureWindowList": cgsHWCaptureWindowList != nil,
            "CGSCopySpacesForWindows": cgsCopySpacesForWindows != nil,
        ]
    }

    /// macOS's own system shortcuts ("symbolic hotkeys"), which WindowServer handles before any event tap sees the key:
    /// 1 = ⌘Tab, 2 = ⌘⇧Tab (the app switcher). Not persisted: they come back at logout (AltTab uses the same calls).
    public enum SymbolicHotKey: Int32 { case commandTab = 1, commandShiftTab = 2 }
    private typealias SetSymbolicFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsSymbolicFn = @convention(c) (Int32) -> Bool
    private static let setSymbolic: SetSymbolicFn? = symbol("CGSSetSymbolicHotKeyEnabled", in: skyLight)
    private static let isSymbolic: IsSymbolicFn? = symbol("CGSIsSymbolicHotKeyEnabled", in: skyLight)

    public static func setSymbolicHotKey(_ key: SymbolicHotKey, enabled: Bool) {
        _ = setSymbolic?(key.rawValue, enabled)
    }

    public static func isSymbolicHotKeyEnabled(_ key: SymbolicHotKey) -> Bool? { isSymbolic?(key.rawValue) }

    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard let fn = axUIElementGetWindow, fn(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    static func psn(for pid: pid_t) -> ProcessSerialNumber? {
        var psn = ProcessSerialNumber()
        guard let fn = getProcessForPID, fn(pid, &psn) == noErr else { return nil }
        return psn
    }

    @discardableResult
    static func setFrontProcess(pid: pid_t, wid: CGWindowID, mode: FrontMode) -> Bool {
        guard var psn = psn(for: pid), let fn = slpsSetFrontProcessWithOptions else { return false }
        return fn(&psn, wid, mode.rawValue) == .success
    }

    /// Makes `wid` the key window of its app by posting a synthetic left-mouse-down record to the
    /// WindowServer. Layout follows AltTab `SkyLight.framework.swift` (MakeKeyWindowEvent): 0x100 zeroed
    /// bytes (macOS 14.7.4+ reads past the 0xf8 record), mouse-down only (a down/up pair is a real click),
    /// and a click point far past the bottom-right so no control or resize region is ever hit.
    @discardableResult
    static func makeKeyWindow(pid: pid_t, wid: CGWindowID) -> Bool {
        guard var psn = psn(for: pid), let fn = slpsPostEventRecordTo else { return false }
        var wid = wid
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8 // record length
        bytes[0x08] = 0x01 // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10 // undocumented; yabai/Hammerspoon set it
        withUnsafeBytes(of: &point) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        withUnsafeBytes(of: &wid) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        return bytes.withUnsafeMutableBufferPointer { fn(&psn, $0.baseAddress!) } == .success
    }
}
