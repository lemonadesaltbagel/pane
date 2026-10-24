// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import PaneKit
import Testing

/// Parent of every test that launches PaneFixture windows. `.serialized` applies recursively, so no two
/// integration tests fight over focus or z-order. These tests take over the screen for about a minute.
@Suite("Integration", .serialized, .enabled(if: IntegrationGate.isEnabled, "Needs Accessibility; set PANE_SKIP_INTEGRATION to skip"))
public struct IntegrationTests {
    public init() {
        FixtureBundle.killStrays()
        TestSystemSettings.recoverIfNeeded()
        if !SyntheticKeyboard.heldModifiers.isEmpty { SyntheticKeyboard.releaseAllModifiers() }
    }
}
