# The Windows 11 Start menu: research for pane

2026-10-23. Web research plus read-only checks on this Mac (macOS 26.6.2). **[unverified]** marks something not confirmed by a source or a local check. The plan is in research/plan-start-menu.md.

## 1. What Windows ships now

**Timeline:**
- **2021 Start** (21H2/22H2):
  - A centred panel about 640×720 epx, with search, Pinned (6 columns, paged with dots), Recommended, a separate "All apps" page, and the account and power row.
  - 22H2 added layout presets and pin folders.
- **The "new Start"** (2025):
  - It went to Insiders in June 2025 (build 26200.5641) and to everyone on 24H2/25H2 from October 2025. The rollout finished by July 2026.
  - It's one scrollable surface: search, then **Pinned** (2 rows, with "Show all"), then **Recommended**, then **All**, then the bottom bar.
  - **All** has three views, picked in Start and remembered:
    - **Category** (default): a category needs 3 or more apps, the rest go to "Other", and the most-used apps rise to the top.
    - **Grid** and **List**: A–Z with letter headers, and a letter-jump grid.
- **September 2026 update** (rolling out):
  - "Recommended" becomes **"Recent"**.
  - **Size** is Automatic, Small or Large; this replaced the layout presets.
  - Pinned, Recent and All can each be shown or hidden.
  - A new option: "Hide your name and profile picture".

**Size, place and look:**
- Automatic size: 8 pinned columns, 6 recent items and 4 category columns on large screens; 6, 4 and 3 on small ones. No pixel sizes are published.
- Position: centred on the taskbar's display with centred alignment, or above the Start button with left alignment.
- Acrylic material, solid without transparency. Corner radius 8 px (4 px for items inside).
- Opens by sliding up with a fade in about 200–300 ms **[unverified]**.

**Settings ▸ Personalization ▸ Start:**
- size;
- show or hide Pinned, Recent and All;
- show all pins by default;
- show recently added apps;
- show most used apps;
- show recommended files;
- websites from history; tips and new apps; account notifications; mobile device;
- hide name and picture;
- **Folders next to the power button:** Settings, File Explorer, Documents, Downloads, Music, Pictures, Videos, Network, Personal folder.

## 2. Behaviours

- **Opening and closing:**
  - Win toggles Start, and Ctrl+Esc opens it.
  - Right-clicking Start, or Win+X, opens the Quick Link menu.
  - It opens with focus in search, and **typing goes straight to search**.
  - It closes on Esc, Win, a click outside, focus loss, or launching something.
- **Pinned:**
  - Drag to reorder.
  - **Drop a pin on another to make a folder.** Folders can be renamed, and a folder with no apps left disappears.
  - Right-click: Unpin from Start, Pin to taskbar, Move to front, App settings, Uninstall; More ▸ Run as administrator, Open file location. Insider builds also have Move left/right and Create/Move to folder.
- **Recent:**
  - Recent files with a relative time ("17m ago"), and recently installed apps.
  - Right-click: Remove from list, Open file location.
- **All:** right-click Pin to Start or Pin to taskbar. The letter headers open a jump grid.
- **Account (bottom left):**
  - Picture and name.
  - It opens an account card: Sign out, a "…" menu with Change account settings, and other users.
  - Lock moved to the power menu.
- **Power (bottom right):** Sign-in options, Lock, Sleep, (Hibernate), Shut down, Restart. "Update and…" variants appear when an update is pending.
- **Keyboard:**
  - Arrows move within a grid; Tab and Shift+Tab move between regions (search, Pinned, Recent, All, account, folders, power).
  - Enter launches, Shift+F10 opens the context menu, Esc closes.
- **Search (current release):**
  - Filter pills: All, Apps, Documents, Web, Settings, …
  - Left column: Best match, then groups (Apps, Settings, Documents, Folders, Web).
  - Right preview pane: icon, type, actions (Open, Run as admin, Open file location, Pin to Start/taskbar, Uninstall) and the app's recent files.
  - Enter opens the selection. With the box empty it shows Top apps and recents.
  - Microsoft is testing a single-list search without the preview pane, for taskbar search only, Insiders only.
- **What users complain about** (the lessons for pane):
  - Too big on small screens.
  - Ads, web and Bing results.
  - **Slow:** parts are React Native, with CPU spikes on open; a rewrite is promised.
  - Users value a fast local search, a full app list one click away, folders, and size control.

## 3. How each part maps to macOS 26

| Part | API | Notes |
|---|---|---|
| Installed apps | `NSMetadataQuery`, `kMDItemContentType == com.apple.application-bundle`, over /Applications (+Utilities), /System/Applications (+Utilities), ~/Applications, plus Finder in CoreServices | A live query notices installs and removals. Icons: `NSWorkspace.icon(forFile:)`. pane's `AppCatalog` already scans the folders and ranks matches. |
| Category view | `LSApplicationCategoryType` (Info.plist) or `kMDItemAppStoreCategory` | Safari reads "Productivity". Map Apple's categories to Windows-like groups. |
| Recently added apps | `kMDItemDateAdded` | It changes for Apple's apps on OS updates. Seed from it, then keep pane's own first-seen dates. |
| Most used apps | `kMDItemUseCount` / `kMDItemLastUsedDate` (undocumented), plus pane's own counts | Count launches with `NSWorkspace.didLaunchApplicationNotification`. |
| Recent files | `NSMetadataQuery`, `kMDItemLastUsedDate` ≥ today − 30 days, apps and folders excluded | 31 items in the last 7 days here. Also macOS 26's shared file lists (`com.apple.LSSharedFileList.RecentDocuments.sfl4`, a private bookmark archive). **Unknown:** whether TCC hides Desktop, Documents and Downloads results from a packaged pane. |
| Settings search | System Settings panes: `/System/Library/ExtensionKit/Extensions/*.appex`, ids `com.apple.<Name>-Settings.extension` | Open one with `x-apple.systempreferences:<id>`. The display names come from each appex, plus our keywords. pane's own settings: `PaneSettings.search`. |
| File search | `NSMetadataQuery` on display name / text content, asynchronous, cancelled on each keystroke | |
| Power | Apple events to loginwindow (`kSystemProcess`): `'rest'` restart, `'shut'` shut down, `'rlgo'` log out; `'rrst'`/`'rsdn'`/`'logo'` show the system's confirmation | **Unknown:** whether a direct event to loginwindow asks for Automation consent (the System Events route does). A signed app needs `com.apple.security.automation.apple-events`. Apps can cancel a restart. |
| Sleep | `IOPMSleepSystem` (IOKit) | No admin rights needed. **Never in tests: sleep locks this Mac.** |
| Lock / switch user | `SACLockScreenImmediate`, `SACSwitchToLoginWindow` (private login.framework, exported on 26.6.2) | Chromium uses the same. Not a synthetic ⌃⌘Q. |
| Account | `NSFullUserName()`; picture `CBIdentity(name:authority:).image` (Collaboration.framework) | "Change account settings" opens `com.apple.Users-Groups-Settings.extension`. |

## 4. Prior art on the Mac

- **uBar:** its "uBar Menu" lists Applications, System Settings and custom items.
- **boringBar:** a Dock replacement with a Start menu and launcher.
- **Others:** Taskbar, RetroWin, and the menu-bar "Start".
- **Launchpad replacements** since Tahoe removed it (LaunchOS, BuhoLaunchpad): users miss folders and custom layouts in Spotlight's Apps view.
- **None is a faithful Windows 11 Start.** On Windows, StartAllBack and Start11 sell on speed, a full app list, and no ads.

## 5. Accessibility

- **Windows' element names** (XAML): `StartDocked.SearchBoxToggleButton`, `StartMenu.PinnedList`, `TopLevelSuggestionsContainer`, `ZoomControl` (All), `StartDocked.UserTileView`, `StartDocked.PowerOptionsView`.
- **Narrator** reads the pinned grid as a list of items with their position ("3 of 18").
- **pane's identifiers:** in the plan, §Identifiers.

Sources: Microsoft Windows Insider blog (2025-06-09, 2026-05-15, 2026-05-29, 2026-10-07); BleepingComputer; Windows Latest (2025-03-23, 2026-07-01, 2026-07-27, 2026-09-08); PCWorld (two articles); Thurrott (two); pureinfotech; deskmodder; The Register (2026-07-21); Microsoft Learn (Geometry); Microsoft Support (keyboard shortcuts); the Windhawk Start menu styling guide; Apple QA1134; Apple Developer Forums 129646 and 722807; Eclectic Light (2023-08-04); Chromium `login_util.cc`; timac.org; jaywcjlove/SystemSettings-URLs-macOS; Macworld; iBoysoft; Tom's Hardware; Winaero.
