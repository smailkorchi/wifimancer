#!/usr/bin/env bash
# One-time setup: install dependencies, fonts, and generate Xcode project.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install from https://brew.sh"; exit 1
fi

echo "→ installing tools"
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
brew list libpcap  >/dev/null 2>&1 || brew install libpcap

echo "→ checking Poppins/Lora fonts"
if ! ls ~/Library/Fonts/ | grep -qi "poppins"; then
    echo "  ! Poppins not found in ~/Library/Fonts — falling back to system."
    echo "    Download Poppins+Lora from Google Fonts and drop the .ttf files into:"
    echo "    Resources/Fonts/    (recommended for in-bundle registration)"
fi

echo "→ generating Xcode project"
xcodegen generate

echo
echo "Done. Next: ./Scripts/build.sh"
