// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import CoreGraphics
import Testing
import PaneKit

@Suite("Multiple displays · geometry")
struct MultiDisplayGeometryTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: -100, width: 1920, height: 1080)

    @Test func sharedEdgesDontSnap() {
        let screens = [main, right]
        // The main display's right edge touches the other display: no snap there, the pointer crosses.
        #expect(SnapZones.zone(for: CGPoint(x: 1438, y: 400), in: main, others: screens) == nil)
        #expect(SnapZones.zone(for: CGPoint(x: 1441, y: 400), in: right, others: screens) == nil)
        // Outer edges still snap.
        #expect(SnapZones.zone(for: CGPoint(x: 1, y: 400), in: main, others: screens) == .leftHalf)
        #expect(SnapZones.zone(for: CGPoint(x: 3358, y: 400), in: right, others: screens) == .rightHalf)
        #expect(SnapZones.zone(for: CGPoint(x: 2000, y: -99), in: right, others: screens) == .maximize)
        // Where the taller display reaches past the other one, its left edge is outer there.
        #expect(SnapZones.zone(for: CGPoint(x: 1441, y: 950), in: right, others: screens) == .leftHalf)
        // One display: as before.
        #expect(SnapZones.zone(for: CGPoint(x: 1438, y: 400), in: main) == .rightHalf)
    }

    @Test func framesKeepTheirPlaceBetweenWorkAreas() {
        let from = CGRect(x: 0, y: 30, width: 1440, height: 822), to = CGRect(x: 1440, y: -70, width: 1920, height: 1002)
        // Centred stays centred; the size is kept.
        let centred = Geometry.translated(CGRect(x: 420, y: 241, width: 600, height: 400), from: from, to: to)
        #expect(centred.size == CGSize(width: 600, height: 400))
        #expect(abs(centred.midX - to.midX) <= 1 && abs(centred.midY - to.midY) <= 1)
        // At the left edge it stays at the left edge; too big, it shrinks to fit.
        #expect(Geometry.translated(CGRect(x: 0, y: 30, width: 600, height: 400), from: from, to: to).origin == CGPoint(x: 1440, y: -70))
        let big = Geometry.translated(CGRect(x: 1440, y: -70, width: 1900, height: 1000), from: to, to: from)
        #expect(big.width == 1440 && big.height == 822 && from.contains(big))
    }
}
