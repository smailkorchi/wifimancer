#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Shared/Sources/Models/DeviceIdentification.swift" \
    "$ROOT/App/State/MDNSAppEnricher.swift" "$ROOT/Tests/Bonjour/BonjourTests.swift" -o "$WORK/tests"
"$WORK/tests"
