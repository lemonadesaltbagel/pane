// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import ApplicationServices

/// What pane is allowed to do (research/plan-settings-onboarding.md, E1): Accessibility (required: every window and
/// keyboard behaviour) and window previews (optional: the PanePreview helper's Screen Recording). Changes are noticed
/// without a relaunch: macOS's Accessibility change notification, and a check every second as a fallback
/// (`AXIsProcessTrusted` can lag a toggle).
///
/// Tests fake the state with PANE_FAKE_PERMISSIONS_FILE: a file holding e.g. `accessibility=missing`, re-read on every
/// check (rewrite it to "grant" or "revoke").
@MainActor
public final class Permissions {
    public enum State: String, Sendable { case granted, missing }

    public static let shared = Permissions()
    /// Called on the main thread when Accessibility changes.
    public var onAccessibilityChange: ((State) -> Void)?
    public private(set) var accessibility: State
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private init() { accessibility = Self.readAccessibility() }

    nonisolated static func readAccessibility() -> State {
        if let path = ProcessInfo.processInfo.environment["PANE_FAKE_PERMISSIONS_FILE"],
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text.contains("accessibility=missing") ? .missing : .granted
        }
        return AXIsProcessTrusted() ? .granted : .missing
    }

    /// Window previews: the helper is running and has Screen Recording (or pane has it itself).
    public var previews: State { PreviewClient.isAvailable ? .granted : .missing }

    public func start() {
        guard timer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // The notification can arrive before the new value reads back: look again a moment later too.
            MainActor.assumeIsolated { self?.check() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.check() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    public func check() {
        let now = Self.readAccessibility()
        guard now != accessibility else { return }
        accessibility = now
        onAccessibilityChange?(now)
    }

    /// Asks for Accessibility: macOS's own prompt the first time (it only prompts while pane has no row in the list),
    /// afterwards the Privacy & Security ▸ Accessibility page.
    public func requestAccessibility() {
        let key = "pane.accessibilityPrompted"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        openAccessibilitySettings()
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Talks to the running agent from another pane process (D2: starting pane again opens its Settings; also
/// `--open-settings <page>`, `--restart`). A local message port; replies "ok".
public enum AgentLink {
    static let portName = "dev.pane.agent" as CFString
    nonisolated(unsafe) private static var port: CFMessagePort?
    nonisolated(unsafe) private static var handler: ((String) -> Void)?

    /// In the running agent: `handle` gets each message on the main thread. The name can still belong to a pane
    /// that is quitting (a restart starts the new pane before the old one has gone): keep trying until it's free.
    @MainActor public static func listen(_ handle: @escaping (String) -> Void, attempt: Int = 0) {
        handler = handle
        var context = CFMessagePortContext()
        let callback: CFMessagePortCallBack = { _, _, data, _ in
            let text = (data as Data?).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async { AgentLink.handler?(text) }
            return Unmanaged.passRetained("ok".data(using: .utf8)! as CFData)
        }
        guard let local = CFMessagePortCreateLocal(nil, portName, callback, &context, nil) else {
            if attempt == 0 { PaneLog.write("agent link busy (a pane is quitting); retrying") }
            guard attempt < 120 else { return } // 30 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { listen(handle, attempt: attempt + 1) } }
            return
        }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
        if attempt > 0 { PaneLog.write("agent link ready") }
    }

    /// From another process: true when the running agent got it.
    public static func send(_ message: String, timeout: TimeInterval = 2) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return false }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 0, message.data(using: .utf8)! as CFData, timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        reply?.release()
        return status == kCFMessagePortSuccess
    }
}
