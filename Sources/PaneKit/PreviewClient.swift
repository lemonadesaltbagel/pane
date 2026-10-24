// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import CoreGraphics
import ImageIO

/// Window previews from wherever the Screen Recording grant lives: this process if it has it, otherwise the
/// PanePreview helper app (installed by scripts/install-preview-helper.sh), over a local CFMessagePort.
public enum PreviewClient {
    public static let portName = "dev.pane.preview"
    public static let bundleID = "dev.pane.preview"
    public static let protocolVersion = 1

    public static var helperURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pane/PanePreview.app")
    }

    public struct Status: Equatable {
        public let running: Bool
        public let permitted: Bool
    }

    public enum Source: String { case local, screenCaptureKit, privateCapture }

    /// CFMessagePort remotes are cached per name by CoreFoundation: invalidating one breaks every concurrent
    /// request to the same name (measured: parallel flyout loads all failed). So requests are serialized on one
    /// queue over one long-lived remote, recreated only when it's no longer valid.
    private static let queue = DispatchQueue(label: "pane.PreviewClient")
    nonisolated(unsafe) private static var remote: CFMessagePort?

    private static func request(_ object: [String: Any], timeout: TimeInterval) -> Data? {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return queue.sync { () -> Data? in
            if remote.map({ !CFMessagePortIsValid($0) }) ?? true { remote = CFMessagePortCreateRemote(nil, portName as CFString) }
            guard let remote else { return nil }
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(remote, 0, payload as CFData, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
            guard status == kCFMessagePortSuccess, let reply else {
                if status == kCFMessagePortIsInvalid { self.remote = nil }
                return nil
            }
            return reply.takeRetainedValue() as Data
        }
    }

    public static func helperStatus() -> Status {
        guard let data = request(["op": "status"], timeout: 1),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Status(running: false, permitted: false) }
        return Status(running: true, permitted: json["permitted"] as? Bool ?? false)
    }

    /// Starts the helper if it's installed and not running (LaunchServices launch, so the helper — not the
    /// terminal — is the responsible process for TCC).
    @discardableResult
    public static func launchHelper() async -> Bool {
        if helperStatus().running { return true }
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
        for _ in 0..<40 {
            if helperStatus().running { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Whether previews can be produced right now (locally or via the helper). The helper's answer is remembered for
    /// 30 s and refreshed in the background: asking it means queueing behind captures still in flight, which blocked
    /// Task View's opening for ~0.6 s with 120 windows (measured).
    public static var isAvailable: Bool {
        if Capture.hasScreenRecording { return true }
        let (known, at) = statusLock.withLock { (lastPermitted, lastStatusAt) }
        if let known {
            if Date().timeIntervalSince(at) > 30, statusLock.withLock({ !refreshing }) {
                statusLock.withLock { refreshing = true }
                DispatchQueue.global(qos: .utility).async {
                    let permitted = helperStatus().permitted
                    statusLock.withLock { lastPermitted = permitted; lastStatusAt = Date(); refreshing = false }
                }
            }
            return known
        }
        let permitted = helperStatus().permitted
        statusLock.withLock { lastPermitted = permitted; lastStatusAt = Date() }
        return permitted
    }
    private static let statusLock = NSLock()
    nonisolated(unsafe) private static var lastPermitted: Bool?
    nonisolated(unsafe) private static var lastStatusAt = Date.distantPast
    nonisolated(unsafe) private static var refreshing = false

    /// A preview of `wid` no larger than `maxDimension` points on its long side.
    public static func thumbnail(_ wid: CGWindowID, maxDimension: CGFloat = 320) async -> (CGImage, Source)? {
        if Capture.hasScreenRecording {
            if let image = try? await Capture.thumbnail(wid, maxDimension: maxDimension) { return (image, .local) }
            if let image = PrivateAPI.captureWindow(wid) { return (image, .local) }
        }
        guard let data = request(["op": "capture", "wid": Int(wid), "max": Double(maxDimension)], timeout: 3), data.count > 1,
              let source = CGImageSourceCreateWithData(data.dropFirst() as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, data.first == 0x53 ? .screenCaptureKit : .privateCapture)
    }
}
