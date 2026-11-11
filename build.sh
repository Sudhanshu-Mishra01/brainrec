#!/usr/bin/env bash
# Builds BrainRec.app (release) from the Swift package and signs it.
#
#   ./build.sh                          # dev build, NOT sandboxed (easiest for first tests)
#   SANDBOX=1 ./build.sh                # same entitlements as the App Store build (test this before submitting)
#   SIGN_ID="BrainRec Dev" ./build.sh   # sign with a stable self-signed cert -> permissions survive rebuilds
#
# For the App Store itself use Xcode (see docs/APP_STORE.md), not this script.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This app only builds on macOS (needs ScreenCaptureKit / AVFoundation)." >&2
  exit 1
fi

APP="BrainRec.app"
SIGN_ID="${SIGN_ID:--}"
BUNDLE_ID="${BUNDLE_ID:-com.letscodebrain.brainrec}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ENTITLEMENTS="Resources/BrainRec.entitlements"
if [[ "${SANDBOX:-0}" == "1" ]]; then
  ENTITLEMENTS="Resources/BrainRec-AppStore.entitlements"
  echo "▶ sandboxed build (App Store entitlements)"
fi

echo "▶ swift build (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▶ assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/BrainRec" "${APP}/Contents/MacOS/BrainRec"

# Fill in the Xcode-style placeholders in Info.plist.
sed \
  -e "s|\$(PRODUCT_NAME)|BrainRec|g" \
  -e "s|\$(EXECUTABLE_NAME)|BrainRec|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" \
  -e "s|\$(MARKETING_VERSION)|${VERSION}|g" \
  -e "s|\$(CURRENT_PROJECT_VERSION)|${BUILD_NUMBER}|g" \
  -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|14.0|g" \
  Resources/Info.plist > "${APP}/Contents/Info.plist"

# App icon: build AppIcon.icns from the asset-catalog PNGs.
ICON_SRC="Resources/Assets.xcassets/AppIcon.appiconset"
if [[ -d "${ICON_SRC}" ]] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  cp "${ICON_SRC}"/*.png "${ICONSET}/"
  iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP}/Contents/Info.plist"
fi

echo "▶ signing with identity: ${SIGN_ID}"
codesign --force --deep --sign "${SIGN_ID}" \
  --entitlements "${ENTITLEMENTS}" "${APP}"

echo "✅ Built ${APP}"
echo "   Run:   open ${APP}"
echo "   (Always start it with 'open' or a double-click. Running the file inside the app from Terminal"
echo "    makes macOS give the Camera / Screen Recording permission to Terminal instead of BrainRec.)"
echo "   Logs:  touch /tmp/brainrec.log && open -W --stdout /tmp/brainrec.log --stderr /tmp/brainrec.log ${APP}"
