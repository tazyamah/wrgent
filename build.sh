#!/bin/bash
#
# wrgent (Weekly Report GENeraTor) build script
# Builds, signs, deploys to /Applications, and launches.
#
set -euo pipefail

APP_NAME="wrgent"
APP_DIR="${APP_NAME}.app"
DEST="/Applications/${APP_DIR}"
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"

if [[ -x "${XCODE_DEV}/usr/bin/swift" ]]; then
    export DEVELOPER_DIR="${XCODE_DEV}"
    unset TOOLCHAINS 2>/dev/null || true
    unset SDKROOT 2>/dev/null || true
    SWIFT="${XCODE_DEV}/usr/bin/swift"
else
    SWIFT="swift"
fi

echo "==> Toolchain: $("${SWIFT}" --version | head -1)"

echo "==> Building ${APP_NAME} ..."
"${SWIFT}" build -c release
BIN_PATH="$("${SWIFT}" build -c release --show-bin-path)/${APP_NAME}"
[[ -f "${BIN_PATH}" ]] || { echo "Build failed: binary not found" >&2; exit 1; }

echo "==> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
[[ -f "Resources/AppIcon.icns" ]] && cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

BUILD_ID="$(date +%Y%m%d.%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_ID}" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
echo "   build id: ${BUILD_ID}"

echo "==> Code signing ..."
IDENTITY="wrgent Self-Signed"
if codesign --force --deep --sign "${IDENTITY}" "${APP_DIR}"; then
    echo "   using stable identity: ${IDENTITY}"
else
    echo "   using ad-hoc signature."
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "==> Deploying to ${DEST} ..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1
rm -rf "${DEST}"
cp -R "${APP_DIR}" "${DEST}"

echo ""
echo "Done. Canonical app: ${DEST} (build ${BUILD_ID})"
echo ""

open "${DEST}"
