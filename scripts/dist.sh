#!/bin/bash
# Build a Developer ID–signed, hardened-runtime, NOTARIZED Screen Divider for
# direct download (the website). Unlike install.sh (local dev build, self-signed),
# this produces a build macOS Gatekeeper accepts with a normal double-click.
#
# Requires:
#   - "Developer ID Application: Harvey Creative LLC (Q9NN4C8339)" in the keychain
#   - Notary credentials. By default this uses the Harvey Creative App Store
#     Connect API key already on this Mac (same key the Beacon/Marketer
#     TestFlight pipelines use) — NO app-specific password needed:
#       ~/.appstoreconnect/private_keys/AuthKey_NZV2GU7863.p8
#     Override with ASC_KEY_ID / ASC_ISSUER / ASC_P8 env vars if the key rotates.
#     Fallbacks (only if the .p8 is absent):
#       NOTARY_KEYCHAIN_PROFILE  a profile saved via `notarytool store-credentials`
#       NOTARY_APPLE_ID + NOTARY_PASSWORD (app-specific) + NOTARY_TEAM_ID
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
APP="$DIST/Screen Divider.app"
ZIP="$DIST/ScreenDivider.zip"
IDENTITY="Developer ID Application: Harvey Creative LLC (Q9NN4C8339)"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building (full features, no paywall)…"
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit -framework ApplicationServices \
  -D SD_LOCAL_UNLOCK -O -o "$DIST/ScreenDivider" \
  $(find Sources/ScreenDivider -name "*.swift")

cp "$DIST/ScreenDivider" "$APP/Contents/MacOS/ScreenDivider"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/menubar-icon.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/menubar-icon@2x.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/menubar-icon@3x.png "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/config-example.json "$APP/Contents/Resources/" 2>/dev/null || true
rm -f "$DIST/ScreenDivider"

echo "==> Signing with Developer ID + hardened runtime…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Zipping…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ---- Notarize ----
# Preferred: Harvey Creative App Store Connect API key (no app-specific password).
ASC_KEY_ID="${ASC_KEY_ID:-NZV2GU7863}"
ASC_ISSUER="${ASC_ISSUER:-00573b3e-6c60-4953-a352-11858550eae1}"
ASC_P8="${ASC_P8:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-Q9NN4C8339}"
CREDS=()
if [ -f "$ASC_P8" ]; then
  echo "==> Notarizing with App Store Connect API key ($ASC_KEY_ID)."
  CREDS=(--key "$ASC_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")
elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  CREDS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  CREDS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
fi

if [ ${#CREDS[@]} -eq 0 ]; then
  echo "==> No notary credentials found — built + signed only (NOT notarized)."
  echo "    Expected API key at $ASC_P8, or set NOTARY_* env vars."
  exit 0
fi

echo "==> Submitting to Apple notary service (waits for result)…"
xcrun notarytool submit "$ZIP" "${CREDS[@]}" --wait

echo "==> Stapling the ticket…"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Verifying Gatekeeper acceptance…"
spctl -a -vvv -t exec "$APP" || true
xcrun stapler validate "$APP"

echo "==> Done. Notarized build: $ZIP"
