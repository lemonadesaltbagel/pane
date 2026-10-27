# Starting pane midway: what happens to windows that are already open

Measured on 2026-10-22 (macOS 26.6.2). Each state was set up with test windows *before* starting pane, then pane's agent was started (`StartupAdoptionTests`, `PANE_STRESS=1`).

## What pane does, per state

| Window state before pane starts | Before this round | Now |
|---|---|---|
| **Minimized** | **Un-minimized** at start and again at quit. pane applies its Dock settings by restarting the Dock, and a restarting Dock gives every minimized window back. | Kept minimized: the windows are noted before the restart and re-minimized when they come back. A window may pop up and minimize again for a moment. |
| **Reaching under the taskbar** (possible when the Dock was auto-hidden) | Stayed under the bar (macOS doesn't move windows when the reserved space grows) | Moved up to end at the bar, and shorter if taller than the space (Windows does this when the work area shrinks). |
| **In macOS full screen** (own Space) | Left alone. The taskbar lists it; clicking it switches to its Space. Alt+Tab **didn't list it**. | Still left alone; Alt+Tab now lists it, and choosing it goes to its Space. |
| **App with no windows** | Kept running; quit-on-last-window only acts on a later change, never at start. | Same |
| **Hidden app (⌘H)** | Stays hidden and running | Same |
| **Ordinary windows, maximized windows** (Dock not auto-hidden) | Unchanged: they already end above where the bar goes | Same |

Live Dock resizing (private `CoreDockSetTileSize`, so no restart and nothing un-minimized) was tried and does nothing on macOS 26 (`CoreDockExperimentTests`).

## The open question: windows already in macOS full screen

Windows has no full-screen Spaces: a full-screen app is a window on the desktop, and the taskbar hides while it's focused. pane gives windows that enter full screen *after* it starts exactly that. For windows that were already in full screen when pane started, the choices are:

| Option | What the user sees | Cost |
|---|---|---|
| **Leave** (today) | They stay in macOS full screen. Reachable from the taskbar and Alt+Tab, but switching to one is a Space slide, and the bar isn't there. | Two kinds of full screen side by side. |
| **Convert when visited** (recommended) | The first time you switch to one, pane brings it back to the desktop as Windows-style full screen. From then on it behaves like every other window. | One exit-full-screen animation, at the moment you go there anyway. |
| **Convert all at start** | Every full-screen window is brought back as pane starts. | A burst of Space animations at launch, one per window (15 on this Mac), while you watch. |
| **Ask once** | The onboarding asks which of the above. | One more question. |

The exceptions stay as they are for every option: apps in `keepNativeFullScreen` (games), and Terminal, which pane never touches.

**Decided by the user (2026-10-22): convert when visited**, built and tested (`existingFullScreenConvertsOnFirstVisit`). My recommendation was **convert when visited** as the default, with this choice in Settings (leave / onVisit / atStart, reserved now). It gets everything to the Windows model without disturbing the launch. Note this would apply to your own full-screen Edge too, the first time you switch to it.
