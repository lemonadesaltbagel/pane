// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import CoreGraphics
import ImageIO
import PaneKit
import ScreenCaptureKit
import UniformTypeIdentifiers

// PanePreview — a tiny capture helper that holds the Screen Recording grant, so pane and its tests can get
// window previews while running from a terminal that can't be granted the permission.
//
// It is installed once (scripts/install-preview-helper.sh) and rarely rebuilt: an ad-hoc signed app keeps its
// TCC grant only while its code hash is unchanged. Clients talk to it over a local CFMessagePort
// (`PreviewClient` in PaneKit). Requests are JSON: {"op":"status"} or {"op":"capture","wid":N,"max":320}.
// Capture replies are PNG data; status replies are JSON.

let portName = PreviewClient.portName as CFString

func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

func scaled(_ image: CGImage, max dimension: CGFloat) -> CGImage {
    let scale = min(1, dimension / CGFloat(max(image.width, image.height)))
    guard scale < 1 else { return image }
    let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

/// ScreenCaptureKit for shareable (on-screen) windows; the private CGSHWCaptureWindowList for minimized and
/// other-Space windows, which SCK can't capture (DockDoor's approach).
func capture(_ wid: CGWindowID, max dimension: CGFloat) -> (CGImage, String)? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: CGImage?
    Task.detached {
        result = try? await Capture.thumbnail(wid, maxDimension: dimension)
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 2) == .success, let result { return (result, "screencapturekit") }
    if let image = PrivateAPI.captureWindow(wid) { return (scaled(image, max: dimension), "cgshw") }
    return nil
}

let callback: CFMessagePortCallBack = { _, _, data, _ in
    guard let data = data as Data?,
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let op = request["op"] as? String else { return nil }
    switch op {
    case "status":
        let status: [String: Any] = ["permitted": CGPreflightScreenCaptureAccess(), "pid": Int(getpid()), "version": PreviewClient.protocolVersion]
        return (try? JSONSerialization.data(withJSONObject: status)).map { Unmanaged.passRetained($0 as CFData) }
    case "capture":
        guard let wid = (request["wid"] as? NSNumber)?.uint32Value else { return nil }
        let dimension = (request["max"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 320
        guard let (image, source) = capture(wid, max: dimension), let encoded = png(image) else { return nil }
        // Reply: 1 byte source tag (S = ScreenCaptureKit, H = CGSHW) + PNG.
        var reply = Data([source == "screencapturekit" ? 0x53 : 0x48])
        reply.append(encoded)
        return Unmanaged.passRetained(reply as CFData)
    default:
        return nil
    }
}

guard let port = CFMessagePortCreateLocal(nil, portName, callback, nil, nil) else {
    FileHandle.standardError.write("PanePreview: port \(portName) is taken (already running?)\n".data(using: .utf8)!)
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if !CGPreflightScreenCaptureAccess() {
    // Shows the system prompt and adds PanePreview to System Settings ▸ Privacy & Security ▸ Screen Recording.
    _ = CGRequestScreenCaptureAccess()
}
app.run()
