#!/bin/bash
# Builds PR Tally, installs it to ~/Applications, and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
pkill -x PRTally || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/PR Tally.app"
cp -R "dist/PR Tally.app" "$HOME/Applications/"
open "$HOME/Applications/PR Tally.app"
echo "Installed to ~/Applications/PR Tally.app. Look for the count in your menu bar."
