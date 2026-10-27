# Research behind pane's engine

Notes from studying how other macOS tools do Windows-style window management, and how Windows 11 itself behaves.
pane re-implemented the techniques; it doesn't copy code (see `CONTRIBUTING.md`). File and line references point into
shallow clones of each project under `refs/`, which isn't part of this repository.

| Note | Covers |
|---|---|
| [`wm-engines.md`](wm-engines.md) | AeroSpace, yabai, Amethyst, Hammerspoon: window registry, focus, threading, Spaces, hotkeys, displays |
| [`alt-tab.md`](alt-tab.md) | AltTab: window enumeration, live updates, single-window activation, overriding ⌘⇥ |
| [`snapping-maximize.md`](snapping-maximize.md) | Rectangle, Loop, easy-move-resize: frame setting, maximize/restore, drag snapping, title-bar double-click, the green button |
| [`click-through.md`](click-through.md) | Making the first click on an inactive window act, as on Windows |
| [`lifecycle-menus-instances.md`](lifecycle-menus-instances.md) | Quit on last window (swiftquit, Swindler), menus through AX, Alt navigation, middle clicks, new instances |
| [`taskbar-grouping.md`](taskbar-grouping.md) | Windows' combined taskbar buttons, the group pop-up and its keys; DockDoor and Tungsten Edge |
| [`start-menu.md`](start-menu.md) | Windows 11's Start, and the macOS APIs behind each part |
| [`settings-and-keys.md`](settings-and-keys.md) | Settings and shortcut design in AltTab, Rectangle, Ice and Windows 11 |
| [`startup-adoption.md`](startup-adoption.md) | Starting pane while windows are already open, maximized or in full screen |
