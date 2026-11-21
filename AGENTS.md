# Agent notes

Repo: the `roon-proton` Arch package (Windows Roon through Proton/UMU, native
Roon Bridge for audio) and an Omarchy bar plugin in `plugin/`. See `README.md`.

Run `make check` before committing. Do not run `make check-arch` or `makepkg`
unless asked.

Debugging skills (`.claude/skills/`):

- `roon-installer-checksums`: install fails with "checksum verification failed".
- `roon-audio-endpoint`: missing zone, native Bridge without RAATServer, mode
  switching, discovery and firewall.
- `roon-plugin-debugging`: plugin helper, shell logs, reloads, opening the card
  from the command line.
- `roon-window-identity`: Roon's window class and title for rules and scripts.

`.agents/skills/verify-roon-proton` verifies the live System Output route.
