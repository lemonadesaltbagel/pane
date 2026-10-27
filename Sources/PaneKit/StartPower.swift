// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Collaboration
import IOKit.pwr_mgt

/// Start's power menu and account (act at once, like Windows).
public enum PowerAction: String, CaseIterable, Sendable {
    case lock, sleep, restart, shutDown, logOut, switchUser

    public var title: String {
        switch self {
        case .lock: return "Lock"
        case .sleep: return "Sleep"
        case .restart: return "Restart"
        case .shutDown: return "Shut down"
        case .logOut: return "Log out"
        case .switchUser: return "Switch user"
        }
    }
}

public enum Power {
    /// Tests: PANE_FAKE_POWER=<file> appends the action's name to the file and does nothing else. Never sleep,
    /// restart or shut down a Mac running tests (sleep locks it and ends unattended work).
    nonisolated(unsafe) public static var perform: (PowerAction) -> Bool = { action in
        let env = ProcessInfo.processInfo.environment
        if let path = env["PANE_FAKE_POWER"] { return fake(action, to: path) }
        // A test agent never sleeps, restarts or shuts down the Mac, even if a test forgot the fake.
        if env["PANE_DEFAULTS_SUITE"] != nil {
            PaneLog.write("power: \(action.rawValue) refused in a test agent")
            return false
        }
        return real(action)
    }

    /// The test stand-in: records the action, nothing else.
    @discardableResult
    public static func fake(_ action: PowerAction, to path: String) -> Bool {
        let line = action.rawValue + "\n"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close() }
        else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
        return true
    }

    static func real(_ action: PowerAction) -> Bool {
        switch action {
        case .lock: return loginCall("SACLockScreenImmediate")
        case .switchUser: return loginCall("SACSwitchToLoginWindow")
        case .sleep:
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            defer { IOServiceClose(port) }
            return IOPMSleepSystem(port) == kIOReturnSuccess
        case .restart: return sendToLoginWindow("rest")
        case .shutDown: return sendToLoginWindow("shut")
        case .logOut: return sendToLoginWindow("rlgo")
        }
    }

    /// login.framework's lock and switch-user calls (private; what Chromium uses). No synthetic ⌃⌘Q.
    private static func loginCall(_ symbol: String) -> Bool {
        typealias Fn = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY),
              let sym = dlsym(handle, symbol) else { return false }
        _ = unsafeBitCast(sym, to: Fn.self)()
        return true
    }

    /// Restart / shut down / log out: a Core-suite Apple event to loginwindow (Apple QA1134). Apps may still object.
    private static func sendToLoginWindow(_ code: String) -> Bool {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber, bytes: &psn, length: MemoryLayout<ProcessSerialNumber>.size)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: fourCharCode(code), targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        do { _ = try event.sendEvent(options: [.noReply], timeout: 10); return true } catch { return false }
    }

    static func fourCharCode(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}

/// The account button: your name and picture (Users & Groups), and "Change account settings".
public enum Account {
    public static var name: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }

    public static var picture: NSImage? {
        CBIdentity(name: NSUserName(), authority: .default())?.image
    }

    /// The picture as a circle of `size` points (centre-cropped), ready for a menu button.
    public static func avatar(size: CGFloat) -> NSImage? {
        guard let picture else { return nil }
        let source = picture.size
        let side = min(source.width, source.height)
        let crop = NSRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            picture.draw(in: rect, from: crop, operation: .copy, fraction: 1)
            return true
        }
    }

    public static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!)
    }
}

/// The folders next to the power button (setting `start.folders`, D6): Settings and Finder by default.
public enum StartPlace: String, CaseIterable, Sendable {
    case settings, finder, documents, downloads, music, pictures, movies, network, home

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .finder: return "Finder"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .music: return "Music"
        case .pictures: return "Pictures"
        case .movies: return "Movies"
        case .network: return "Network"
        case .home: return "Home folder"
        }
    }

    public var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .finder: return "folder"
        case .documents: return "doc"
        case .downloads: return "arrow.down.circle"
        case .music: return "music.note"
        case .pictures: return "photo"
        case .movies: return "film"
        case .network: return "network"
        case .home: return "house"
        }
    }

    /// Where it goes: System Settings for Settings, a Finder window otherwise.
    public var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .settings: return URL(fileURLWithPath: "/System/Applications/System Settings.app")
        case .finder: return home
        case .documents: return home.appendingPathComponent("Documents")
        case .downloads: return home.appendingPathComponent("Downloads")
        case .music: return home.appendingPathComponent("Music")
        case .pictures: return home.appendingPathComponent("Pictures")
        case .movies: return home.appendingPathComponent("Movies")
        case .network: return URL(fileURLWithPath: "/Network")
        case .home: return home
        }
    }

    public func open() { NSWorkspace.shared.open(url) }
}
