// swift-tools-version: 6.0
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), Swift Testing ships as a framework outside the
// default search path, so the test target is pointed at it explicitly.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingFlags: (swift: [SwiftSetting], linker: [LinkerSetting]) =
    FileManager.default.fileExists(atPath: "\(cltFrameworks)/Testing.framework")
        ? ([.unsafeFlags(["-F", cltFrameworks])],
           [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                          "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])])
        : ([], [])

let package = Package(
    name: "pane",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaneKit", targets: ["PaneKit"]),
        .library(name: "PaneShell", targets: ["PaneShell"]),
        .library(name: "PaneApp", targets: ["PaneApp"]),
        .library(name: "PaneTestKit", targets: ["PaneTestKit"]),
        .executable(name: "pane", targets: ["pane"]),
        .executable(name: "PanePreview", targets: ["PanePreview"]),
        .executable(name: "PaneFixture", targets: ["PaneFixture"]),
        .executable(name: "pane-probe", targets: ["pane-probe"]),
        .executable(name: "pane-tests", targets: ["pane-tests"]),
    ],
    targets: [
        // Window primitives: AX, WindowServer (CGWindowList + SkyLight), focus, geometry, lifecycle.
        .target(name: "PaneKit"),
        // The UI: taskbar, Start, Alt+Tab, Settings, onboarding.
        .target(name: "PaneShell", dependencies: ["PaneKit"]),
        // The agent wired together (PaneAgent, PaneMain), with the extension points (PaneExtension, PaneHost).
        .target(name: "PaneApp", dependencies: ["PaneKit", "PaneShell"]),
        // The runnable agent: `PaneMain.run()` (run from Terminal).
        .executableTarget(name: "pane", dependencies: ["PaneApp"]),
        // Capture helper that holds the Screen Recording grant (installed by scripts/install-preview-helper.sh).
        .executableTarget(name: "PanePreview", dependencies: ["PaneKit"]),
        // A controllable AppKit app that tests launch and manipulate, so tests never touch the user's apps.
        .executableTarget(name: "PaneFixture"),
        // Manual probe CLI for poking at real apps.
        .executableTarget(name: "pane-probe", dependencies: ["PaneKit"]),
        // What the integration tests share (also for extensions' own tests): the fixture app, polling, findings, the
        // integration root suite, and launching and reading a test agent.
        .target(
            name: "PaneTestKit",
            dependencies: ["PaneKit", "PaneShell"],
            path: "Tests/PaneTestKit",
            swiftSettings: testingFlags.swift,
            linkerSettings: testingFlags.linker
        ),
        // Swift Testing suites, run as an executable (`swift run pane-tests`) rather than a testTarget:
        // with only the Command Line Tools, SwiftPM doesn't generate a Swift Testing entry point, so the
        // runner calls Testing's own entry point instead (Tests/PaneKitTests/main.swift).
        .executableTarget(
            name: "pane-tests",
            dependencies: ["PaneKit", "PaneShell", "PaneTestKit"],
            path: "Tests/PaneKitTests",
            swiftSettings: testingFlags.swift,
            linkerSettings: testingFlags.linker
        ),
    ],
    swiftLanguageModes: [.v5]
)
