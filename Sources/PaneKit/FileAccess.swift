// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit

/// What macOS keeps from an app until you allow it, for an optional feature (pane Pro's recent files): Full Disk
/// Access, or just the Desktop, Documents and Downloads folders. A denied permission turns off only what needs it.
///
/// Checked without prompting: Full Disk Access by reading a file only it opens; the folders only once pane has asked
/// for them (reading one before that is what makes macOS ask).
///
/// Tests fake it in PANE_FAKE_PERMISSIONS_FILE (`fullDiskAccess=granted`, `folders=granted` / `folders=denied`). A test
/// agent never shows macOS's prompts: asking for the folders there writes `folders=granted` to the file, or
/// `folders=denied` when the file says `folders=deny`.
public enum FileAccess {
    public enum Level: String, Sendable {
        /// Full Disk Access: every recent file, and the apps' "Open Recent" lists.
        case full
        /// Desktop, Documents and Downloads.
        case folders
        case none
    }

    public static var level: Level { hasFullDiskAccess ? .full : foldersAllowed ? .folders : .none }

    /// The fake file's text, when tests fake permissions.
    public static var fakeState: String? { fake }
    static var fake: String? {
        ProcessInfo.processInfo.environment["PANE_FAKE_PERMISSIONS_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }
    static var testAgent: Bool { ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] != nil }

    /// Full Disk Access: macOS's privacy database is readable (only Full Disk Access opens it; reading never prompts).
    public static var hasFullDiskAccess: Bool {
        if let fake { return fake.contains("fullDiskAccess=granted") }
        let tcc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tcc) else { return false }
        try? handle.close()
        return true
    }

    /// The three folders, once pane asked for them (not before: that would be the prompt).
    public static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
    }

    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static let askedKey = "pane.foldersAsked"
    public static var askedForFolders: Bool { fake.map { $0.contains("folders=") } ?? defaults.bool(forKey: askedKey) }

    public static var foldersAllowed: Bool {
        if let fake { return fake.contains("folders=granted") || fake.contains("fullDiskAccess=granted") }
        if hasFullDiskAccess { return true }
        guard askedForFolders, !testAgent else { return false }
        return folders.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }

    /// macOS's prompt for each folder, one after another, off the main thread; `done` on the main thread with whether
    /// all three are allowed.
    public static func requestFolders(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let path = ProcessInfo.processInfo.environment["PANE_FAKE_PERMISSIONS_FILE"] {
            let text = fake ?? ""
            let granted = !text.contains("folders=deny")
            try? (text + "\n" + (granted ? "folders=granted" : "folders=denied")).write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { done(granted) }
            return
        }
        guard !testAgent else {
            PaneLog.write("file access: no prompts in a test agent")
            DispatchQueue.main.async { done(false) }
            return
        }
        defaults.set(true, forKey: askedKey)
        DispatchQueue.global(qos: .userInitiated).async {
            // Reading a folder is what makes macOS ask (it waits for the answer).
            let allowed = folders.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }.allSatisfy { $0 }
            DispatchQueue.main.async { done(allowed) }
        }
    }

    /// Privacy & Security ▸ Full Disk Access, where you turn pane on (or add it with +).
    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    /// Privacy & Security ▸ Files and Folders (to change an answer to the folder prompts).
    public static func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
    }
}
