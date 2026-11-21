---
name: roon-plugin-debugging
description: Debug or iterate on the Omarchy bar plugin in plugin/. Use when the widget shows an error or "waiting for authorization", edits do not take effect, you need shell logs, or you want to open the card from the command line for testing or screenshots.
---

# Omarchy Roon plugin

## Run the helper alone

```sh
python3 -I plugin/roon-helper.py --host <core-ip>      # --port defaults to 9330
```

It prints JSON lines. Status values: `no_host`, `connecting`, `waiting_auth`,
`connected`, `error` (with `message`); then `zones` and `art` events. Closing
stdin makes it exit. Log lines on stderr start with `omarchy-roon:`.

- `waiting_auth`: the user must enable **Omarchy Roon** in Roon under
  **Settings > Extensions**. Needed once per Core.
- Pairing token: `~/.config/omarchy-roon/state.json`.
- Album art cache: `$XDG_RUNTIME_DIR/omarchy-roon/art/`.

## Reload after edits

The plugin is installed as a symlink,
`~/.config/omarchy/plugins/kingscott.roon -> <repo>/plugin`. The shell runs with
`QS_DISABLE_FILE_WATCHER=1`, so edits behind the symlink are not picked up. Run
`omarchy restart shell` after every change.

## Shell logs

```sh
quickshell list --all              # note the instance id
quickshell log -i <id> -t 200      # add -f to follow
```

`RoonService.qml` forwards the helper's stderr to the shell log.

## Open the card from the command line

```sh
omarchy-shell shell summon kingscott.roon '{}'   # also: toggle, hide <id>
```

Useful for screenshots and testing without clicking the bar. `Panel.qml`
exposes `open()`, `close()` and `opened` for this.

For `grim -g "<x>,<y> <w>x<h>"`, coordinates are logical, not physical pixels.
On a scaled display, divide physical pixels by the monitor scale
(`hyprctl monitors -j | jq '.[].scale'`).
