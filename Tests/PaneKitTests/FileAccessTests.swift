// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import Testing
import PaneKit

/// Faked through PANE_FAKE_PERMISSIONS_FILE, as tests must never show macOS's prompts.
@Suite("File access (faked)", .serialized)
struct FileAccessTests {
    func withFake(_ text: String, _ body: (URL) async throws -> Void) async rethrows {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pane-fake-permissions-\(UUID().uuidString).txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let before = ProcessInfo.processInfo.environment["PANE_FAKE_PERMISSIONS_FILE"]
        setenv("PANE_FAKE_PERMISSIONS_FILE", file.path, 1)
        defer {
            if let before { setenv("PANE_FAKE_PERMISSIONS_FILE", before, 1) } else { unsetenv("PANE_FAKE_PERMISSIONS_FILE") }
            try? FileManager.default.removeItem(at: file)
        }
        try await body(file)
    }

    @Test func levels() async {
        await withFake("") { _ in #expect(FileAccess.level == .none && !FileAccess.askedForFolders) }
        await withFake("folders=granted") { _ in #expect(FileAccess.level == .folders) }
        await withFake("fullDiskAccess=granted") { _ in #expect(FileAccess.level == .full && FileAccess.foldersAllowed) }
    }

    @Test func askingForFoldersWithoutAPrompt() async {
        await withFake("") { _ in
            let granted = await withCheckedContinuation { c in FileAccess.requestFolders { c.resume(returning: $0) } }
            #expect(granted && FileAccess.level == .folders && FileAccess.askedForFolders)
        }
        await withFake("folders=deny") { _ in
            let granted = await withCheckedContinuation { c in FileAccess.requestFolders { c.resume(returning: $0) } }
            #expect(!granted && FileAccess.level == .none && FileAccess.askedForFolders)
        }
    }
}
