#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifimancer-session-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
models=(DeviceIdentification Device Network EngagementScope CutTargetReconciler CutSession)
model_files=()
for model in "${models[@]}"; do model_files+=("$repo_dir/Shared/Sources/Models/$model.swift"); done
xcrun swiftc -swift-version 5 -strict-concurrency=complete "${model_files[@]}" \
    "$repo_dir/Tests/Session/CutSessionTests.swift" -o "$test_dir/model-tests"
"$test_dir/model-tests"

# Compile the exact controller source and real packet actors. OS discovery is
# stubbed; every pcap symbol links to test implementations instead of libpcap.
python3 - "$repo_dir" "$test_dir/controller-tests.swift" <<'PY'
from pathlib import Path
import sys
repo, destination = Path(sys.argv[1]), Path(sys.argv[2])
source = (repo / 'Helper/Sources/Service/HelperService.swift').read_text()
controller = source[source.index('/// Actor isolation owns the policy/inventory.'):]
fixtures = (repo / 'Tests/Session/ControllerFixtures.swift').read_text()
tests = (repo / 'Tests/Session/ControllerTests.swift').read_text()
destination.write_text(fixtures + '\n' + controller + '\n' + tests)
PY
xcrun clang -std=c17 -Wall -Wextra -Werror -DPACKET_SAFETY_SWIFT_SUPPORT \
    -I "$repo_dir/Helper/CSources/include" -I "$repo_dir/Tests/PacketSafety" \
    -c "$repo_dir/Tests/PacketSafety/PacketSafetyTests.c" -o "$test_dir/offline-pcap.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -I "$repo_dir/Helper/CSources/include" \
    -c "$repo_dir/Helper/CSources/wm_arp.c" -o "$test_dir/wm-arp.o"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    -I "$repo_dir/Helper/CSources/include" \
    -import-objc-header "$repo_dir/Tests/PacketSafety/OfflinePcap.h" \
    "${model_files[@]}" "$repo_dir/Shared/Sources/Models/SpeedSample.swift" \
    "$repo_dir/Helper/Sources/Util/Logger.swift" \
    "$repo_dir/Helper/Sources/Spoof/ARPSpoofer.swift" \
    "$repo_dir/Helper/Sources/Spoof/ARPResponder.swift" \
    "$test_dir/controller-tests.swift" "$test_dir/offline-pcap.o" "$test_dir/wm-arp.o" \
    -o "$test_dir/controller-tests"
"$test_dir/controller-tests"

python3 - "$repo_dir" "$test_dir/rpc-tests.swift" <<'PY'
from pathlib import Path
import sys
repo, destination = Path(sys.argv[1]), Path(sys.argv[2])
source = (repo / 'App/State/HelperClient.swift').read_text()
request = source[source.index('    /// Each request owns its XPC error handler'):source.index('    nonisolated private static func decoded')]
reply = source[source.index('/// A reply and an XPC error may arrive concurrently.'):source.index('extension Notification.Name')]
fixtures = (repo / 'Tests/Session/RPCFixtures.swift').read_text()
tests = (repo / 'Tests/Session/RPCTests.swift').read_text()
client = '@MainActor private final class FixtureClient {\n var connection: FixtureConnection?\n var statusText = ""\n' + request + '\n}\n'
destination.write_text(fixtures + '\n' + client + reply + tests)
PY
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    "$test_dir/rpc-tests.swift" -o "$test_dir/rpc-tests"
"$test_dir/rpc-tests"
