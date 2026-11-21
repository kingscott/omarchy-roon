---
name: roon-installer-checksums
description: Fix "checksum verification failed" when roon-proton installs Roon or Roon Bridge. Use when install or endpoint install fails on a hash mismatch, or when Roon ships a new build and the pinned SHA-512 hashes in roon-wine need updating.
---

# Roon installer checksums

## Why it breaks

`roon-wine` downloads two Roon artifacts from URLs with no version in them, so
they always serve the latest upload:

- `INSTALLER_URL` (`RoonInstaller64.exe`), pinned by `INSTALLER_SHA512`
- `BRIDGE_URL` (`RoonBridge_linuxx64.tar.bz2`), pinned by `BRIDGE_SHA512`

When Roon ships a new build, or re-uploads the same build, the hash no longer
matches. `download_verified` then deletes the partial download and dies with
`<label> checksum verification failed; the upstream artifact may have changed`.
The Proton runtime is not affected: its URL contains `PROTON_VERSION`.

## Fix

1. Download each failing artifact into an empty scratch directory and hash it:

   ```sh
   curl --proto '=https' --fail --location --output "$dir/file" "$URL"
   sha512sum "$dir/file"
   ```

2. Set the new value in `INSTALLER_SHA512` and/or `BRIDGE_SHA512` in `roon-wine`.
   The README says the Windows installer was checked for its Harman
   International Authenticode signature when its hash was last updated. Do that
   check before pinning a new installer.
3. `roon-wine` is a package source, so its sha256 changes. Run
   `sha256sum roon-wine` and replace the first entry of `sha256sums` in
   `PKGBUILD` and the first `sha256sums` line in `.SRCINFO`.
4. Bump `pkgrel` in both `PKGBUILD` and `.SRCINFO` (or run
   `makepkg --printsrcinfo > .SRCINFO` on Arch).
5. Run `make check`.

## Notes

- Verified downloads are cached in `${XDG_CACHE_HOME:-~/.cache}/roon-wine`. A
  cached file is reused only if it matches the pinned hash.
- Past example: commit `9177e04` (installer moved to a new build; the Bridge
  archive kept its build number but had a new checksum).
