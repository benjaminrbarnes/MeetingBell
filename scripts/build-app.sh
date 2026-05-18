#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MeetingBell"
BUILD_CONFIGURATION="release"
BUILD_DIR="$PROJECT_DIR/.build/$BUILD_CONFIGURATION"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ROOT_APP_DIR="$PROJECT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"

swift build -c "$BUILD_CONFIGURATION"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
  sleep 0.5
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
if [[ "${MEETINGBELL_DEVELOPMENT_MODE:-1}" != "0" ]]; then
  touch "$RESOURCES_DIR/DevelopmentMode.enabled"
fi
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

rm -rf "$ROOT_APP_DIR"
cp -R "$APP_DIR" "$ROOT_APP_DIR"

if [[ "${MEETINGBELL_RELAUNCH:-1}" != "0" ]]; then
  open "$ROOT_APP_DIR"
  RELAUNCH_MESSAGE="Relaunched $ROOT_APP_DIR."
else
  RELAUNCH_MESSAGE="Skipped relaunch because MEETINGBELL_RELAUNCH=0."
fi

echo "Built $APP_DIR"
echo "Also copied it to $ROOT_APP_DIR for double-click launching."
echo "$RELAUNCH_MESSAGE"
if [[ "${MEETINGBELL_DEVELOPMENT_MODE:-1}" != "0" ]]; then
  echo "Development testing menu is enabled."
fi
