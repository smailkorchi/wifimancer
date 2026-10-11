#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifimancer-packet-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$repo_dir/Helper/CSources/include" -I "$repo_dir/Tests/PacketSafety" \
    "$repo_dir/Helper/CSources/wm_arp.c" \
    "$repo_dir/Helper/CSources/wm_pcap.c" \
    "$repo_dir/Tests/PacketSafety/PacketSafetyTests.c" -o "$test_dir/packet-tests"
"$test_dir/packet-tests"

xcrun clang -std=c17 -Wall -Wextra -Werror -DPACKET_SAFETY_SWIFT_SUPPORT \
    -I "$repo_dir/Helper/CSources/include" -I "$repo_dir/Tests/PacketSafety" \
    -c "$repo_dir/Tests/PacketSafety/PacketSafetyTests.c" -o "$test_dir/offline-pcap.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -I "$repo_dir/Helper/CSources/include" \
    -c "$repo_dir/Helper/CSources/wm_arp.c" -o "$test_dir/wm-arp.o"
xcrun swiftc -swift-version 5 -strict-concurrency=complete \
    -I "$repo_dir/Helper/CSources/include" \
    -import-objc-header "$repo_dir/Tests/PacketSafety/OfflinePcap.h" \
    "$repo_dir/Shared/Sources/Models/DeviceIdentification.swift" "$repo_dir/Shared/Sources/Models/Device.swift" \
    "$repo_dir/Shared/Sources/Models/Network.swift" \
    "$repo_dir/Helper/Sources/Util/Logger.swift" \
    "$repo_dir/Helper/Sources/Spoof/ARPSpoofer.swift" \
    "$repo_dir/Helper/Sources/Spoof/ARPResponder.swift" \
    "$repo_dir/Tests/PacketSafety/PacketActorSafetyTests.swift" \
    "$test_dir/offline-pcap.o" "$test_dir/wm-arp.o" -o "$test_dir/actor-tests"
"$test_dir/actor-tests"

xcrun clang -std=c17 -Wall -Wextra -Werror -I "$repo_dir/Helper/CSources/include" \
    -c "$repo_dir/Helper/CSources/wm_pcap.c" -o "$test_dir/wm-pcap.o"
cat "$repo_dir/Helper/Sources/Scan/ARPScanner.swift" \
    "$repo_dir/Tests/PacketSafety/ScannerCaptureTests.swift" > "$test_dir/scanner-tests.swift"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    -I "$repo_dir/Helper/CSources/include" \
    -import-objc-header "$repo_dir/Tests/PacketSafety/OfflinePcap.h" \
    "$repo_dir/Shared/Sources/Models/DeviceIdentification.swift" "$repo_dir/Shared/Sources/Models/Device.swift" \
    "$repo_dir/Shared/Sources/Models/Network.swift" \
    "$test_dir/scanner-tests.swift" "$test_dir/offline-pcap.o" \
    "$test_dir/wm-arp.o" "$test_dir/wm-pcap.o" -o "$test_dir/scanner-tests"
"$test_dir/scanner-tests"
