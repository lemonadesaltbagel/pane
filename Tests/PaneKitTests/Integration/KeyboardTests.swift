// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Carbon.HIToolbox
import Testing
import PaneKit
import PaneTestKit

extension IntegrationTests {
    /// Feature 7: the plumbing a Windows keyboard model needs. Nothing here swallows or rewrites real input.
    @Suite("7 · Keyboard plumbing")
    struct KeyboardTests {
        @Test func listenOnlyEventTapCanBeCreated() {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
            Report.record("7 Keyboard · listen-only tap", tap != nil ? "created" : "refused (grant Input Monitoring)")
            #expect(tap != nil)
            if let tap { CFMachPortInvalidate(tap) }
        }

        @Test func activeEventTapCanBeCreated() {
            // Needed for Alt-tap menus, green-button override and Ctrl→Cmd rewriting.
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                        callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
            Report.record("7 Keyboard · active tap", tap != nil ? "created" : "refused")
            #expect(tap != nil)
            if let tap { CFMachPortInvalidate(tap) }
        }

        @Test func carbonHotKeyRegistersAndUnregisters() {
            // Win+Number / Alt+F4 style chords. Ctrl+Opt+Cmd+F12 is unlikely to collide with anything.
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_F12), UInt32(controlKey | optionKey | cmdKey),
                                             EventHotKeyID(signature: 0x50414E45, id: 1), GetApplicationEventTarget(), 0, &ref)
            #expect(status == noErr)
            if let ref { UnregisterEventHotKey(ref) }
        }
    }
}
