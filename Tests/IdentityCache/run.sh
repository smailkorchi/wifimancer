#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    "$repo_dir/Shared/Sources/Models/DeviceIdentification.swift" \
    "$repo_dir/Shared/Sources/Models/Device.swift" \
    "$repo_dir/App/State/DeviceIdentityCache.swift" \
    "$repo_dir/Tests/IdentityCache/CacheTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
