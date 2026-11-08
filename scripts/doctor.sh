#!/bin/bash
# Checks this Mac can build, test, and run PR Tally, and says how to fix what's missing.
set -uo pipefail
cd "$(dirname "$0")/.."

problems=0
ok() { echo "ok    $1"; }
fail() { echo "FIX   $1"; echo "      $2"; problems=$((problems + 1)); }

macos="$(sw_vers -productVersion)"
if [[ "${macos%%.*}" -ge 14 ]]; then ok "macOS $macos"; else fail "macOS $macos" "PR Tally needs macOS 14 or later."; fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
if [[ -z "$developer_dir" ]]; then
  fail "No developer tools" "Install Xcode from the App Store."
elif [[ "$developer_dir" == *CommandLineTools* && "${macos%%.*}" -ge 27 ]]; then
  # bundle.sh and install.sh find Xcode on their own; swift test and swift run don't.
  fail "Command Line Tools selected ($developer_dir)" \
    "On macOS 27 they can't compile SwiftUI. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
  ok "Developer tools at $developer_dir"
fi

if command -v swift >/dev/null; then ok "$(swift --version 2>/dev/null | head -n 1)"; else fail "swift not found" "Install Xcode."; fi

if command -v gh >/dev/null; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh logged in as $(gh api user --jq .login 2>/dev/null || echo '?')"
  else
    fail "gh not logged in" "Run: gh auth login (or save a token in the app's settings)."
  fi
else
  fail "gh not found" "Install it from https://cli.github.com, or save a token in the app's settings."
fi

if [[ $problems -eq 0 ]]; then
  echo "Ready. Next: swift test --skip KeychainTokenTests, then ./scripts/install.sh"
else
  echo "$problems thing(s) to fix."
  exit 1
fi
