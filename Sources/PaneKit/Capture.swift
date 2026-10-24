// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import CoreGraphics
import ScreenCaptureKit

public enum Capture {
    public static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    public enum Failure: Error { case windowNotShareable(CGWindowID) }

    /// Public path (AltTab on macOS 26+): ScreenCaptureKit single-window screenshot at thumbnail size.
    public static func thumbnail(_ wid: CGWindowID, maxDimension: CGFloat = 320) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == wid }) else { throw Failure.windowNotShareable(wid) }
        let scale = min(1, maxDimension / max(window.frame.width, window.frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }
}
