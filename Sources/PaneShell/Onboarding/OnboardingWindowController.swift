// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import SwiftUI
import PaneKit

/// First-run onboarding (Phase 3, D4): seven steps. Accessibility is required (Continue waits for it); everything
/// else can be skipped and changed later in Settings. Finishing writes the onboarding version (`Onboarding.markDone`).
@MainActor
public final class OnboardingModel: ObservableObject {
    public enum Step: String, CaseIterable, Sendable {
        case welcome, accessibility, previews, keyboard, conflicts, changes, login

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .accessibility: return "Accessibility"
            case .previews: return "Window previews"
            case .keyboard: return "Keyboard"
            case .conflicts: return "Other apps"
            case .changes: return "What pane changes"
            case .login: return "Start at login"
            }
        }
        var symbol: String {
            switch self {
            case .welcome: return "hand.wave"
            case .accessibility: return "accessibility"
            case .previews: return "rectangle.on.rectangle"
            case .keyboard: return "keyboard"
            case .conflicts: return "app.badge"
            case .changes: return "slider.horizontal.3"
            case .login: return "power"
            }
        }
    }

    public enum PreviewState: String { case granted, missing, skipped }

    public let store: SettingsStore
    @Published public var step: Step = .welcome { didSet { if step == .changes { changeRows = SystemChanges.describe(store) } } }
    @Published public private(set) var accessibility: Permissions.State = .missing
    @Published public private(set) var previews: PreviewState = .missing
    @Published var previewsSkipped = false
    @Published var previewsBusy = false
    @Published var previewNote: String?
    @Published public private(set) var conflicts: [Conflicts.App] = []
    @Published var ignored: Set<String> = []
    @Published public private(set) var macOSFeatures: [String] = []
    /// The changes step's rows, as they were when the step opened (a row stays when its switch is turned off).
    @Published var changeRows: [SystemChanges.Change] = []
    @Published public private(set) var revision = 0

    public var onFinish: (() -> Void)?
    /// The keyboard step's content (pane Pro's choice of keyboard); without it the step is left out.
    public var keyboardStep: (() -> AnyView)?
    /// A sentence after the welcome text (pane Pro: its trial).
    public var welcomeNote: String?
    /// The welcome's list of what pane brings (pane Pro adds its features).
    public var welcomeFeatures: [(text: String, symbol: String)] = [
        ("A taskbar with your apps, pinned and running", "dock.rectangle"),
        ("Snap windows by dragging them to an edge", "rectangle.split.2x1"),
        ("Alt+Tab between windows", "square.grid.2x2"),
    ]
    /// The steps shown.
    public var steps: [Step] { Step.allCases.filter { ($0 != .keyboard || keyboardStep != nil) && ($0 != .previews || previewsText != nil) } }
    /// The previews step's text: shown only when an extension offers window thumbnails (they need Screen Recording).
    public var previewsText: String?
    private var observation: SettingsObservation?

    public init(store: SettingsStore) {
        self.store = store
        observation = store.observeAll { [weak self] _ in self?.revision += 1 }
        refresh()
    }

    /// Re-reads permissions and running apps (every second while the window is open, and on permission changes).
    public func refresh() {
        accessibility = Permissions.shared.accessibility
        let available = PreviewClient.isAvailable
        previews = available ? .granted : (previewsSkipped ? .skipped : .missing)
        conflicts = Conflicts.runningApps()
        macOSFeatures = Conflicts.macOSFeatures()
    }

    var canContinue: Bool { step != .accessibility || accessibility == .granted }
    var isLast: Bool { step == steps.last }

    public func next() {
        guard canContinue else { return }
        if step == .previews && previews != .granted { previewsSkipped = true; refresh() }
        guard let i = steps.firstIndex(of: step) else { return }
        if i + 1 < steps.count { step = steps[i + 1] } else { finish() }
    }

    public func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    public func finish() {
        try? Onboarding.markDone(store)
        onFinish?()
    }

    func turnOnPreviews() {
        previewsBusy = true
        previewNote = nil
        Task { @MainActor in
            let started = await PreviewClient.launchHelper()
            previewsBusy = false
            if !started { previewNote = "pane's preview helper isn't installed on this Mac. Window lists show app icons instead." }
            refresh()
        }
    }

    /// The changes step: is this change on?
    func isOn(_ change: SystemChanges.Change) -> Bool { change.isOn(in: store) }

    func set(_ change: SystemChanges.Change, on: Bool) { change.turn(on, in: store) }
}

/// The onboarding window: steps on the left, the current one on the right, Back / Continue below.
@MainActor
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    private var timer: Timer?

    public init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Welcome to pane"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setAccessibilityIdentifier("pane.onboarding")
        window.contentView = NSHostingView(rootView: OnboardingRootView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public var isShown: Bool { window?.isVisible == true }

    public func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.refresh() } }
    }

    public func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
