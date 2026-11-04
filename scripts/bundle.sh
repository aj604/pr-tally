#!/bin/bash
# Builds dist/PR Tally.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PRTally
app="dist/PR Tally.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PRTally" "$app/Contents/MacOS/PRTally"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
