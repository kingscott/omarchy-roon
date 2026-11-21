---
name: roon-audio-endpoint
description: Debug the Roon audio endpoint on this machine. Use when the laptop zone is missing in Roon, native Bridge is active but has no RAATServer, playback fails to start, or switching between system, desktop, and direct modes goes wrong.
---

# Roon audio endpoint

Background on the three modes is in `README.md` (Audio output modes) and
`docs/architecture.md`.

## First checks

```sh
roon-proton doctor                 # from a checkout: bash ./roon-wine doctor
roon-proton endpoint status        # roonbridge-native.service
```

`doctor` prints `endpoint mode` as one of: System Output via shared PipeWire
device, exclusive/direct ALSA, or desktop System Output.

For system mode, `./.agents/skills/verify-roon-proton/verify-system-output.sh`
is a read-only check. It looks at the service, TCP 9200 ownership
(`ss -lntp | grep :9200`), the saved `plug:pipewire` output, and the RAAT log.

## Native Bridge is active but there is no zone

The Windows RAATServer (from the Proton prefix) and native Bridge share one
rendezvous. If the Windows one starts first, `roonbridge-native.service` stays
active without a native RAATServer child. `endpoint mode system|direct` avoids
this by stopping the managed prefix and UMU/Proton launchers, then starting
Bridge, so use it instead of restarting services by hand. Relaunch Roon
afterward (`roon-proton run`).

## Discovery

- A firewall can block discovery. With UFW, allow the trusted LAN:
  `sudo ufw allow from <subnet>/24`.
- If neither endpoint shows up in Roon while existing network zones work,
  restart Roon Server on the Core. This fixed stale Core-side RAAT discovery on
  2026-07-20 (`docs/testing.md`).

## Playback fails to start

- Roon's Settings page lists the first Loopback PCM; the saved output is
  rewritten to `plug:pipewire` with software volume in system mode. The log to
  read is `$XDG_DATA_HOME/roon-wine/native-endpoint/data/RAATServer/Logs/RAATServer_log.txt`
  (look for `opening [plug:pipewire]`).
- Settings live in `.../native-endpoint/data/RAATServer/Settings/device_*.json`.
- Format errors such as `FORMAT_NOT_SUPPORTED` on 44.1 kHz were the old
  fixed-rate loopback route (fixed in 0.2.0-9); they should not occur in system
  mode.

## Device held by the endpoint

`roon-proton endpoint release` restarts the endpoint and frees the ALSA device.
