#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Shared/Sources/Models/DeviceIdentification.swift" "$ROOT/App/State/UPnPDiscovery.swift" \
  "$ROOT/Tests/UPnP/UPnPTests.swift" -o "$WORK/tests"
"$WORK/tests" "$ROOT/Tests/UPnP/Fixtures"
