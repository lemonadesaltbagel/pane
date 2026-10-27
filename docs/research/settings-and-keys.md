# Settings and key bindings: how comparable products do it, and what pane should ship

Researched 2026-10-22 from the web and from public source code. Sources are numbered [n] and listed at the end. Anything marked *(unverified)* still needs checking.

## 1. Core actions: key binding comparison

| Action | Windows 11 [1] | macOS 15/26 native [2][3] | Rectangle: Recommended / Spectacle [4] | Others |
|---|---|---|---|---|
| Snap left / right | Win+←/→ | fn⌃←/→ | ⌃⌥←/→ / ⌘⌥←/→ | Magnet ⌃⌥←/→ [5]; Loop fn+key [6]; Raycast none [7]; Amethyst ⌥⇧ [8] |
| Maximize | Win+↑ | fn⌃F (Fill) | ⌃⌥↩ / ⌘⌥F | |
| Minimize, or restore from snapped/maximized | Win+↓ | ⌘M; fn⌃R (previous size) | Restore ⌃⌥⌫ (both presets) | |
| Snap top / bottom | Win+↑/↓ from snapped: quarter | fn⌃↑/↓ (halves) | ⌃⌥↑/↓ / ⌘⌥↑/↓ | |
| Move to next display | Win+⇧←/→ | none | ⌃⌥⌘←/→ (both presets) | |
| Snap Layouts | Win+Z | hover the green button | none | |
| Window switcher | Alt+Tab, Alt+Esc | ⌘⇥ (switches apps), ⌘` (windows of one app) | n/a | AltTab ⌥⇥, ⌥` [9]; DockDoor ⌥⇥ [10] |
| Task View | Win+Tab | ⌃↑ / F3 (Mission Control) | n/a | |
| New / close desktop | Win+Ctrl+D / Win+Ctrl+F4 | none | n/a | |
| Switch desktop | Win+Ctrl+←/→ | ⌃←/→, ⌃1…9 | n/a | |
| Show desktop | Win+D; Win+M minimizes all | F11 / fn-F11 | n/a | |
| Start / launcher | Win (tap), Ctrl+Esc | ⌘Space (Spotlight) | n/a | Raycast Hyper = ⌃⌥⌘ [11] |
| Taskbar app N | Win+1…9 | none | n/a | |
| Close window | Alt+F4 | ⌘W | n/a | |
| Quit app | (Alt+F4 on the last window) | ⌘Q | n/a | Karabiner: Alt+F4 → ⌘Q [12] |

**How Windows emulators map the keys.** All of them treat ⌘ as Win:
- Parallels does so by default, and users complain that tapping ⌘ opens Start [13].
- VMware Fusion uses profiles, plus a "Mac Host Shortcuts" pane that turns off macOS shortcuts while Fusion is in front [14].
- Windows App sends Win for ⌘, except ⌘C/V/X/A/Z/F, which become Ctrl+… under the "Use Mac shortcuts" setting [15][16].
- Karabiner's Windows rule sets go the other way: Ctrl+letter becomes ⌘+letter, Alt+F4 becomes ⌘Q, and Home/End become ⌘←/→. They exclude VMs and remote-desktop apps, and "PC-Style" also excludes terminals [12].

## 2. Settings patterns from mature products

**What the settings are, and how they are grouped**
- **Windows 11** [17][18][19]:
  - *Taskbar* settings come in three groups:
    - Taskbar items: Search, Task view.
    - Tray icons, each switched on or off.
    - Behaviors: alignment (center by default), auto-hide, badges, flashing, which displays show it, "far corner shows desktop", and combine buttons.
  - *Multitasking* has a Snap windows switch with sub-options: Snap Assist, layouts on hovering maximize, layouts on dragging to the top, snap groups, and snap without reaching the edge. It also has title-bar shake (**off** by default), and settings for whether the taskbar and Alt+Tab show windows from the current desktop or all desktops (the taskbar defaults to the current desktop).
- **AltTab** is the best model [9]. Its tabs are General, Controls, Appearance, Exceptions, and About.
  - It allows up to 3 shortcuts, each with its own filters (apps, Spaces, screens, minimized/hidden/fullscreen windows, order).
  - While the switcher is open, single keys act on the selected window: W, M, Q, H, F, and S.
  - It has Export, Import, and Reset buttons, and searchable settings. Launch at login defaults to on.
  - Its Exceptions list is per bundle ID: **Hide** and **Ignore shortcuts** (always, or only when fullscreen). VMs and remote desktops are pre-filled.
  - If the user binds ⌘⇥, AltTab turns off the native ⌘⇥ hotkey and restores it later [20].
- **Rectangle** [4][21][22]:
  - On first run the user picks the "Recommended" or "Spectacle" preset.
  - It has a per-app "Ignore app" option, JSON import/export, and hidden `defaults` keys.
  - At launch it **detects conflicts**: competing window managers that are running, and macOS's edge tiling (`com.apple.WindowManager` `EnableTilingByEdgeDrag`). It offers to turn off the macOS tiling.
- **Loop** [6]: the trigger key defaults to fn, and launch at login defaults to off. It has an excluded-apps list and iCloud settings sync.
- **Ice** [23] has panes for General, Menu Bar Layout, Menu Bar Appearance, Hotkeys, and Advanced. Defaults: reveal on click and on scroll (not on hover), and auto-rehide using the "smart" strategy after 15 s.
- **Bartender 6** [24][25] sorts items into Shown, Hidden, and Always Hidden. It also has Triggers, Presets, Hotkeys, and Quick Reveal.
- **Taskbar/dock tools**: uBar [26] has panes for General, Theme, Areas, Menu, Apps, Date & Time, Shortcuts, and Advanced, with per-monitor settings. DockDoor [10] has separate Gestures and Keybinds pages. HyperDock [27] and Moom [28] give each action its own hotkey.

**What every mature product has:** launch at login, a menu bar icon you can hide, a permissions check on first launch, a shortcut recorder for every action, a per-app exceptions list, JSON import/export, reset to defaults, and conflict detection.

## 3. Recommendation for pane

### 3a. Key bindings

Add a new setting, **`keyboardMode`: `"mac"` (default) | `"windows"`**. It is the "Windows keyboard" toggle and also the preset question shown on first run, as Rectangle does.

On a PC keyboard, macOS already treats the Win key as ⌘ and Alt as ⌥. So pane's ⌘=Win, ⌥=Alt mapping puts every modifier exactly where a Windows user expects it.

| Action | `mac` mode (default: only adds bindings macOS doesn't use) | `windows` mode |
|---|---|---|
| Start | ⌘ tapped alone; ⌃Esc | same |
| Snap ←/→, maximize ↑, restore/minimize ↓ | **fn⌃+arrows** (macOS's own tiling chords, which pane already takes over); alternative ⌃⌥+arrows | ⌘ + arrows |
| Next display | fn⌃⇧←/→ (replaces native Arrange); alternate ⌃⌥⌘←/→ | ⌘⇧←/→ |
| Snap Layouts | fn⌃Z *(check it is unused)*; hovering the green button | ⌘Z is **not** offered (it is Undo) |
| Switcher | ⌥⇥, ⌥`; replacing ⌘⇥ is opt-in, done the AltTab way | ⌥⇥ |
| Task View | ⌃↑ / F3 while `virtualDesktops` is on, because Mission Control doesn't show pane's desktops | ⌘⇥ |
| Desktops | ⌃⌘D / ⌃⌘←→ / ⌃⌘F4 / ⌃⌘⇧←→ (current). They shadow Look Up and, *(unverified)*, Xcode's back/forward | same |
| Show desktop | F11, made a Windows-style toggle; taskbar corner | ⌘D, ⌘M |
| Taskbar app N | off | ⌘1…9 |
| Close window | ⌥F4 (laptops need fn) | ⌥F4 |
| Explorer / Lock | off (⌃⌘Q is the native lock) | ⌘E, ⌘L |

**`windows` mode** also remaps Ctrl+letter to ⌘+letter, Home/End, and Alt+F4 (the Karabiner and Windows App approach), except in terminals, VMs, and remote-desktop apps. That frees the ⌘ chords, which is the only safe way to get ⌘←/→, ⌘D, ⌘E, ⌘L and ⌘1…9.

**Alternative Win keys (`winKey`):** `command` (default), `rightCommand`, `hyper` (Caps Lock becomes ⌃⌥⌘, with no conflicts), and `fn` (no Globe key on PC keyboards).

**pane must never override these:**
- ⌘⌥Esc, ⌃⌘Q, and the power/eject combos. These must keep working even if pane's event tap stalls.
- ⌘Q/W/H/M/C/V/X/Z/A/S/F/T/N/O/P/,
- ⌘Space, ⌘⇧3/4/5, ⌘`
- ⌘⇥, unless the user opts in.
- In `mac` mode: ⌘/⌥/fn+arrows in text.
- ⌥+letter and ⌥Space, because they type characters. Alt-tap must only arm on a clean tap.
- ⌃⌥ chords while VoiceOver is running.
- Any chord during Secure Input.

All pane chords also stand down while a VM, remote desktop, or full-screen game is frontmost (AltTab's exception list). Pane should check `com.apple.symbolichotkeys` and running window managers for conflicts, and show each one next to the binding it affects.

### 3b. Settings

Group the settings into Windows-named panes, because the target users know Windows' Settings. Existing keys are in `code`; ★ marks new ones.

1. **General**
   - ★launchAtLogin=on, ★showMenuBarIcon=on, ★pause-pane switch.
   - Permission status: Accessibility, Screen Recording, Input Monitoring.
   - ★updates.
2. **Keyboard**
   - ★keyboardMode=mac, ★winKey=command.
   - winTap=on, altTap=on, `altF4`=on, `desktopKeys`=on, `fullScreenKey`=on.
   - `winArrows` and `winNumbers` become per-group presets.
   - ★A recorder for each action and ★a conflict list.
3. **Snap & windows**
   - `takeOverTiling`=on.
   - Windows' Snap sub-switches (★drag, ★layouts on green-button hover, ★layouts on top drag, ★Snap Assist) all on; ★windowShake off; ★gaps 0.
   - `clickThrough`=on, `convertNativeFullScreen`=on, `keepNativeFullScreen`=[].
4. **Taskbar**
   - `replaceDock`=on, `barHeight`=48, ★alignment=center, `combineButtons`=always, `pinned`.
   - ★badges, ★flashing, ★allDisplays, ★farCornerShowsDesktop and ★hoverPreviews all on; ★autoHide off.
5. **Notification area (tray)**
   - `trayHidesMenuBar`=on, `trayLocation`=menubar, `traySingleMove`=on, `trayIconRefreshMinutes`=10.
   - ★A per-icon Shown/Hidden/Always-hidden list.
   - ★Reveal on click=on, on hover=off, on scroll=on; ★autoRehide=smart/15 s (Ice's defaults).
6. **Alt+Tab**
   - ★shortcut=⌥⇥, ★secondShortcut=⌥` (current app), ★replaceCmdTab=off.
   - ★Filters as in AltTab: current desktop, all displays, minimized/hidden windows shown, most recent first, thumbnails, 100 ms delay.
7. **Desktops**
   - `virtualDesktops`=on.
   - ★taskbarShows=current, ★names, ★taskViewReplacesMissionControl=on.
8. **Start**
   - `startMenu`=apps.
   - ★pinned, ★recent.
9. **Apps (exceptions)**, one row per bundle ID, with the options:
   - hide from taskbar/switcher;
   - ignore pane shortcuts (always / when frontmost / when fullscreen);
   - keep native full screen;
   - don't quit on last window (folds in `optOut`);
   - don't snap.

   Pre-filled with VM and remote-desktop apps, and Finder set to "hide when it has no windows".
10. **Lifecycle**
    - `quitOnLastWindow`=on.
11. **Advanced**
    - Export/Import `config.json`.
    - Reset to defaults (also restores the macOS settings pane changed).
    - Debug logging; show onboarding again.

**Onboarding**, in this order:
1. Permissions.
2. Keyboard preset (`mac`/`windows`), with a keymap preview.
3. Conflict check: other window managers and macOS tiling (Rectangle's pattern).
4. "What pane changes in macOS" (Dock, tiling, ⌘⇥), and a promise to restore all of it.

## Sources
1. https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec
2. https://support.apple.com/guide/mac-help/mchl9674d0b0/mac
3. https://support.apple.com/en-us/102650
4. https://github.com/rxhanson/Rectangle (README; `Rectangle/WindowAction.swift`)
5. https://forum.keyboardmaestro.com/t/km-not-sending-shortcuts-to-magnet/19286
6. https://github.com/MrKai77/Loop (`Loop/Extensions/Defaults+Extensions.swift`)
7. https://manual.raycast.com/window-management
8. https://raw.githubusercontent.com/ianyh/Amethyst/development/docs/configuration-files.md
9. https://github.com/lwouis/alt-tab-macos (`src/preferences/Preferences.swift`, `settings-window/tabs/*`); https://alt-tab.app/
10. https://github.com/ejbills/DockDoor
11. https://manual.raycast.com/hyper-key
12. https://github.com/pqrs-org/KE-complex_modifications (`public/json/windows_shortcuts_on_macos.json`, `pc_shortcuts.json`)
13. https://forum.parallels.com/threads/how-to-stop-cmd-key-from-activating-windows-key.349850/
14. https://docs.vmware.com/en/VMware-Fusion/13/com.vmware.fusion.using.doc/GUID-A50D0E3C-9549-43B5-AB57-070F805780A3.html
15. https://learn.microsoft.com/en-us/windows-app/input-keyboard-mouse-touch-pen
16. https://learn.microsoft.com/en-us/answers/questions/447782/remote-desktop-connection-for-macos-how-to-remap-c
17. https://support.microsoft.com/en-us/windows/customize-the-taskbar-in-windows-0657a50f-0cc7-dbfd-ae6b-05020b195b07
18. https://support.microsoft.com/en-us/windows/snap-your-windows-885a9b1e-a983-a3b1-16cd-c531795e6241
19. https://support.microsoft.com/en-us/windows/configure-multiple-desktops-in-windows-36f52e38-5b4a-557b-2ff9-e1a60c976434; https://www.windowscentral.com/whats-new-multitasking-windows-11
20. https://github.com/lwouis/alt-tab-macos/blob/master/src/preferences/settings-window/tabs/controls/NativeHotkeyResolverSpecs.md
21. https://raw.githubusercontent.com/rxhanson/Rectangle/main/TerminalCommands.md
22. https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/MacTilingDefaults.swift; `AppDelegate.swift` (`checkForConflictingApps`)
23. https://github.com/jordanbaird/Ice (`Ice/Settings/SettingsManagers/*.swift`)
24. https://www.macbartender.com/Bartender6/release_notes/
25. https://thesweetbits.com/tools/bartender-review/
26. https://ubarapp.com/
27. https://bahoom.com/hyperdock/
28. https://manytricks.com/moom/help/keyboard.html; https://manytricks.com/blog/?p=6456
