// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation
import ApplicationServices
import CoreGraphics
import Testing
import PaneKit
import PaneTestKit
// Pure logic: no permissions, no windows, safe to run in parallel.

@Suite("Geometry")
struct GeometryTests {
    @Test func cocoaAndAXFlipAreInverse() {
        let cocoa = CGRect(x: 100, y: 50, width: 800, height: 600)
        let ax = Geometry.cocoaToAX(cocoa, primaryHeight: 1000)
        #expect(ax == CGRect(x: 100, y: 350, width: 800, height: 600))
        #expect(Geometry.axToCocoa(ax, primaryHeight: 1000) == cocoa)
    }

    @Test func secondaryScreenAbovePrimaryHasNegativeAXY() {
        // A 1440-tall display stacked above a 1000-tall primary: Cocoa y 1000...2440 → AX y -1440...0.
        let ax = Geometry.cocoaToAX(CGRect(x: 0, y: 1000, width: 2560, height: 1440), primaryHeight: 1000)
        #expect(ax.minY == -1440)
    }

    @Test func snapRectsTileTheWorkAreaWithoutGaps() {
        let work = CGRect(x: 0, y: 25, width: 1511, height: 921) // odd sizes on purpose
        let left = Geometry.rect(for: .leftHalf, in: work)
        let right = Geometry.rect(for: .rightHalf, in: work)
        #expect(left.maxX == right.minX)
        #expect(left.width + right.width == work.width)
        let quarters: [Geometry.Snap] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let area = quarters.map { Geometry.rect(for: $0, in: work) }.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == work.width * work.height)
        #expect(Geometry.rect(for: .maximize, in: work) == work)
    }
}

@Suite("Placement (emulated maximize state)")
struct PlacementTests {
    let work = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let free = CGRect(x: 200, y: 200, width: 640, height: 420)

    @Test func maximizeThenToggleRestoresOriginalFrame() {
        var store = PlacementStore()
        let maximized = store.toggleMaximize(1, currentFrame: free, workArea: work)
        #expect(maximized == work)
        #expect(store.state(of: 1, currentFrame: maximized) == .snapped(.maximize))
        #expect(store.toggleMaximize(1, currentFrame: maximized, workArea: work) == free)
        #expect(store.state(of: 1, currentFrame: free) == .normal)
    }

    @Test func chainedSnapsRestoreToTheFreeFrameNotTheIntermediateOne() {
        var store = PlacementStore()
        let max = store.snap(1, currentFrame: free, to: .maximize, workArea: work)
        let left = store.snap(1, currentFrame: max, to: .leftHalf, workArea: work)
        #expect(store.restore(1, currentFrame: left) == free)
    }

    @Test func userMovingTheWindowDropsTheMaximizedState() {
        var store = PlacementStore()
        let max = store.snap(1, currentFrame: free, to: .maximize, workArea: work)
        let dragged = max.offsetBy(dx: 40, dy: 40)
        #expect(store.state(of: 1, currentFrame: dragged) == .normal)
        #expect(store.restore(1, currentFrame: dragged) == nil)
        // The next maximize records the dragged frame as the new restore frame.
        let again = store.toggleMaximize(1, currentFrame: dragged, workArea: work)
        #expect(store.toggleMaximize(1, currentFrame: again, workArea: work) == dragged)
    }

    @Test func appSideOnePointJitterStillCountsAsMaximized() {
        var store = PlacementStore()
        let max = store.snap(1, currentFrame: free, to: .maximize, workArea: work)
        #expect(store.state(of: 1, currentFrame: max.insetBy(dx: 1, dy: 0)) == .snapped(.maximize))
    }
}

@Suite("Lifecycle policy")
struct LifecyclePolicyTests {
    let policy = LifecyclePolicy()

    @Test func lastStandardWindowClosedQuits() {
        #expect(policy.decide(AppWindowSnapshot(bundleID: "com.example.editor")) == .quit)
    }

    @Test func palettesAloneDoNotKeepTheAppAlive() {
        #expect(policy.decide(AppWindowSnapshot(standardWindows: 0, otherWindows: 2)) == .quit)
    }

    @Test func anyStandardWindowKeepsTheAppAlive() {
        #expect(policy.decide(AppWindowSnapshot(standardWindows: 1)) == .keep(.hasWindows))
    }

    @Test func trayAppsAreNeverQuit() {
        #expect(policy.decide(AppWindowSnapshot(hasStatusItem: true)) == .keep(.trayApp))
    }

    @Test func finderIsExcluded() {
        #expect(policy.decide(AppWindowSnapshot(bundleID: "com.apple.finder")) == .keep(.excluded))
    }

    @Test func agentsAndAccessoryAppsAreNeverQuit() {
        // Found by `pane-probe survey`: Dock, loginwindow, helpers all have zero windows.
        #expect(policy.decide(AppWindowSnapshot(isRegularApp: false)) == .keep(.notARegularApp))
    }

    @Test func windowsAXCannotSeeBlockTheQuit() {
        // The swiftquit failure mode: other-Space / background-tab windows invisible to kAXWindows.
        #expect(policy.decide(AppWindowSnapshot(unaccountedWindowServerWindows: 1)) == .keep(.possiblyHiddenWindows))
    }
}

@Suite("Snap zones")
struct SnapZoneTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func edgesAndCorners() {
        #expect(SnapZones.zone(for: CGPoint(x: 0, y: 450), in: screen) == .leftHalf)
        #expect(SnapZones.zone(for: CGPoint(x: 1439, y: 450), in: screen) == .rightHalf)
        #expect(SnapZones.zone(for: CGPoint(x: 700, y: 0), in: screen) == .maximize)
        #expect(SnapZones.zone(for: CGPoint(x: 0, y: 10), in: screen) == .topLeft)
        #expect(SnapZones.zone(for: CGPoint(x: 1439, y: 899), in: screen) == .bottomRight)
        #expect(SnapZones.zone(for: CGPoint(x: 10, y: 899), in: screen) == .bottomLeft)
        #expect(SnapZones.zone(for: CGPoint(x: 700, y: 450), in: screen) == nil)
    }

    @Test func secondaryDisplayToTheLeftUsesItsOwnEdges() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(SnapZones.zone(for: CGPoint(x: -1920, y: 500), in: left) == .leftHalf)
        #expect(SnapZones.zone(for: CGPoint(x: -1, y: 500), in: left) == .rightHalf)
    }
}

@Suite("Taskbar layout")
struct TaskbarLayoutTests {
    func window(_ id: CGWindowID, _ bundle: String, seat: Int, focused: Bool = false) -> ManagedWindow {
        ManagedWindow(id: id, pid: 1, title: "\(bundle) \(id)", appName: bundle, bundleID: bundle, frame: .zero,
                      isMinimized: false, isOnVisibleSpace: true, isFocused: focused, seat: seat)
    }

    @Test func pinnedFirstThenOthersGroupedByAppInFirstSeenOrder() {
        let windows = [window(1, "b", seat: 1), window(2, "c", seat: 2), window(3, "b", seat: 3), window(4, "a", seat: 4)]
        let items = TaskbarLayout.items(windows: windows, pinned: ["a", "z"])
        #expect(items.map(\.id) == ["win:4", "pin:z", "win:1", "win:3", "win:2"])
        #expect(items.first?.isPinned == true)
        #expect(items[1].kind == .pinnedApp)
    }

    @Test func activeWindowIsMarked() {
        let items = TaskbarLayout.items(windows: [window(1, "a", seat: 1), window(2, "a", seat: 2, focused: true)], pinned: [])
        #expect(items.map(\.isActive) == [false, true])
    }
}

@Suite("Snap transitions (Win+Arrow)")
struct SnapTransitionTests {
    @Test func windowsSequences() {
        #expect(SnapTransitions.next(from: .normal, .up) == .snap(.maximize))
        #expect(SnapTransitions.next(from: .snapped(.maximize), .down) == .restore)
        #expect(SnapTransitions.next(from: .normal, .down) == .minimize)
        #expect(SnapTransitions.next(from: .snapped(.leftHalf), .up) == .snap(.topLeft))
        #expect(SnapTransitions.next(from: .snapped(.topLeft), .down) == .snap(.leftHalf))
        #expect(SnapTransitions.next(from: .snapped(.leftHalf), .right) == .restore)
        #expect(SnapTransitions.next(from: .snapped(.rightHalf), .right) == .moveToDisplay(.right, .leftHalf))
    }

    @Test func hiddenAppsAreNeverQuit() {
        #expect(LifecyclePolicy().decide(AppWindowSnapshot(isHidden: true)) == .keep(.appHidden))
    }
}

@Suite("Menu mnemonics")
struct MnemonicTests {
    @Test func firstFreeLetter() {
        #expect(Mnemonics.assign(["File", "Edit", "View", "Window", "Help", "Format"]) == ["f", "e", "v", "w", "h", "o"])
        #expect(Mnemonics.assign(["A", "a"]) == ["a", nil])
    }
}

@Suite("Start menu search")
struct AppCatalogTests {
    let apps = ["Visual Studio Code", "Safari", "System Settings", "Microsoft Edge", "Terminal", "TextEdit"].map {
        AppEntry(name: $0, bundleID: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    @Test func prefixThenWordThenSubstringThenInitials() {
        let te = AppCatalog.rank(apps, "te").map(\.name)
        #expect(Set(te.prefix(2)) == ["TextEdit", "Terminal"]) // name prefix first
        #expect(te.last == "System Settings")                 // substring ("sysTEm") last
        #expect(AppCatalog.rank(apps, "edge").map(\.name) == ["Microsoft Edge"])
        #expect(AppCatalog.rank(apps, "vsc").map(\.name) == ["Visual Studio Code"])
        #expect(AppCatalog.rank(apps, "sett").first?.name == "System Settings")
    }

    @Test func scansThisMac() {
        let catalog = AppCatalog()
        let found = catalog.reload()
        #expect(found.contains { $0.bundleID == "com.apple.finder" } || found.contains { $0.name == "Safari" })
        #expect(catalog.search("saf").first?.name == "Safari")
    }
}

@Suite("Taskbar grouping")
struct TaskbarGroupingTests {
    func w(_ id: CGWindowID, _ app: String, seat: Int, focused: Bool = false, title: String? = nil) -> ManagedWindow {
        ManagedWindow(id: id, pid: pid_t(app.hashValue & 0xffff), title: title ?? "\(app) \(id)", appName: app, bundleID: app, frame: .zero,
                      isMinimized: false, isOnVisibleSpace: true, isFocused: focused, seat: seat)
    }

    var windows: [ManagedWindow] {
        [w(1, "edge", seat: 1), w(2, "code", seat: 2), w(3, "edge", seat: 3, focused: true), w(4, "finder", seat: 4), w(5, "edge", seat: 5)]
    }

    @Test func groupsArePinnedThenDragOrderThenFirstSeen() {
        let groups = TaskbarLayout.groups(windows: windows, pinned: ["finder", "mail"], appOrder: [AppKey("code")])
        #expect(groups.map(\.key.raw) == ["finder", "mail", "code", "edge"])
        #expect(groups.map(\.index) == [0, 1, 2, 3])
        #expect(groups.first { $0.key.raw == "edge" }?.windows.map(\.id) == [1, 3, 5]) // seat order
        #expect(groups.first { $0.key.raw == "mail" }?.windows.isEmpty == true)          // pinned, not running
    }

    @Test func mruDrivesTheRepresentative() {
        let history = FocusHistory()
        history.note(5); history.note(1)
        let edge = TaskbarLayout.groups(windows: windows, pinned: [], history: history).first { $0.key.raw == "edge" }!
        #expect(edge.mru.prefix(2) == [1, 5])
        #expect(edge.representative == 1)
    }

    @Test func alwaysIsOneIconPerApp() {
        let groups = TaskbarLayout.groups(windows: windows, pinned: [])
        let p = TaskbarLayout.present(groups: groups, mode: .always, availableWidth: 1000)
        #expect(p.buttons.map(\.id) == ["app:edge", "app:code", "app:finder"])
        #expect(p.buttons.first?.windowCount == 3)
        #expect(p.buttons.allSatisfy { !$0.showsLabel })
        #expect(p.buttons.first?.isActive == true)
    }

    @Test func neverIsOneLabeledButtonPerWindowAppsContiguous() {
        let groups = TaskbarLayout.groups(windows: windows, pinned: [])
        let p = TaskbarLayout.present(groups: groups, mode: .never, availableWidth: 2000)
        #expect(p.buttons.map(\.id) == ["win:1", "win:3", "win:5", "win:2", "win:4"])
        #expect(p.buttons.allSatisfy { $0.showsLabel })
    }

    @Test func whenFullCollapsesOnlyWhenNeeded() {
        let groups = TaskbarLayout.groups(windows: windows, pinned: [])
        let wide = TaskbarLayout.present(groups: groups, mode: .whenFull, availableWidth: 2000)
        #expect(wide.collapsed.isEmpty)
        #expect(wide.buttons.count == 5)
        // 5 buttons × 96 min > 400 → the 3-window app collapses into one labeled button.
        let tight = TaskbarLayout.present(groups: groups, mode: .whenFull, availableWidth: 400)
        #expect(tight.collapsed == [AppKey("edge")])
        #expect(tight.buttons.map(\.id) == ["app:edge", "win:2", "win:4"])
        #expect(tight.buttons.first?.showsLabel == true)
    }

    @Test func whenFullHysteresisKeepsAGroupCollapsedNearTheEdge() {
        let groups = TaskbarLayout.groups(windows: windows, pinned: [])
        var metrics = TaskbarMetrics()
        metrics.hysteresis = 100
        let collapsed = TaskbarLayout.present(groups: groups, mode: .whenFull, metrics: metrics, availableWidth: 400)
        // Just enough room to expand, but not enough spare room: stays collapsed.
        let expandedWidth: CGFloat = 5 * 96 + 4 * 2
        let near = TaskbarLayout.present(groups: groups, mode: .whenFull, metrics: metrics, availableWidth: expandedWidth + 10, previous: collapsed)
        #expect(near.collapsed == [AppKey("edge")])
        let roomy = TaskbarLayout.present(groups: groups, mode: .whenFull, metrics: metrics, availableWidth: 2000, previous: collapsed)
        #expect(roomy.collapsed.isEmpty)
    }

    @Test func overflowNeverHidesTheActiveApp() {
        let many = (1...12).map { w(CGWindowID($0), "app\($0)", seat: $0, focused: $0 == 12) }
        let p = TaskbarLayout.present(groups: TaskbarLayout.groups(windows: many, pinned: []), mode: .always, availableWidth: 300)
        #expect(!p.overflow.isEmpty)
        #expect(p.buttons.contains { $0.id == "app:app12" })
        #expect(p.overflow.allSatisfy { !$0.isActive })
    }

    @Test func groupCycleStartsAtMRUHeadThenWalksSeatOrder() {
        // App in the background: the last active window first, then seat order.
        let background = windows.map { ManagedWindow(id: $0.id, pid: $0.pid, title: $0.title, appName: $0.appName, bundleID: $0.bundleID, frame: .zero,
                                                     isMinimized: false, isOnVisibleSpace: true, isFocused: false, seat: $0.seat) }
        let history = FocusHistory()
        history.note(3)
        let edge = TaskbarLayout.groups(windows: background, pinned: [], history: history).first { $0.key.raw == "edge" }!
        let cycle = GroupCycle()
        let start = Date()
        let sequence = (0..<4).map { cycle.next(edge, now: start.addingTimeInterval(Double($0) * 0.2)) }
        #expect(sequence == [3, 5, 1, 3])
        #expect(cycle.next(edge, now: start.addingTimeInterval(5)) == 3) // idle → restarts at the MRU head
    }

    @Test func groupCycleSkipsTheActiveHead() {
        // Window 3 is focused and most recent: the first cycle step goes to the next window.
        let history = FocusHistory()
        history.note(3)
        let edge = TaskbarLayout.groups(windows: windows, pinned: [], history: history).first { $0.key.raw == "edge" }!
        let cycle = GroupCycle()
        #expect([cycle.next(edge), cycle.next(edge), cycle.next(edge)] == [5, 1, 3])
    }

    @Test func flyoutPresentationAndTitleTrimming() {
        let edge = TaskbarLayout.groups(windows: windows + [w(9, "edge", seat: 9, title: "Docs — edge")], pinned: []).first { $0.key.raw == "edge" }!
        #expect(GroupFlyout.make(for: edge, previewsAvailable: true, maxThumbnails: 6).presentation == .thumbnails)
        #expect(GroupFlyout.make(for: edge, previewsAvailable: false, maxThumbnails: 6).presentation == .list)
        #expect(GroupFlyout.make(for: edge, previewsAvailable: true, maxThumbnails: 2).presentation == .list)
        #expect(GroupFlyout.make(for: edge, previewsAvailable: true, maxThumbnails: 6).entries.last?.title == "Docs")
        #expect(GroupFlyout.maxThumbnails(screenWidth: 1440) == 6)
    }

    @Test func arrangeTilesTheWorkArea() {
        let work = CGRect(x: 0, y: 29, width: 1440, height: 855)
        let side = (0..<3).map { TaskbarActions.arrange(.sideBySide, index: $0, count: 3, in: work) }
        #expect(side.last?.maxX == work.maxX && side[0].maxX == side[1].minX)
        let stacked = (0..<2).map { TaskbarActions.arrange(.stacked, index: $0, count: 2, in: work) }
        #expect(stacked[1].maxY == work.maxY && stacked[0].maxY == stacked[1].minY)
    }
}

@Suite("Work area adoption")
struct WorkAreaAdoptionTests {
    let work = CGRect(x: 0, y: 25, width: 1440, height: 859) // menu bar 25, taskbar from 884

    @Test func windowsThatFitStay() {
        #expect(WorkAreaAdoption.fitted(CGRect(x: 100, y: 100, width: 500, height: 400), in: work) == nil)
        #expect(WorkAreaAdoption.fitted(CGRect(x: 100, y: 484, width: 500, height: 400), in: work) == nil) // ends exactly at the bar
    }

    @Test func aWindowUnderTheBarMovesUpKeepingItsSize() {
        #expect(WorkAreaAdoption.fitted(CGRect(x: 300, y: 600, width: 500, height: 330), in: work) == CGRect(x: 300, y: 554, width: 500, height: 330))
    }

    @Test func aWindowTallerThanTheWorkAreaShrinks() {
        // Maximized with an auto-hidden Dock: the whole screen below the menu bar.
        #expect(WorkAreaAdoption.fitted(CGRect(x: 0, y: 25, width: 1440, height: 907), in: work) == CGRect(x: 0, y: 25, width: 1440, height: 859))
    }

    @Test func windowsElsewhereAreLeftAlone() {
        #expect(WorkAreaAdoption.fitted(CGRect(x: 0, y: 2000, width: 400, height: 300), in: work) == nil) // another screen below
    }
}

@Suite("Dock pins sync")
struct DockPinsTests {
    func tile(_ id: String, extra: String = "") -> [String: Any] {
        ["tile-type": "file-tile", "GUID": id.count, "tile-data": ["bundle-identifier": id, "file-label": id + extra]]
    }
    func ids(_ e: [[String: Any]]) -> [String] { e.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String } }
    let url: (String) -> URL? = { URL(fileURLWithPath: "/Applications/\($0).app") }
    let name: (String) -> String? = { _ in nil }

    @Test func keepsOrderAndDataOfAppsStillPinned() {
        let dock = [tile("a", extra: "!"), tile("b"), tile("c")]
        let next = DockPins.updated(dock, pinned: ["c", "a"], url: url, name: name)
        #expect(ids(next) == ["a", "c"]) // the Dock's order, not pane's
        #expect(((next[0]["tile-data"] as? [String: Any])?["file-label"] as? String) == "a!") // untouched entry
    }

    @Test func addsNewAppsAtTheEnd() {
        let next = DockPins.updated([tile("a")], pinned: ["a", "z"], url: url, name: name)
        #expect(ids(next) == ["a", "z"])
        let data = next[1]["tile-data"] as? [String: Any]
        #expect((data?["file-data"] as? [String: Any])?["_CFURLString"] as? String == "file:///Applications/z.app")
        #expect(next[1]["tile-type"] as? String == "file-tile")
    }

    @Test func appsWithoutALocationAreSkippedAndNonAppsKept() {
        let folder: [String: Any] = ["tile-type": "directory-tile", "tile-data": ["file-label": "Downloads"]]
        let next = DockPins.updated([tile("a"), folder], pinned: ["ghost"], url: { $0 == "ghost" ? nil : URL(fileURLWithPath: "/x") }, name: name)
        #expect(ids(next).isEmpty)
        #expect(next.count == 1) // the folder entry stays
    }
}

import Carbon.HIToolbox

