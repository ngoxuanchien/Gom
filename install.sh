#!/usr/bin/env bash
# Build Gom from source and install it into /Applications (or $GOM_APP_DIR).
# Usage: ./install.sh   or   curl -fsSL https://raw.githubusercontent.com/ngoxuanchien/Gom/main/install.sh | bash
set -euo pipefail

APP_DIR="${GOM_APP_DIR:-/Applications}"

command -v xcodebuild >/dev/null || { echo "Xcode is required (xcodebuild not found)."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install XcodeGen first: https://github.com/yonaskolb/XcodeGen"; exit 1; }
  brew install xcodegen
fi

# Run from a checkout if we are in one. Otherwise keep a copy in a fixed place, since
# Chrome loads the unpacked extension from there and a temp dir would get cleaned up.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ ! -f "$SRC/Gom/project.yml" ]; then
  SRC="${GOM_SRC_DIR:-$HOME/Library/Application Support/Gom/source}"
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch --depth 1 origin main
    git -C "$SRC" reset --hard FETCH_HEAD
  else
    git clone --depth 1 https://github.com/ngoxuanchien/Gom.git "$SRC"
  fi
fi

cd "$SRC/Gom"
xcodegen generate
xcodebuild -project Gom.xcodeproj -scheme Gom -configuration Release \
  -derivedDataPath build -quiet build

osascript -e 'quit app "Gom"' 2>/dev/null || true
rm -rf "$APP_DIR/Gom.app"
cp -R build/Build/Products/Release/Gom.app "$APP_DIR/"
open "$APP_DIR/Gom.app"

echo
echo "Gom installed to $APP_DIR/Gom.app"
echo "Browser extension: open chrome://extensions, enable Developer mode,"
echo "click Load unpacked and choose: $SRC/extension"
echo "(Already loaded? Just click Reload on the Gom card.)"

# Chrome won't let scripts install unpacked extensions, so open both ends of the manual step.
if open -Ra "Google Chrome" 2>/dev/null; then
  open -a "Google Chrome" "chrome://extensions"
  open "$SRC/extension"
fi
