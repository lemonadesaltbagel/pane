// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import AppKit
import Testing
import PaneKit
import PaneTestKit

// Runs Swift Testing inside a real AppKit event loop, as pane itself will run: SkyLight's window
// notifications are only delivered through NSApp's event machinery, and the main actor stays serviced.
// Accepts the usual Swift Testing arguments, e.g. `pane-tests --filter Placement`.
// The engine's tests: agent tests run the Free build.
Harness.agentBinaryName = "pane"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task.detached {
    let status = await Testing.__swiftPMEntryPoint() as CInt
    exit(status)
}
app.run()
