#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Shared/Sources/Models/DeviceIdentification.swift" \
  "$ROOT/App/State/ReverseNameDiscovery.swift" \
  "$ROOT/Tests/ReverseName/ReverseNameTests.swift" -o "$WORK/tests"
"$WORK/tests"
