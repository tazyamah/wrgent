#!/bin/bash
#
# wrgent (Weekly Report GENeraTor) build script
# Builds, signs, deploys to /Applications, and launches.
#
set -euo pipefail

APP_NAME="wrgent"
APP_DIR="${APP_NAME}.app"
DEST="/Applications/${APP_DIR}"
SWIFT="${WRGENT_SWIFT:-swift}"
SDK_PATH="${WRGENT_SDK_PATH:-$(xcrun --show-sdk-path)}"
# このCLTの27.0 SDKにはSwiftUIのStateマクロが含まれないため、
# 導入済みの26.5 SDKを使う。明示したSDK指定は優先する。
if [[ -z "${WRGENT_SDK_PATH:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
BUILD_ARGS=(-c release --build-system native --sdk "${SDK_PATH}")

echo "==> Toolchain: $("${SWIFT}" --version | head -1)"
echo "==> SDK: ${SDK_PATH}"
echo "==> Building ${APP_NAME} ..."
"${SWIFT}" build "${BUILD_ARGS[@]}"
BIN_PATH="$("${SWIFT}" build "${BUILD_ARGS[@]}" --show-bin-path)/${APP_NAME}"
[[ -f "${BIN_PATH}" ]] || { echo "Build failed: binary not found" >&2; exit 1; }

echo "==> Assembling ${APP_DIR} ..."
bash Scripts/prepare-mlx-runtime.sh
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
[[ -f "Resources/AppIcon.icns" ]] && cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp "Resources/mlx_worker.py" "${APP_DIR}/Contents/Resources/mlx_worker.py"
ditto ".build/mlx-runtime" "${APP_DIR}/Contents/Resources/MLXRuntime"

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

codesign --verify --deep --strict "${APP_DIR}"
if [[ "${WRGENT_BUILD_ONLY:-0}" == 1 ]]; then
    echo "Build-only complete: ${APP_DIR} (build ${BUILD_ID})"
    exit 0
fi

echo "==> Deploying to ${DEST} ..."
# コピーと署名確認を先に終え、置換に失敗しても現行版を戻せるようにする。
DEPLOY_ROOT="$(mktemp -d "${PWD}/.build/deploy.XXXXXX")"
ditto "${APP_DIR}" "${DEPLOY_ROOT}/next.app"
codesign --verify --deep --strict "${DEPLOY_ROOT}/next.app"
for pid in $(pgrep -x "${APP_NAME}" || true); do
    OPEN_AUDIO="$(lsof -p "${pid}" -Fn 2>/dev/null | grep -E '^n.*\.m4a$' || true)"
    if [[ -n "${OPEN_AUDIO}" ]]; then
        echo "録音または音声処理中のため、アプリの入れ替えを中止しました。" >&2
        exit 1
    fi
done
# The crash guardian intentionally relaunches after an unexpected process exit.
# Disable any running instance's guardian before replacing the bundle.
GUARD_DIR="${HOME}/Library/Application Support/wrgent/crash-guardian"
if [[ -d "${GUARD_DIR}" && ! -L "${GUARD_DIR}" ]]; then
    find "${GUARD_DIR}" -maxdepth 1 -type f -name 'guardian-*' -user "$(id -u)" \
        -exec sh -c 'printf stop > "$1"' _ {} \;
fi
# Disable the pre-guardian release's per-user temporary markers once during
# migration.  TMPDIR is user-specific; files must be regular and user-owned.
LEGACY_GUARD_DIR="${TMPDIR%/}"
if [[ -d "${LEGACY_GUARD_DIR}" && ! -L "${LEGACY_GUARD_DIR}" ]]; then
    find "${LEGACY_GUARD_DIR}" -maxdepth 1 -type f -name 'wrgent-crash-guardian-*' -user "$(id -u)" \
        -exec sh -c 'printf stop > "$1"' _ {} \;
fi
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1
if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "既存アプリが終了していないため、入れ替えを中止しました。" >&2
    exit 1
fi
if [[ -d "${DEST}" ]]; then
    mv "${DEST}" "${DEPLOY_ROOT}/previous.app"
fi
if ! mv "${DEPLOY_ROOT}/next.app" "${DEST}"; then
    if [[ -d "${DEPLOY_ROOT}/previous.app" ]]; then
        mv "${DEPLOY_ROOT}/previous.app" "${DEST}"
        open "${DEST}"
    fi
    exit 1
fi

echo ""
echo "Done. Canonical app: ${DEST} (build ${BUILD_ID})"
echo ""

open "${DEST}"
