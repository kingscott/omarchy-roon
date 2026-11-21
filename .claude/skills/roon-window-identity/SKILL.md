---
name: roon-window-identity
description: Identify the Roon desktop window for window rules, focus scripts, or screenshots. Use when writing Hyprland or Niri rules, or debugging why the plugin cannot focus Roon.
---

# Roon window identity

The Windows Roon app runs through XWayland and its main window has:

- class / app-id: `steam_app_0`
- title: `Roon`

Packaged rules match both, so other Proton apps are unaffected and only the main
window tiles (dialogs and popups keep compositor defaults). Snippets are in
`roon-proton.hyprland.conf`, `roon-proton.hyprland.lua`, `roon-proton.niri.kdl`
and installed under `/usr/share/roon-proton/wm`. Docs: `docs/window-managers.md`.

Check the live values with `hyprctl clients` or `niri msg windows`.

The bar plugin (`plugin/Panel.qml`, `openRoon`) finds the window with
`hyprctl clients -j` using class `steam_app_0` and a title starting with `Roon`,
focuses it, or otherwise launches `roon-proton run`. If a Proton update changes
the class or title, update the rule files, the desktop entry's `StartupWMClass`,
and that filter.
