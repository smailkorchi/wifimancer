#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Shared/Sources/Models/DeviceIdentification.swift" \
    "$ROOT/Shared/Sources/Models/Device.swift" \
    "$ROOT/Tests/Identification/ModelTests.swift" -o "$WORK/tests"
"$WORK/tests"
