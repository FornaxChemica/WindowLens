#!/usr/bin/env bash
# Build a WindowLens DMG + Sparkle appcast for GitHub Releases.
#
# Default (no paid Apple Developer Program):
#   Ad-hoc sign the .app (codesign -), wrap in a DMG, sign the update with Sparkle,
#   upload to GitHub Releases. Testers open via Privacy & Security → Open Anyway.
#
# Optional later (paid program):
#   ./scripts/release.sh --version 1.0.0 --build 1 --developer-id
#
# Usage:
#   ./scripts/release.sh --version 1.0.0 --build 1
#   ./scripts/release.sh --version 1.0.1 --build 2 --skip-github
#   ./scripts/release.sh --version 1.0.0 --build 1 --developer-id
#
# Outputs (gitignored):
#   dist/release/WindowLens-<version>.dmg
#   dist/release/appcast.xml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="WindowLens"
TEAM_ID="2H4922DF8G"
PROJECT="WindowLens.xcodeproj"
SCHEME="WindowLens"
CONFIGURATION="Release"
NOTARY_PROFILE="${NOTARY_PROFILE:-WindowLens-Notary}"
GITHUB_REPO="${GITHUB_REPO:-FornaxChemica/WindowLens}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-$ROOT/.secrets/sparkle_ed25519_private.key}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.6}"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/.tools}"
SPARKLE_DIR="$TOOLS_DIR/Sparkle-$SPARKLE_VERSION"
DIST_DIR="$ROOT/dist/release"
DERIVED_DATA_PATH="$ROOT/.build/ReleaseDerivedData"
ARCHIVE_PATH="$DERIVED_DATA_PATH/WindowLens.xcarchive"
EXPORT_DIR="$DERIVED_DATA_PATH/Export"
ADHOC_ENTITLEMENTS="$ROOT/scripts/adhoc.entitlements"

VERSION=""
BUILD=""
MODE="adhoc" # adhoc | developer-id
SKIP_NOTARIZE=0
SKIP_GITHUB=0
SKIP_VERSION_WRITE=0
NOTES_FILE=""

usage() {
  cat <<EOF
Build WindowLens release artifacts (DMG + Sparkle appcast).

Usage:
  ./scripts/release.sh --version X.Y.Z --build N [options]

Modes:
  (default)           Ad-hoc signed DMG — free, testers use Open Anyway
  --developer-id      Developer ID + notarization (paid Apple Developer Program)

Options:
  --skip-github       Don't create/upload a GitHub Release
  --skip-notarize     Skip notarization (developer-id mode only)
  --skip-version-write
  --notes FILE        GitHub release notes file
  --help

See docs/RELEASING.md for Gatekeeper / install instructions.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --build) BUILD="${2:?}"; shift 2 ;;
    --adhoc) MODE="adhoc"; shift ;;
    --developer-id) MODE="developer-id"; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --skip-github) SKIP_GITHUB=1; shift ;;
    --skip-version-write) SKIP_VERSION_WRITE=1; shift ;;
    --notes) NOTES_FILE="${2:?}"; shift 2 ;;
    --help|-h) usage ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Required: --version X.Y.Z and --build N" >&2
  echo "Example: ./scripts/release.sh --version 1.0.0 --build 1" >&2
  exit 1
fi

log() { printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_developer_id() {
  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -n 1 || true)"
  [[ -n "$identity" ]] || die "No Developer ID Application certificate found. Use default ad-hoc mode, or enroll in the Apple Developer Program."
  printf '%s\n' "$identity"
}

ensure_sparkle_tools() {
  if [[ -x "$SPARKLE_DIR/bin/generate_appcast" && -x "$SPARKLE_DIR/bin/sign_update" ]]; then
    return 0
  fi

  log "Downloading Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$TOOLS_DIR"
  local archive="$TOOLS_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  local url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$archive" "$url"
  rm -rf "$SPARKLE_DIR"
  mkdir -p "$SPARKLE_DIR"
  tar -xf "$archive" -C "$SPARKLE_DIR"

  if [[ ! -x "$SPARKLE_DIR/bin/generate_appcast" ]]; then
    local nested
    nested="$(find "$SPARKLE_DIR" -type f -path '*/bin/generate_appcast' | head -n 1 || true)"
    [[ -n "$nested" ]] || die "generate_appcast missing after Sparkle download"
    SPARKLE_DIR="$(cd "$(dirname "$nested")/.." && pwd)"
  fi
  [[ -x "$SPARKLE_DIR/bin/generate_appcast" ]] || die "Sparkle generate_appcast not executable"
}

write_versions() {
  [[ "$SKIP_VERSION_WRITE" == "1" ]] && return 0
  log "Writing version $VERSION ($BUILD) into Xcode project…"
  python3 - "$ROOT/WindowLens.xcodeproj/project.pbxproj" "$VERSION" "$BUILD" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
version, build = sys.argv[2], sys.argv[3]
text = path.read_text()
text2, n1 = re.subn(r"(MARKETING_VERSION = )[^;]+;", rf"\g<1>{version};", text)
text3, n2 = re.subn(r"(CURRENT_PROJECT_VERSION = )[^;]+;", rf"\g<1>{build};", text2)
if n1 < 2 or n2 < 2:
    raise SystemExit(f"Unexpected version rewrite counts: MARKETING={n1} BUILD={n2}")
path.write_text(text3)
print(f"Updated MARKETING_VERSION→{version} ({n1} sites), CURRENT_PROJECT_VERSION→{build} ({n2} sites)", file=sys.stderr)
PY
}

build_adhoc_app() {
  log "Building Release (ad-hoc distribution)…"
  rm -rf "$DERIVED_DATA_PATH"
  mkdir -p "$DERIVED_DATA_PATH"

  # Build with whatever local signing Xcode has; we re-sign ad-hoc next.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    ENABLE_HARDENED_RUNTIME=YES >&2

  local app="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
  [[ -d "$app" ]] || die "Built app missing at $app"

  log "Ad-hoc signing app bundle (avoids “damaged and can’t be opened”)…"
  [[ -f "$ADHOC_ENTITLEMENTS" ]] || die "Missing $ADHOC_ENTITLEMENTS"

  # Sign nested code first, then the bundle (inside-out).
  find "$app" \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.app" \) -prune -o -type f -print 2>/dev/null | true
  codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ADHOC_ENTITLEMENTS" \
    "$app" >&2

  codesign --verify --deep --strict "$app" >&2
  codesign -dv --verbose=2 "$app" 2>&1 | grep -E 'Signature|Flags|Authority|Sealed' >&2 || true

  # Fail loud if resources weren't sealed (Sequoia treats that as "damaged").
  if ! codesign -d --verbose=2 "$app" 2>&1 | grep -q "Sealed Resources"; then
    die "Ad-hoc signature is missing sealed resources — Gatekeeper will say the app is damaged"
  fi

  printf '%s\n' "$app"
}

build_developer_id_app() {
  local identity="$1"
  log "Archiving Release with Developer ID…"
  rm -rf "$DERIVED_DATA_PATH"
  mkdir -p "$DERIVED_DATA_PATH"

  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="$identity" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    ENABLE_HARDENED_RUNTIME=YES >&2

  log "Exporting Developer ID app…"
  local export_plist="$DERIVED_DATA_PATH/ExportOptions.plist"
  cat > "$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF

  rm -rf "$EXPORT_DIR"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$export_plist" >&2

  local app="$EXPORT_DIR/$APP_NAME.app"
  [[ -d "$app" ]] || die "Exported app missing at $app"
  codesign -dv --verbose=2 "$app" >&2
  printf '%s\n' "$app"
}

make_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  log "Creating DMG $(basename "$dmg_path")…"

  local stage
  stage="$(mktemp -d /tmp/windowlens-dmg.XXXXXX)"
  ditto "$app_path" "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"

  local temp_dmg="$DIST_DIR/.tmp-$APP_NAME.dmg"
  rm -f "$temp_dmg" "$dmg_path"
  mkdir -p "$DIST_DIR"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$stage" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$temp_dmg" >&2

  mv "$temp_dmg" "$dmg_path"
  rm -rf "$stage"
}

sign_dmg_developer_id() {
  local dmg_path="$1"
  local identity="$2"
  log "Signing DMG with Developer ID…"
  codesign --force --sign "$identity" --timestamp "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path" >&2
}

notarize_and_staple() {
  local dmg_path="$1"
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    log "Skipping notarization (--skip-notarize)"
    return 0
  fi

  log "Notarizing DMG (profile: $NOTARY_PROFILE)…"
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait >&2

  log "Stapling notarization ticket…"
  xcrun stapler staple "$dmg_path" >&2
  xcrun stapler validate "$dmg_path" >&2
}

rewrite_appcast_urls() {
  local appcast_path="$1"
  python3 - "$appcast_path" "$GITHUB_REPO" "$APP_NAME" <<'PY'
import pathlib, re, sys, urllib.parse
path = pathlib.Path(sys.argv[1])
repo = sys.argv[2]
app_name = sys.argv[3]
text = path.read_text()

def repl(match: re.Match[str]) -> str:
    url = match.group(1)
    name = pathlib.Path(urllib.parse.urlparse(url).path).name
    m = re.match(rf"{re.escape(app_name)}-([0-9]+(?:\.[0-9]+)*)\.dmg$", name)
    if not m:
        return match.group(0)
    version = m.group(1)
    full = f"https://github.com/{repo}/releases/download/v{version}/{name}"
    return f'url="{full}"'

text2, n = re.subn(r'url="([^"]+)"', repl, text)
path.write_text(text2)
print(f"Rewrote {n} enclosure URL(s) for GitHub Releases tags", file=sys.stderr)
PY
}

generate_appcast() {
  log "Generating Sparkle appcast…"
  [[ -f "$SPARKLE_PRIVATE_KEY" ]] || die "Missing Sparkle private key: $SPARKLE_PRIVATE_KEY"
  [[ -x "$SPARKLE_DIR/bin/generate_appcast" ]] || die "generate_appcast missing"

  "$SPARKLE_DIR/bin/generate_appcast" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY" \
    -o "$DIST_DIR/appcast.xml" \
    "$DIST_DIR" >&2

  [[ -f "$DIST_DIR/appcast.xml" ]] || die "appcast.xml was not created"
  rewrite_appcast_urls "$DIST_DIR/appcast.xml"
  echo "Appcast written to $DIST_DIR/appcast.xml" >&2
}

publish_github() {
  local dmg_path="$1"
  if [[ "$SKIP_GITHUB" == "1" ]]; then
    log "Skipping GitHub release (--skip-github)"
    return 0
  fi
  require_cmd gh

  local tag="v$VERSION"
  local title="$APP_NAME $VERSION"
  local notes_args=()
  if [[ -n "$NOTES_FILE" ]]; then
    notes_args+=(--notes-file "$NOTES_FILE")
  else
    if [[ "$MODE" == "adhoc" ]]; then
      notes_args+=(--notes "$(cat <<EOF
WindowLens $VERSION (build $BUILD)

**Ad-hoc signed** (not notarized). First launch on macOS:
1. Open the DMG and drag WindowLens to Applications
2. Open WindowLens — if blocked, open **System Settings → Privacy & Security**
3. Click **Open Anyway**, then confirm **Open**

See README for details.
EOF
)")
    else
      notes_args+=(--notes "WindowLens $VERSION (build $BUILD)")
    fi
  fi

  log "Publishing GitHub release ${tag}…"
  if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg_path" "$DIST_DIR/appcast.xml" \
      --repo "$GITHUB_REPO" --clobber >&2
  else
    gh release create "$tag" "$dmg_path" "$DIST_DIR/appcast.xml" \
      --repo "$GITHUB_REPO" \
      --title "$title" \
      "${notes_args[@]}" >&2
  fi

  echo "Release published:" >&2
  echo "  https://github.com/$GITHUB_REPO/releases/tag/$tag" >&2
  echo "  Feed: https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml" >&2
}

# ── main ─────────────────────────────────────────────────────────────
require_cmd xcodebuild
require_cmd codesign
require_cmd hdiutil
require_cmd curl
require_cmd python3

[[ -f "$SPARKLE_PRIVATE_KEY" ]] || die "Missing $SPARKLE_PRIVATE_KEY — restore from backup before releasing"

ensure_sparkle_tools
write_versions

echo "Release mode: $MODE" >&2

if [[ "$MODE" == "adhoc" ]]; then
  APP_PATH="$(build_adhoc_app)"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  make_dmg "$APP_PATH" "$DMG_PATH"
else
  require_cmd security
  DEVELOPER_ID_IDENTITY="$(find_developer_id)"
  echo "Using identity: $DEVELOPER_ID_IDENTITY" >&2
  APP_PATH="$(build_developer_id_app "$DEVELOPER_ID_IDENTITY")"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  make_dmg "$APP_PATH" "$DMG_PATH"
  sign_dmg_developer_id "$DMG_PATH" "$DEVELOPER_ID_IDENTITY"
  notarize_and_staple "$DMG_PATH"
fi

generate_appcast
publish_github "$DMG_PATH"

log "Done"
echo "Mode:    $MODE"
echo "DMG:     $DMG_PATH"
echo "Appcast: $DIST_DIR/appcast.xml"
echo
if [[ "$MODE" == "adhoc" ]]; then
  echo "Testers: drag to Applications, then Privacy & Security → Open Anyway if blocked."
fi
echo "Update feed:"
echo "  https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
