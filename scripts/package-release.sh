#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MeetingBell"
VERSION="${1:-0.1.1}"
RELEASE_DIR="$PROJECT_DIR/release"
APP_PATH="$PROJECT_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macOS.zip"

MEETINGBELL_RELAUNCH=0 MEETINGBELL_DEVELOPMENT_MODE=0 "$PROJECT_DIR/scripts/build-app.sh"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Created $ZIP_PATH"
echo "Upload this zip to a GitHub Release."
