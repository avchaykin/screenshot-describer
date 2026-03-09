#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build-app.sh"

mkdir -p dist
cd dist
rm -f screenshot-describer-macos.zip
zip -qry screenshot-describer-macos.zip ScreenshotDescriber.app
shasum -a 256 screenshot-describer-macos.zip | awk '{print $1}'
