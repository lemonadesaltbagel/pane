// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import CoreGraphics
import Foundation

/// SkyLight's per-connection notification stream (AltTab `WindowServerEvents.swift`, yabai): window
/// lifecycle straight from the WindowServer, independent of whether the app's AX tree is honest or alive.
///
/// Two rules measured by AltTab on macOS 26: nothing (not even create/destroy) is delivered until at least one
/// window has been opted in with `SLSRequestNotificationsForWindows`, and that call REPLACES the watch list,
/// so the full set must be sent every time.
public final class WindowServerEvents {
    public enum Kind: UInt32, CaseIterable {
        case destroyed = 804
        case moved = 806
        case resized = 807
        case focused = 808
        case created = 811
        case orderedIn = 815
        case orderedOut = 816
    }

    public static let shared = WindowServerEvents()

    /// Called on whatever thread SkyLight delivers on (the main thread when NSApp is running); keep it
    /// cheap. Delivery needs an AppKit event loop (`NSApp.run()`): a bare CFRunLoop gets nothing.
    public var handler: ((Kind, CGWindowID) -> Void)?

    private let lock = NSLock()
    private var subscribers: [UUID: (Kind, CGWindowID) -> Void] = [:]

    /// Multiple listeners (one per WindowWatcher); returns a token for `removeSubscriber`.
    public func addSubscriber(_ subscriber: @escaping (Kind, CGWindowID) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { subscribers[id] = subscriber }
        return id
    }

    public func removeSubscriber(_ id: UUID) { lock.withLock { subscribers[id] = nil } }

    private func dispatch(_ kind: Kind, _ wid: CGWindowID) {
        handler?(kind, wid)
        for subscriber in lock.withLock({ Array(subscribers.values) }) { subscriber(kind, wid) }
    }

    private var watched = Set<CGWindowID>()
    private var started = false

    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, UInt32) -> Void
    private typealias RegisterFn = @convention(c) (UInt32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> CGError
    private typealias RequestFn = @convention(c) (UInt32, UnsafeMutablePointer<CGWindowID>, Int32) -> CGError

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let register: RegisterFn? = dlsym(skyLight, "SLSRegisterConnectionNotifyProc").map { unsafeBitCast($0, to: RegisterFn.self) }
    private static let request: RequestFn? = dlsym(skyLight, "SLSRequestNotificationsForWindows").map { unsafeBitCast($0, to: RequestFn.self) }

    public static var isAvailable: Bool { register != nil && request != nil && PrivateAPI.cgsMainConnectionID != nil }

    private static let proc: NotifyProc = { event, data, length, _, _ in
        guard let kind = Kind(rawValue: event) else { return }
        var wid: UInt32 = 0
        if let data, length >= 4 { memcpy(&wid, data, 4) }
        WindowServerEvents.shared.dispatch(kind, wid)
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return true }
        guard let register = Self.register, let connection = PrivateAPI.cgsMainConnectionID?() else { return false }
        for kind in Kind.allCases { _ = register(connection, Self.proc, kind.rawValue, nil) }
        started = true
        return true
    }

    /// Adds windows to the watch list (sending the whole list, since the call replaces it).
    @discardableResult
    public func watch(_ wids: [CGWindowID]) -> Bool {
        let existing = Set(WindowServer.windows(onScreenOnly: false).map(\.id))
        lock.lock(); defer { lock.unlock() }
        let before = watched
        watched = watched.intersection(existing).union(wids) // prune dead wids; the list is replaced each call
        if watched == before && !before.isEmpty { return true }
        guard let request = Self.request, let connection = PrivateAPI.cgsMainConnectionID?() else { return false }
        var list = Array(watched)
        return request(connection, &list, Int32(list.count)) == .success
    }
}
