#!/usr/bin/env bash
# CI release build for macOS: fetch ghostty, build, sign, notarize, staple,
# zip. Designed for a Forgejo macos runner; safe to run locally too.
#
# Env:
#   VERSION            release version, e.g. 0.3.0 (stamped into Info.plist)
#   SIGN_IDENTITY      Developer ID Application identity (default: repo Makefile)
#   APPLE_CERT_P12_B64 base64 of the Developer ID .p12 (CI only; skips when unset)
#   APPLE_CERT_PASSWORD  password for the .p12 (CI only)
#   KEYCHAIN_PASSWORD  password for the temp CI keychain (CI only)
#   APPLE_ID, APPLE_TEAM_ID, NOTARY_PASSWORD  notarytool API auth (CI only;
#                      local builds keep using the NOTARY_PROFILE keychain profile)
#   NOTARY_PROFILE     local keychain profile (default: gct)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION required, e.g. VERSION=0.3.0}"
VERSION="${VERSION#v}"  # tags arrive as v0.3.0
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Tanishq Dubey (P3FJ87836G)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-gct}"
APP="build/Grand Central Terminal.app"

# 1. Developer ID cert into a temp keychain (CI only: secret provided).
if [ -n "${APPLE_CERT_P12_B64:-}" ]; then
  echo "== importing signing cert =="
  KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD required with APPLE_CERT_P12_B64}"
  APPLE_CERT_PASSWORD="${APPLE_CERT_PASSWORD:-}"
  KC="$RUNNER_TEMP/gct-sign.keychain-db"
  echo "$APPLE_CERT_P12_B64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
  security import "$RUNNER_TEMP/cert.p12" -P "$APPLE_CERT_PASSWORD" \
    -k "$KC" -T /usr/bin/codesign
  security list-keychains -d user -s "$KC" "$(security list-keychains -d user | tr -d ' "')"
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KC"
  rm -f "$RUNNER_TEMP/cert.p12"
fi

# 2. Sources + toolchain.
./scripts/fetch-ghostty.sh
ZIG_BIN="$(command -v zig || true)"
if [ -z "$ZIG_BIN" ]; then
  echo "== installing zig 0.17.0 =="
  ZIG_VER="0.17.0"
  ZIG_ARCH="$(uname -m | sed -e 's/arm64/aarch64/')"
  curl -fsSL -o /tmp/zig.tar.xz \
    "https://ziglang.org/download/${ZIG_VER}/zig-${ZIG_ARCH}-macos-${ZIG_VER}.tar.xz"
  tar -xf /tmp/zig.tar.xz -C /tmp && rm /tmp/zig.tar.xz
  export PATH="/tmp/zig-${ZIG_ARCH}-macos-${ZIG_VER}:$PATH"
fi

# 3. Stamp the version, then the normal build. ZIG= points at the real
# binary: the Makefile default is a local path that won't exist on CI.
PLIST="Resources/Info.plist"
cp "$PLIST" /tmp/Info.plist.bak
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
GCTD_VERSION_SRC="Sources/Daemon/Version.swift"
cp "$GCTD_VERSION_SRC" /tmp/Version.swift.bak
sed -i '' "s/GCTVersion = \"dev\"/GCTVersion = \"$VERSION\"/" "$GCTD_VERSION_SRC"
trap 'cp /tmp/Info.plist.bak Resources/Info.plist; cp /tmp/Version.swift.bak Sources/Daemon/Version.swift' EXIT
make build ZIG="$(command -v zig)"

# 4. Sign (hardened runtime, explicit inner-first order — no --deep).
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/GrandCentralTerminal" \
  "$APP/Contents/MacOS/gctd" \
  "$APP/Contents/MacOS/ptyexec"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 5. Notarize: API-key auth on CI, keychain profile locally.
ZIP="build/GrandCentralTerminal-${VERSION}-macos-arm64.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PASSWORD:-}" ]; then
  xcrun notarytool submit "$ZIP" \
    --apple-id "${APPLE_ID:?}" --team-id "${APPLE_TEAM_ID:?}" \
    --password "$NOTARY_PASSWORD" --wait
else
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"  # re-zip WITH the ticket
spctl -a -t exec -vv "$APP"
echo "release: $ZIP"
