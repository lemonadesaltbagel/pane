// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import PaneKit
import PaneShell

// pane's agent (PaneApp): the engine wired together. `PaneMain.run()` starts it; the `pane` executable is just that.
// Run it from Terminal (Terminal's Accessibility grant covers it):
//
//   .build/debug/pane [--dry-run] [--duration SECONDS] [--lifecycle-scope BUNDLE_ID] [--restore-only]
//
//   --dry-run          don't touch system settings (no Dock reservation, native tiling stays on)
//   --duration N       quit after N seconds (smoke tests)
//   --lifecycle-scope  only ever quit apps with this bundle ID (repeatable; protects real apps while testing)
//   --restore-only     restore settings left behind by a crashed run, then exit
//
// Settings: ~/Library/Application Support/Pane/config.json, see `SettingsStore` and `PaneSettings` (PaneKit).
// Every system change is backed up first and restored on quit, Ctrl-C, SIGTERM, or the next launch after a crash.

struct Config {
    var barHeight: Double = 48
    var replaceDock = true
    var takeOverTiling = true
    var quitOnLastWindow = true
    var optOut: [String] = []
    var pinned: [String]? = nil
    /// Pinned apps are the Dock's (setting `taskbar.syncDockPins`).
    var syncDockPins = false
    /// Windows' "Automatically hide the taskbar" (setting `taskbar.autoHide`).
    var autoHide = false
    /// Windows "Combine taskbar buttons": "always" (Windows default), "whenFull", "never".
    var combineButtons: CombineMode = .always
    /// Windows click-through: the first click on an inactive window activates it AND acts.
    var clickThrough = true
    /// Shortcuts the user rebound (settings `keys.*`; nil = turned off).
    var bindings: [Shortcut: KeyBinding?] = [:]
    /// Apps whose own keys win (pane's chords stand down).
    var ignoredApps: Set<String> = []
    /// ⌘Tab opens pane's window switcher (setting `switcher.replaceCommandTab`).
    var commandTabSwitcher = false

    init() {}

    /// The settings in effect at launch (`SettingsStore`: config.json v2, v1 files read as before).
    @MainActor init(_ store: SettingsStore) {
        barHeight = store[PaneSettings.barHeight]
        replaceDock = store[PaneSettings.replaceDock]
        takeOverTiling = store[PaneSettings.takeOverTiling]
        quitOnLastWindow = store[PaneSettings.quitOnLastWindow]
        optOut = Set(store.overrides(PaneSettings.quitOnLastWindow).filter { !$0.value }.map(\.key)).sorted()
        pinned = store[PaneSettings.pinned]
        syncDockPins = store[PaneSettings.syncDockPins]
        autoHide = store[PaneSettings.autoHide]
        combineButtons = CombineMode(rawValue: store[PaneSettings.combineButtons]) ?? .always
        clickThrough = store[PaneSettings.clickThrough]
        for action in Shortcut.allCases where !store.isDefault(action.setting) { bindings[action] = store[action.setting] }
        ignoredApps = store.apps(PaneSettings.ignoreShortcuts) { $0 == "always" }
        commandTabSwitcher = store[PaneSettings.replaceCommandTab]
    }

    /// Apps an extension says pane leaves alone (pane Pro's App exceptions): never quit, and pane's keys stand down.
    mutating func leaveAlone(_ apps: Set<String>) {
        optOut = Set(optOut).union(apps).sorted()
        ignoredApps.formUnion(apps)
    }
}

/// Timestamped (UTC, as the soak's log), so a test's record lines up with the agent's.
func log(_ message: String) {
    PaneLog.write(message)
    TrayLog.file("[pane] \(message)\n") // advanced.debugLog
}

/// Test agents: logs when the main thread doesn't answer for over 2 s (the soak saw pane's windows not appear for
/// ~25 s once; this says whether pane was blocked).
enum MainThreadWatchdog {
    static func start() {
        let queue = DispatchQueue(label: "pane.watchdog", qos: .utility)
        func ping() {
            let sent = Date()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            queue.async {
                if answered.wait(timeout: .now() + 2) == .timedOut {
                    answered.wait()
                    log(String(format: "main thread stalled for %.1f s", Date().timeIntervalSince(sent)))
                }
                queue.asyncAfter(deadline: .now() + 1) { ping() }
            }
        }
        queue.async { ping() }
    }
}

struct Arguments {
    var dryRun = false
    var duration: TimeInterval?
    var lifecycleScope: Set<String>?
    /// Tests: virtual desktops manage only these bundles' windows.
    var desktopScope: Set<String>?
    /// Tests: the taskbar lists only these bundles' windows.
    var taskbarScope: Set<String>?
    var restoreOnly = false
    /// Started by a restart handover: adopt the previous pane's system changes.
    var takeover = false

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--dry-run": dryRun = true
            case "--duration": duration = it.next().flatMap(TimeInterval.init)
            case "--lifecycle-scope": lifecycleScope = (lifecycleScope ?? []).union([it.next() ?? ""])
            case "--desktop-scope": desktopScope = (desktopScope ?? []).union([it.next() ?? ""])
            case "--taskbar-scope": taskbarScope = (taskbarScope ?? []).union([it.next() ?? ""])
            case "--restore-only": restoreOnly = true
            case "--open-settings": _ = it.next() // handled once running (or by the running agent)
            case "--restart": break
            case "--takeover": takeover = true
            default: log("unknown argument \(arg)")
            }
        }
    }
}

@MainActor
final class PaneAgent: NSObject, NSApplicationDelegate {
    /// Settings (config.json). Read at launch; changes to `.restart` settings apply after a restart.
    /// PANE_CONFIG: another config file (tests use a copy, so they never change your settings).
    let prefs = SettingsStore(url: ProcessInfo.processInfo.environment["PANE_CONFIG"].map { URL(fileURLWithPath: $0) } ?? SettingsStore.defaultURL)
    lazy var config = Config(prefs)
    var settingsWatch: SettingsObservation?
    var liveSettings: [SettingsObservation] = []
    var dockShield: DockHoverShield?
    var dockSignals: DockSignals?
    var preRestartBadges: [String: String] = [:]
    let args = Arguments(CommandLine.arguments)
    let settings = SystemSettings()
    let inventory = WindowInventory()
    let lifecycle = LifecycleService()
    let snap = SnapService()
    var hotkeys: HotkeyService!
    let history = FocusHistory()
    var switcher: SwitcherController!
    var commandSwitcher: SwitcherController?
    var switcherPanel: SwitcherPanel!
    /// Pro's features (none in the Free build), and what they may use.
    let extensions: [PaneExtension]
    private(set) var host: PaneHost?

    init(extensions: [PaneExtension] = []) {
        self.extensions = extensions
        super.init()
    }
    let catalog = AppCatalog()
    /// pane's own menu-bar icon (`general.showMenuBarIcon`); the menu-bar tray's chevron stands in for it.
    var menuBarIcon: MenuBarIcon?
    let iconMenu = MenuBarIcon()
    let clickThrough = ClickThroughService()
    let fullScreen = FullScreenService()
    /// Which windows are on the current virtual desktop (Pro's desktops answer; all without them).
    let desktopMembership = DesktopMembership()
    /// Windows already in macOS full screen when pane started: left alone (only new ones are converted).
    var taskbar: TaskbarPanel!
    var preview: SnapPreviewOverlay!
    var signalSources: [DispatchSourceSignal] = []
    var restored = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The edition first: Free's locks must be in place before anything reads the settings.
        launchExtensions()
        if ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] != nil { MainThreadWatchdog.start() }
        // Another pane process (started again, `--open-settings`, `--restart`) talks to this one.
        AgentLink.listen { [weak self] message in self?.handleLink(message) }
        // `pane --open-settings <page>` as the first pane (also how a restart from Settings reopens it).
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--open-settings") {
            let page = arguments.indices.contains(i + 1) && !arguments[i + 1].hasPrefix("--") ? arguments[i + 1] : nil
            DispatchQueue.main.async { [weak self] in self?.openSettings(page: page) }
        }
        let permissions = Permissions.shared
        permissions.onAccessibilityChange = { [weak self] state in self?.accessibilityChanged(state) }
        permissions.start()
        // First run (or a new onboarding version): the welcome. Test agents only when a test asks (PANE_ONBOARDING=1):
        // some run on your own config, which may not have finished onboarding yet.
        let env = ProcessInfo.processInfo.environment
        let onboarding = !args.restoreOnly && Onboarding.isNeeded(prefs) && (env["PANE_DEFAULTS_SUITE"] == nil || env["PANE_ONBOARDING"] == "1")
        if onboarding { showOnboarding() }
        // `--restore-only` puts settings back and exits, with or without Accessibility.
        guard permissions.accessibility == .granted || args.restoreOnly else {
            // No Accessibility yet: stay up (onboarding runs here) and start as soon as it's granted.
            log("waiting for Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility); pane starts by itself once it's on")
            // Onboarding asks in its own step; otherwise ask now.
            if !onboarding && env["PANE_FAKE_PERMISSIONS_FILE"] == nil { permissions.requestAccessibility() }
            return
        }
        startServices()
    }

    // MARK: Permissions and the agent link

    var servicesStarted = false
    var suspended = false

    func accessibilityChanged(_ state: Permissions.State) {
        onboardingWindow?.model.refresh()
        switch state {
        case .granted where !servicesStarted:
            log("Accessibility granted: starting")
            // Starting takes a moment (the Dock restarts): let onboarding show "Allowed" first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startServices() }
        case .granted where suspended:
            // Taps are rebuilt from scratch after a revoke: restart.
            log("Accessibility granted again: restarting")
            restart()
        case .missing where servicesStarted && !suspended:
            suspendForRevoke()
        default:
            break
        }
    }

    /// Accessibility was taken away while running: event taps without it can stall input, so every key and mouse
    /// handler stops now. The taskbar stays (it doesn't need Accessibility to draw).
    func suspendForRevoke() {
        suspended = true
        hotkeys?.stop()
        switcher?.stop()
        commandSwitcher?.stop()
        extensions.forEach { $0.suspend() }
        snap.stop()
        clickThrough.stop()
        dockShield?.stop()
        log("Accessibility revoked: pane's keyboard and mouse handling stopped")
    }

    /// Messages from another pane process.
    func handleLink(_ message: String) {
        if message.hasPrefix("open-settings") {
            let page = message.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            // Started again before finishing the welcome: the welcome again.
            if page.isEmpty && Onboarding.isNeeded(prefs) && onboardingWindow != nil { showOnboarding(); return }
            openSettings(page: page.isEmpty ? nil : page)
        } else if message == "restart" {
            restart()
        } else if message == "start:toggle" {
            showStartMenu()
        } else if message == "start:hide" {
            startMenu?.hide()
        } else if message.hasPrefix("start-search:") {
            startMenu?.show(search: String(message.dropFirst("start-search:".count)))
        } else if message == "recording:on" {
            ShortcutRecording.begin(); log("recording a shortcut: pane's keys stand down")
        } else if message == "recording:off" {
            ShortcutRecording.end(); log("recording ended")
        } else if extensions.contains(where: { $0.handle(message) }) {
        } else {
            log("link: unknown message \(message)")
        }
    }

    // MARK: Extensions (Pro)

    /// At launch: the host and each extension's `launch` (pane Pro's licensing sets the edition first thing).
    func launchExtensions() {
        guard !extensions.isEmpty else { log("edition: Free"); return }
        let host = PaneHost(prefs: prefs, inventory: inventory, taskbar: nil, fullScreen: fullScreen, snap: snap, history: history,
                            scope: args.desktopScope, desktops: desktopMembership, log: { log($0) })
        self.host = host
        host.isPro = { [weak self] in self?.isPro ?? false }
        host.editionChanged = { [weak self] edition, summary, page in self?.editionChanged(edition, summary: summary, reopenSettings: page) ?? false }
        host.menuBarMenu = { [weak self] in self?.iconMenu.makeMenu() ?? NSMenu() }
        for e in extensions { e.launch(host) }
        if !editionReported { log("edition: Free") }
        config.leaveAlone(host.leftAlone)
    }

    /// Right after the taskbar is made: each extension's `prepare`.
    func prepareExtensions() {
        guard let host else { return }
        host.taskbar = taskbar
        for e in extensions { e.prepare(host) }
    }

    func startExtensions() {
        guard let host else { return }
        host.isHidden = { [live] in live.hidden.contains($0) }
        host.hotkeys = hotkeys
        host.switcherPanel = switcherPanel
        host.startMenu = startMenu
        host.openSettings = { [weak self] page in self?.openSettings(page: page) }
        host.toggleShowDesktop = { [weak self] in self?.toggleShowDesktop() }
        for e in extensions { e.start(host) }
        log("extensions: \(extensions.map(\.name).joined(separator: ", "))")
    }

    // MARK: Edition

    /// pane Pro (a license or the trial): only pane Pro's licensing says so, with the settings it locks otherwise.
    /// The Free build has no editions: nothing is locked.
    var isPro = false
    var editionReported = false

    /// The edition changed (the trial ended, a key was added or removed): locked settings follow at once; launch-time
    /// ones (the tray, desktops, the Windows keyboard…) with a restart, which also brings parked windows and hidden
    /// icons back. True when restarting.
    func editionChanged(_ edition: PaneHost.EditionChange, summary: String, reopenSettings: String?) -> Bool {
        editionReported = true
        log("edition: \(summary)")
        let changed = edition.isPro != isPro || edition.locks != prefs.locks
        isPro = edition.isPro
        prefs.setLocks(edition.locks, userOverrides: edition.lockingOverrides)
        settingsWindow?.model.refresh()
        let pending = changed && servicesStarted ? pendingRestart : []
        guard !pending.isEmpty else { return false }
        log("edition changed: restarting for \(pending.sorted())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restart(reopenSettings: reopenSettings) }
        return true
    }

    /// Onboarding (Phase 3): shown at first run, by "Show welcome again", and on a second start before it's finished.
    var onboardingWindow: OnboardingWindowController?
    func showOnboarding() {
        log("onboarding shown")
        if onboardingWindow == nil {
            let model = OnboardingModel(store: prefs)
            model.onFinish = { [weak self] in self?.onboardingFinished() }
            extensions.forEach { $0.configureOnboarding(model) }
            onboardingWindow = OnboardingWindowController(model: model)
        } else if onboardingWindow?.isShown == false {
            onboardingWindow?.model.step = .welcome // "Show welcome again" starts over; a second start keeps the step
        }
        onboardingWindow?.show()
    }

    /// Choices that only apply at launch (keyboard, Dock…) take effect with a restart, done here so the setup is complete.
    func onboardingFinished() {
        let pending = servicesStarted ? pendingRestart : []
        log("onboarding finished\(pending.isEmpty ? "" : "; restarting for \(pending.sorted())")")
        onboardingWindow?.close()
        if !pending.isEmpty { restart() }
    }

    /// The Settings window (made on first use, then reused). `onOpenSettings` is a hook for tests and onboarding.
    var settingsWindow: SettingsWindowController?
    var onOpenSettings: ((String?) -> Void)?
    func openSettings(page: String?) {
        log("open settings\(page.map { " (\($0))" } ?? "")")
        if settingsWindow == nil {
            let model = SettingsModel(store: prefs)
            model.pendingRestart = { [weak self] in self?.pendingRestart ?? [] }
            model.onRestart = { [weak self] page in self?.restart(reopenSettings: page) }
            model.backupSections = startStore.map { [$0.backupSection] } ?? []
            model.onShowWelcome = { [weak self] in self?.showOnboarding() }
            extensions.forEach { $0.configureSettings(model) }
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show(page: page)
        onOpenSettings?(page)
    }

    /// Restarts pane as a handover (E3): the Dock, tiling and their backup stay as they are and the new pane adopts
    /// them (`--takeover`), so the Dock isn't restored and re-applied (no flicker, no windows moving). pane's own
    /// menu-bar items do go away for the moment the restart takes.
    /// `reopenSettings`: the page the Settings window was on (restarting from its restart bar opens it again there).
    func restart(reopenSettings: String? = nil) {
        log("restarting (pending: \(pendingRestart.sorted()))")
        shutdown(keepSystemChanges: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var arguments: [String] = []
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            if a == "--open-settings" { if let next = it.next(), next.hasPrefix("--") { arguments.append(next) }; continue }
            if a != "--takeover" && a != "--restart" { arguments.append(a) }
        }
        if let page = reopenSettings { arguments += ["--open-settings", page] }
        process.arguments = arguments + ["--takeover"]
        flock(PaneMain.instanceLock, LOCK_UN)
        try? process.run()
        exit(0)
    }

    /// `.restart` settings as they were when this pane started; `pendingRestart` = the ones changed since.
    lazy var launchRestartValues: [String: JSONValue] = Dictionary(uniqueKeysWithValues:
        PaneSettings.all.filter { $0.info.status == .restart }.map { ($0.id, prefs.json($0.id) ?? .null) })
    var pendingRestart: Set<String> {
        Set(launchRestartValues.filter { prefs.json($0.key) != $0.value }.map(\.key))
    }

    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        for issue in prefs.issues { log("settings: \(issue)") }
        // Settings edited while pane runs: `.live` ones are observed where they're used; the rest need a restart.
        prefs.watchFile()
        settingsWatch = prefs.observeAll { id in
            if PaneSettings.setting(id: id)?.info.status == .restart { log("settings: \(id) changed; takes effect when pane restarts") }
        }
        _ = launchRestartValues // snapshot before anything changes
        if settings.hasPendingBackup {
            // A restart handover keeps the Dock and tiling as the previous pane left them (no flicker) — unless these
            // settings no longer want them changed, then they're restored as after a crash.
            if args.takeover && config.replaceDock && config.takeOverTiling {
                log("taking over from the previous pane (system settings kept)")
            } else {
                log("restoring system settings left by a previous run")
                DockReservation(settings: settings).restore()
            }
        }
        let unparked = ParkedWindows.recoverIfNeeded()
        if unparked > 0 { log("brought back \(unparked) windows parked by a previous run") }
        // A previous run that crashed in the Windows keyboard may have left macOS's ⌘Tab off: on until pane takes it.
        for key in [PrivateAPI.SymbolicHotKey.commandTab, .commandShiftTab] { PrivateAPI.setSymbolicHotKey(key, enabled: true) }
        if args.restoreOnly { exit(0) }
        installSignalHandlers()

        var height = CGFloat(config.barHeight)
        if !args.dryRun {
            do {
                if config.takeOverTiling { try settings.apply(NativeTakeover.changes) }
                if config.replaceDock && config.autoHide {
                    // Auto-hide: nothing is reserved (windows use the whole screen); the Dock hides too, and the Dock
                    // shield keeps the bottom edge for pane's bar.
                    preRestartBadges = DockSignals.currentBadges()
                    let before = DockReservation.bottomInset()
                    try settings.apply([.init("com.apple.dock", "autohide", .bool(true))])
                    _ = DockReservation.waitForInset(changingFrom: before, timeout: 4) // the Dock restarts: wait for it
                } else if config.replaceDock {
                    preRestartBadges = DockSignals.currentBadges() // the Dock forgets them when it restarts
                    height = try DockReservation(settings: settings).apply(height: height)
                }
            } catch {
                log("could not apply system settings: \(error)")
            }
        }
        log("bar height \(height) (bottom inset \(DockReservation.bottomInset()))")

        // Taskbar over the reserving Dock.
        let pinned = config.syncDockPins ? DockPins.read() : (config.pinned ?? DockPins.read())
        taskbar = TaskbarPanel(inventory: inventory, height: height, pinned: pinned, history: history, mode: config.combineButtons)
        // Extensions that shape the bar (Pro's tray) attach before it shows.
        prepareExtensions()
        taskbar.includedBundles = args.taskbarScope
        taskbar.onShowDesktop = { [weak self] in self?.toggleShowDesktop() }
        taskbar.onTaskbarSettings = { [weak self] in self?.openSettings(page: "taskbar") }
        applyLiveSettings()
        liveSettings.append(prefs.observeAll { [weak self] _ in self?.applyLiveSettings() })
        taskbar.onPinnedChanged = { [weak self] list in
            guard let self else { return }
            do { try self.prefs.set(PaneSettings.pinned, list) } catch { log("could not save pinned apps: \(error)") }
            // Synced with the Dock: its pinned apps follow (the Dock restarts once, off the main thread).
            if self.prefs[PaneSettings.syncDockPins] {
                DispatchQueue.global(qos: .utility).async { if DockPins.write(list) { log("Dock's pinned apps updated") } }
            }
        }
        liveSettings.append(prefs.observe(PaneSettings.syncDockPins) { [weak self] on in
            if on { self?.taskbar.replacePinned(DockPins.read()) }
        })
        // Badges, progress and attention from the Dock's tiles (it runs under the bar), shown on the taskbar's buttons.
        if config.replaceDock, !Set((ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").split(separator: ",").map(String.init)).contains("docksignals") {
            let signals = DockSignals()
            signals.onChange = { [weak self] all in MainActor.assumeIsolated { self?.taskbar.signals = all } }
            signals.carryOver(preRestartBadges)
            signals.start()
            dockSignals = signals
        }
        // The Dock under the bar must not see the pointer over the bar (it would show its app labels on top of it).
        if config.replaceDock {
            let shield = DockHoverShield(barLevel: TaskbarPanel.level.rawValue)
            shield.start()
            taskbar.onBarFrame = { shield.setBar($0) }
            shield.setTaskbarAutoHide(config.autoHide)
            dockShield = shield
        }
        taskbar.autoHide = config.autoHide
        // Appearance settings: alignment applies live; glass vs solid too.
        taskbar.alignment = TaskbarPanel.Alignment(rawValue: prefs[PaneSettings.alignment]) ?? .center
        taskbar.solidBackground = prefs[PaneSettings.material] == "solid"
        liveSettings.append(prefs.observe(PaneSettings.alignment) { [weak self] value in
            self?.taskbar.alignment = TaskbarPanel.Alignment(rawValue: value) ?? .center
        })
        liveSettings.append(prefs.observe(PaneSettings.material) { [weak self] value in self?.taskbar.solidBackground = value == "solid" })
        taskbar.show()

        // The taskbar shows the current virtual desktop's windows (Pro's desktops; all without them).
        taskbar.windowFilter = { [desktopMembership] window in desktopMembership.isOnCurrent(window.id, for: .taskbar) }

        // Lifecycle (opt-out).
        lifecycle.optOut = Set(config.optOut)
        log("quit-on-last-window opt-outs: \(config.optOut)")
        lifecycle.scope = args.lifecycleScope
        lifecycle.onDecision = { _, bundle, decision in log("lifecycle \(bundle ?? "?"): \(decision)") }

        inventory.onChange = { [weak self] windows in
            MainActor.assumeIsolated {
                self?.taskbar.update(windows)
                self?.history.update(windows)
                self?.fullScreen.focusChanged(to: windows.first(where: \.isFocused)?.id)
                // A window focused while the desktop is shown: the next Show desktop starts over (Windows).
                if self?.showDesktop.isShowingDesktop == true, windows.contains(where: { $0.isFocused && !$0.isMinimized }) { self?.showDesktop.reset() }
                self?.fullScreen.prune(alive: Set(windows.map(\.id)))
                if let self, Date().timeIntervalSince(self.lastPlacementPrune) > 60 {
                    self.lastPlacementPrune = Date()
                    let alive = Set(WindowServer.windows(onScreenOnly: false).map(\.id))
                    self.snap.forgetClosed(alive: alive)
                }
                self?.extensions.forEach { $0.windowsChanged(windows) }
                if self?.config.quitOnLastWindow == true { self?.lifecycle.inventoryChanged(windows) }
            }
        }
        inventory.start()
        // pane started with windows reaching under where the taskbar now is (an auto-hidden Dock let them go to the
        // bottom): move them back into the work area, as Windows does.
        if config.replaceDock, !config.autoHide, !args.dryRun {
            let moved = WorkAreaAdoption.adopt(inventory.refreshNow()) { [inventory] in inventory.element(for: $0) }
            if moved > 0 { log("moved \(moved) window(s) out from under the taskbar") }
        }

        // Snapping + preview, Snap Layouts (green-button hover) and Snap Assist — harness menus.
        preview = SnapPreviewOverlay()
        snap.onPreview = { [weak self] rect in MainActor.assumeIsolated { self?.preview.show(rect) } }
        // Snap Layouts, Snap Assist and shake answer the snap service's events: Pro's (an extension).
        // Off unless pane Pro's extension turns them on (it reads their settings).
        snap.layoutsOnHover = false
        snap.assistEnabled = false
        snap.topDragLayouts = false
        snap.shakeEnabled = false
        // Hover pop-ups and thumbnails are pane Pro's live previews.
        taskbar.showHoverPreviews = false
        snap.isExcluded = { [live] pid in
            guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return live.noSnap.contains(bundle)
        }
        // Restore frames survive a pane restart (test agents keep their own file).
        let testAgent = ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] != nil
        snap.persistURL = ProcessInfo.processInfo.environment["PANE_PLACEMENTS_FILE"].map { URL(fileURLWithPath: $0) }
            ?? (testAgent ? FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-placements.json")
                          : SettingsStore.defaultURL.deletingLastPathComponent().appendingPathComponent("placements.json"))
        if !Set((ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").split(separator: ",").map(String.init)).contains("snap") {
            do { try snap.start() } catch { log("mouse tap refused: \(error)") }
        }

        // Windows full screen (⌃⌘F). Converting macOS full screen back to the desktop is Pro's (an extension).
        fullScreen.onTaskbarSuppressed = { [weak self] hidden in
            MainActor.assumeIsolated {
                self?.taskbar.suppressed = hidden
                // Windows-style full screen auto-hides the Dock; it must not slide up at the bottom edge either.
                self?.dockShield?.setFullScreen(hidden)
            }
        }

        // Click-through (Windows: one click activates and acts).
        // Tests: PANE_DISABLE=clickthrough,snap,keys switches services off (bisecting event-tap interactions).
        let disabled = Set((ProcessInfo.processInfo.environment["PANE_DISABLE"] ?? "").split(separator: ",").map(String.init))
        if config.clickThrough && !disabled.contains("clickthrough") {
            do { try clickThrough.start() } catch { log("click-through tap refused: \(error)") }
        }

        // Keyboard.
        var options = HotkeyService.Options()
        options.bindings = config.bindings
        options.ignoredApps = config.ignoredApps
        // The Windows keyboard's Ctrl layer is Pro's (an extension); its ⌘ = Win chords are the preset's bindings.
        hotkeys = HotkeyService(options: options, snap: snap)
        catalog.reload()
        setUpStart()
        hotkeys.onStart = { [weak self] in self?.showStartMenu() }
        taskbar.onStart = { [weak self] in self?.showStartMenu() }
        hotkeys.onShowDesktop = { [weak self] in self?.toggleShowDesktop() }
        hotkeys.onSettings = { [weak self] in self?.openSettings(page: nil) }
        hotkeys.onFileExplorer = { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }
        hotkeys.onScreenshot = { log("keys: screenshot"); _ = Screenshot.perform() }
        hotkeys.onFullScreenKey = { [weak self] in
            guard let pid = AX.frontmostPID(), let window = AX.focusedWindow(of: pid) else { return }
            DispatchQueue.global(qos: .userInitiated).async { self?.fullScreen.toggle(window) }
        }
        // Alt+Tab's panel exists for the extensions (pane Pro's previews turn its thumbnails on).
        switcherPanel = SwitcherPanel()
        switcherPanel.showsPreviews = false
        startExtensions()
        // macOS's own ⌘Tab wins over every event tap: switched off while an extension's shortcut is on ⌘Tab (pane Pro's
        // Task View in the Windows keyboard) or the switcher has it, and switched on at every other launch (a crash
        // must not leave it off) and at quit.
        let commandTab = KeyBinding([.cmd], "tab")
        let ownsCommandTab = hotkeys.binds(commandTab) || config.commandTabSwitcher
        for key in [PrivateAPI.SymbolicHotKey.commandTab, .commandShiftTab] { PrivateAPI.setSymbolicHotKey(key, enabled: !ownsCommandTab) }
        if ownsCommandTab { log("⌘Tab opens \(config.commandTabSwitcher ? "pane's window switcher" : "an extension's shortcut") (macOS's app switcher is off while pane runs)") }
        // Alt mode: an extension that shows the window's menus (Pro's strips) answers first, else the app's menu bar.
        hotkeys.menuMnemonics = { [weak self] in
            MainActor.assumeIsolated { self?.extensions.lazy.compactMap { $0.menuMnemonics() }.first ?? MirroredMenu.focusedWindowMnemonics() }
        }
        hotkeys.onMenuMnemonic = { [weak self] index in
            MainActor.assumeIsolated {
                if self?.extensions.contains(where: { $0.openMenu(index) }) != true { MirroredMenu.popUpFocusedWindowMenu(index) }
            }
        }
        hotkeys.onTaskbarIndex = { [weak self] index in self?.activateTaskbarItem(index) }
        do { try hotkeys.start() } catch { log("key tap refused: \(error)") }

        // Alt+Tab (⌥Tab), replacing AltTab (decision 7).
        var switcherOptions = SwitcherController.Options()
        switcherOptions.ignoredApps = config.ignoredApps
        switcher = SwitcherController(inventory: inventory, history: history, options: switcherOptions)
        switcher.windowFilter = { [live, desktopMembership] window in
            !live.hidden.contains(window.bundleID ?? "") && desktopMembership.isOnCurrent(window.id, for: .switcher)
        }
        switcher.onShow = { [weak self] items, selected in self?.switcherPanel.show(items, selected: selected) }
        switcher.onSelect = { [weak self] index in self?.switcherPanel.select(index) }
        switcher.onHide = { [weak self] _ in self?.switcherPanel.hide() }
        switcherPanel.onHover = { [weak self] index in self?.switcher.setSelection(index) }
        switcherPanel.onChoose = { [weak self] index in self?.switcher.choose(index) }
        do { try switcher.start() } catch { log("switcher tap refused: \(error)") }
        if config.commandTabSwitcher {
            var options = SwitcherController.Options()
            options.modifier = .maskCommand
            options.ignoredApps = config.ignoredApps
            let commandSwitcher = SwitcherController(inventory: inventory, history: history, options: options)
            commandSwitcher.windowFilter = switcher.windowFilter
            commandSwitcher.onShow = { [weak self] items, selected in self?.switcherPanel.show(items, selected: selected) }
            commandSwitcher.onSelect = { [weak self] index in self?.switcherPanel.select(index) }
            commandSwitcher.onHide = { [weak self] _ in self?.switcherPanel.hide() }
            do { try commandSwitcher.start(); self.commandSwitcher = commandSwitcher; log("⌘Tab opens pane's window switcher") }
            catch { log("⌘Tab switcher tap refused: \(error)") }
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.lwouis.alt-tab-macos").isEmpty {
            log("AltTab is running: pane's ⌥Tab takes precedence, but quit AltTab to avoid two switchers")
        }

        // Window previews come from the PanePreview helper (it holds the Screen Recording grant).
        Task {
            let started = await PreviewClient.launchHelper()
            log(started ? "previews: helper \(PreviewClient.helperStatus().permitted ? "ready" : "running but not permitted")" : "previews: helper not installed (scripts/install-preview-helper.sh); flyouts show title lists")
        }

        if let duration = args.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { NSApp.terminate(nil) }
        }
        log("running (pid \(getpid())); Ctrl-C to quit and restore settings")
    }

    // MARK: Start

    /// The Start menu: made at start-up so the first open is instant.
    var startMenu: StartMenuController?
    var startStore: StartStore?

    func setUpStart() {
        // Test agents keep their own Start file (pins, launch counts), never yours.
        let env = ProcessInfo.processInfo.environment
        let url = env["PANE_START_FILE"].map { URL(fileURLWithPath: $0) }
            ?? (env["PANE_DEFAULTS_SUITE"] != nil ? FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-start.json") : StartStore.defaultURL)
        let store = StartStore(url: url)
        let index = AppIndex(store: store)
        index.startWatching()
        let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
        store.ensurePinned(StartStore.defaultPins(installed: Set(index.apps.map(\.id)), browser: browser, taskbar: taskbar?.pinned ?? []))
        let model = StartMenuModel(index: index, store: store, prefs: prefs)
        model.isPinnedToTaskbar = { [weak self] id in self?.taskbar?.isPinned(id) ?? false }
        model.setPinnedToTaskbar = { [weak self] id, pin in self?.taskbar?.setPinned(id, pin) }
        model.onOpenPaneSettings = { [weak self] page in self?.openSettings(page: page) }
        model.onOpened = { what in log("start: opened \(what)") }
        let controller = StartMenuController(model: model)
        controller.anchor = { [weak self] in
            guard let self, let taskbar = self.taskbar else { return (48, nil, false) }
            return (CGFloat(self.config.barHeight), taskbar.startButtonFrame, self.prefs[PaneSettings.alignment] == "left")
        }
        startMenu = controller
        startStore = store
        settingsWindow?.model.backupSections.insert(store.backupSection, at: 0)
        // Quick Link (Win+X) is Pro's (an extension). Without it, right-clicking Start shows what Pro adds.
        taskbar.onStartRightClick = { [weak self] in self?.openSettings(page: "pro") }
    }

    /// Start (⌘ tap or the Start button): pane's Start, or macOS's Apps panel (setting `start.menu`).
    func showStartMenu() {
        if ProcessInfo.processInfo.environment["PANE_DEBUG_START"] != nil { log("start: requested (\(prefs[PaneSettings.startMenu]))") }
        if prefs[PaneSettings.startMenu] == "apps" {
            // Never during an icon capture (re-hiding the menu-bar icons closes the panel); opening is verified,
            // retried and, if Spotlight is wedged, recovered (AppsPanel.toggleVerified).
            Task { @MainActor in
                for _ in 0..<30 where taskbar.isCapturingIcons { try? await Task.sleep(nanoseconds: 100_000_000) }
                let shown = await AppsPanel.toggleVerified()
                if ProcessInfo.processInfo.environment["PANE_DEBUG_START"] != nil { log("start: Apps shown \(shown), Spotlight restarts \(AppsPanel.spotlightRestarts)") }
            }
            return
        }
        guard let startMenu else { return }
        startMenu.toggle()
        if startMenu.isShown { log(String(format: "start: shown in %.0f ms", startMenu.lastOpenMilliseconds)) } else { log("start: hidden") }
    }

    /// ⌘N (Win+N): app position N. No windows → launch; one → its click; several → the most recent window
    /// first, and pressing ⌘N again within 1.5 s cycles through that app's windows (flyout shown as a hint).
    let numberCycle = GroupCycle()

    // MARK: Live settings

    /// Settings read off the main thread (Alt+Tab's filter runs on its key tap's thread).
    final class LiveSettings: @unchecked Sendable {
        private let lock = NSLock()
        private var _hidden: Set<String> = [], _noSnap: Set<String> = []
        var hidden: Set<String> { get { lock.withLock { _hidden } } set { lock.withLock { _hidden = newValue } } }
        var noSnap: Set<String> { get { lock.withLock { _noSnap } } set { lock.withLock { _noSnap = newValue } } }
    }
    let live = LiveSettings()
    var debugLogOn = false
    var lastPlacementPrune = Date()

    /// Applies every setting that takes effect at once (status `.live`).
    func applyLiveSettings() {
        if Pause.isOn != prefs[PaneSettings.paused] {
            Pause.isOn = prefs[PaneSettings.paused]
            log(Pause.isOn ? "paused: pane's keys and mouse handling stand down" : "resumed")
        }
        NSApp.appearance = switch prefs[PaneSettings.theme] {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pane/pane.log")
        let wantLog = prefs[PaneSettings.debugLog]
        if wantLog != debugLogOn {
            debugLogOn = wantLog
            TrayLog.setFile(wantLog ? (ProcessInfo.processInfo.environment["PANE_LOG_FILE"].map { URL(fileURLWithPath: $0) } ?? logURL) : nil)
            if wantLog { log("diagnostic log on") }
        }
        // Test agents never touch your login items (unless a test points them at its own folder).
        let testAgent = ProcessInfo.processInfo.environment["PANE_DEFAULTS_SUITE"] != nil
        if !testAgent || ProcessInfo.processInfo.environment["PANE_LAUNCH_AGENTS_DIR"] != nil {
            let want = prefs[PaneSettings.launchAtLogin]
            if want != LoginItem.isEnabled {
                LoginItem.set(want)
                log("start at login: \(want ? "on (\(LoginItem.plistURL.path))" : "off")")
            }
        }
        let ignored = host?.leftAlone ?? []
        live.hidden = prefs.apps(PaneSettings.hideFromTaskbar) { $0 }.union(ignored)
        live.noSnap = prefs.apps(PaneSettings.snap) { !$0 }.union(ignored)
        updateMenuBarIcon()
        guard let taskbar else { return }
        taskbar.showBadges = prefs[PaneSettings.badges]
        taskbar.showAttention = prefs[PaneSettings.flashing]
        taskbar.showDesktopCorner = prefs[PaneSettings.farCornerShowsDesktop]
        taskbar.hiddenBundles = live.hidden
        inventory.scheduleRefresh() // the window filters changed
    }

    func updateMenuBarIcon() {
        iconMenu.onSettings = { [weak self] in self?.openSettings(page: nil) }
        iconMenu.onTogglePause = { [weak self] in
            guard let self else { return }
            do { try self.prefs.set(PaneSettings.paused, !self.prefs[PaneSettings.paused]) } catch { log("could not pause: \(error)") }
        }
        iconMenu.isPaused = { Pause.isOn }
        iconMenu.isPro = { [weak self] in self?.isPro ?? true }
        iconMenu.onBuy = host?.purchase?.action
        iconMenu.buyTitle = host?.purchase?.title ?? "Buy…"
        let want = prefs[PaneSettings.showMenuBarIcon] && !(host?.menuBarChevron ?? false)
        if want, menuBarIcon == nil {
            iconMenu.install()
            menuBarIcon = iconMenu
            log("menu-bar icon shown")
        } else if !want, let icon = menuBarIcon {
            icon.uninstall()
            menuBarIcon = nil
            log("menu-bar icon hidden")
        }
    }

    // MARK: Show desktop

    let showDesktop = ShowDesktop()

    /// Windows' Show desktop: this desktop's windows (only the desktop scope's in tests) minimized, or brought back.
    func toggleShowDesktop() {
        var windows = inventory.refreshNow()
        windows = windows.filter { desktopMembership.isOnCurrent($0.id) }
        if let scope = args.desktopScope { windows = windows.filter { scope.contains($0.bundleID ?? "") } }
        let inventory = self.inventory
        DispatchQueue.global(qos: .userInitiated).async { [showDesktop] in
            showDesktop.toggle(windows: windows) { inventory.element(for: $0) }
        }
    }

    func activateTaskbarItem(_ index: Int) {
        let fresh = TaskbarLayout.groups(windows: inventory.refreshNow(), pinned: taskbar.pinned, history: history)
        guard let group = fresh.first(where: { $0.index == index }) else { return }
        if group.windows.isEmpty {
            if let bundleID = group.bundleID { Task { await TaskbarActions.launch(bundleID: bundleID) } }
        } else if group.windows.count == 1, let window = group.windows.first {
            TaskbarActions.click(window, inventory: inventory)
        } else if let wid = numberCycle.next(group) {
            TaskbarActions.focus(wid, inventory: inventory, history: history)
            taskbar.showFlyout(forGroupAt: index)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    /// `keepSystemChanges`: a restart handover — the Dock, tiling and backup stay as they are for the next pane.
    func shutdown(keepSystemChanges: Bool = false) {
        guard !restored else { return }
        restored = true
        hotkeys?.stop()
        ShortcutRecording.end()
        for key in [PrivateAPI.SymbolicHotKey.commandTab, .commandShiftTab] { PrivateAPI.setSymbolicHotKey(key, enabled: true) }
        dockShield?.stop()
        dockSignals?.stop()
        switcher?.stop()
        commandSwitcher?.stop()
        clickThrough.stop()
        fullScreen.shutdown()
        snap.stop()
        inventory.stop()
        taskbar?.close()
        extensions.forEach { $0.stop() }
        menuBarIcon?.uninstall()
        if settings.hasPendingBackup && !keepSystemChanges {
            DockReservation(settings: settings).restore()
            log("system settings restored")
        }
    }

    /// Signals are handled on a background queue and restore the settings directly, so a busy or blocked main
    /// thread (e.g. a modal menu) can't keep the user's Dock/tiling changed after pane is told to quit.
    func installSignalHandlers() {
        let settings = self.settings
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                if settings.hasPendingBackup {
                    settings.restore()
                    log("system settings restored (signal)")
                }
                // Windows parked on other virtual desktops come back (the state file is kept current).
                let unparked = ParkedWindows.recoverIfNeeded()
                if unparked > 0 { log("brought back \(unparked) parked windows (signal)") }
                // macOS's ⌘Tab back on (Task View may have had it).
                for key in [PrivateAPI.SymbolicHotKey.commandTab, .commandShiftTab] { PrivateAPI.setSymbolicHotKey(key, enabled: true) }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
