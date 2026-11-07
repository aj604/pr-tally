#!/bin/bash
# Builds dist/PR Tally.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools can't build SwiftUI on macOS 27 and later (no
# SwiftUIMacros plugin), so use Xcode when it's installed but not selected.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
  xcode="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -n 1)"
  if [[ -n "$xcode" ]]; then
    export DEVELOPER_DIR="$xcode/Contents/Developer"
    echo "Building with $xcode"
  fi
fi

if ! swift build -c release --product PRTally; then
  if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == *CommandLineTools* ]]; then
    echo "Build failed with the Command Line Tools. On macOS 27 and later, install Xcode." >&2
  fi
  exit 1
fi
app="dist/PR Tally.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PRTally" "$app/Contents/MacOS/PRTally"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
