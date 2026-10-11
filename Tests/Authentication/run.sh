#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifimancer-auth-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_dir" "$test_dir" <<'PY'
from pathlib import Path
import sys
repo, out = Path(sys.argv[1]), Path(sys.argv[2])
source = (repo / 'Helper/Sources/Service/main.swift').read_text()
authentication = source[:source.index('final class HelperListenerDelegate')]
tests = (repo / 'Tests/Authentication/ClientAuthenticationTests.swift').read_text()
(out / 'authentication.swift').write_text(authentication + tests)
stubs = '''import os
@objc protocol HelperProtocol {}
@objc protocol HelperEventReceiver {}
final class HelperService: NSObject {}
enum Log {
 static let xpc = Logger(subsystem: "offline", category: "xpc")
 static let root = Logger(subsystem: "offline", category: "root")
}
let kHelperMachServiceName = "offline"
'''
(out / 'main-typecheck.swift').write_text(stubs + source)
PY
xcrun swiftc -swift-version 5 -strict-concurrency=complete -typecheck "$test_dir/main-typecheck.swift"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    "$test_dir/authentication.swift" -o "$test_dir/authentication-tests"
"$test_dir/authentication-tests"
