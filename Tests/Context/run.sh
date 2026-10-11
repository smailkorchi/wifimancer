#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifimancer-context-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/Shared/Sources/Models/DeviceIdentification.swift" "$repo_dir/Shared/Sources/Models/Device.swift" \
    "$repo_dir/Shared/Sources/Models/Network.swift" \
    "$repo_dir/Shared/Sources/Models/EngagementScope.swift" \
    "$repo_dir/Shared/Sources/Models/CutTargetReconciler.swift" \
    "$repo_dir/Shared/Sources/Models/CutSession.swift" \
    "$repo_dir/Helper/Sources/Util/ContextDetector.swift" \
    "$repo_dir/Tests/Context/ContextFixtures.swift" \
    "$repo_dir/Tests/Context/ContextDetectorTests.swift" -o "$test_dir/context-tests"
"$test_dir/context-tests"
