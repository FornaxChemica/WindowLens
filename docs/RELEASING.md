# Releasing WindowLens

Two shipping modes:

| Mode | Cost | Gatekeeper UX |
| --- | --- | --- |
| **Ad-hoc (default)** | Free | One-time **Open Anyway** in Privacy & Security |
| **Developer ID** (`--developer-id`) | Apple Developer Program (~$99/yr) | Double-click; no warning |

Most early open-source Mac apps ship ad-hoc. The important trick: **properly ad-hoc sign** the `.app` (`codesign -`). A half-signed or unsigned bundle on Sequoia+ often shows **“is damaged”** with **no bypass**. A valid ad-hoc signature shows **“Apple could not verify…”**, which users can approve.

## Ad-hoc release (recommended for now)

### Prerequisites

1. Sparkle private key: `.secrets/sparkle_ed25519_private.key`
2. Optional upload: `gh auth login`

### Ship

```bash
./scripts/release.sh --version 1.0.0 --build 1
```

This:

1. Builds Release  
2. Ad-hoc signs with `scripts/adhoc.entitlements` (includes `disable-library-validation` so Sparkle loads)  
3. Creates `dist/release/WindowLens-<version>.dmg`  
4. Generates Sparkle-signed `appcast.xml`  
5. Uploads a GitHub Release (`v<version>`) with DMG + appcast  

Flags: `--skip-github`, `--skip-version-write`, `--notes FILE`.

## What testers do

1. Download the DMG from [Releases](https://github.com/FornaxChemica/WindowLens/releases)  
2. Drag **WindowLens** to **Applications**  
3. Open it  
4. If macOS blocks it:
   - **System Settings → Privacy & Security**
   - Scroll to the message about WindowLens
   - Click **Open Anyway**, then **Open**  
5. Grant Accessibility / Input Monitoring / Screen Recording as prompted  

Terminal fallback (if needed):

```bash
xattr -cr /Applications/WindowLens.app
```

macOS remembers the exception; later launches are normal. Sparkle updates still work (EdDSA-signed DMGs); first open of a new build may need Open Anyway again until you notarize.

## Developer ID + notarization (later)

When enrolled in the Apple Developer Program:

```bash
xcrun notarytool store-credentials "WindowLens-Notary" \
  --apple-id YOUR@email.com \
  --team-id 2H4922DF8G \
  --password "app-specific-password"

./scripts/release.sh --version 1.0.1 --build 2 --developer-id
```

## Homebrew

Official Homebrew casks are moving toward requiring notarization. For unsigned/ad-hoc apps, prefer GitHub Releases (or a **personal** tap), not `homebrew/cask`.

## Why not “just leave it unsigned”?

| Bundle state | Typical Sequoia result |
| --- | --- |
| No / broken bundle signature | **“is damaged”** — often no Open Anyway |
| Valid **ad-hoc** signature | **“could not verify”** — Open Anyway works |
| Developer ID + notarized | Opens cleanly |

Tools like [Sentinel](https://github.com/alienator88/Sentinel) help end users clear quarantine locally; we don’t require them — README + Open Anyway is enough.
