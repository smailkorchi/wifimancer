#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wifimancer-appstate-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Use the exact store event/transition methods and full coordinator. Replace only
# profile I/O, enrichment, notifications and helper RPCs with offline fixtures.
python3 - "$repo_dir" "$test_dir/appstate-tests.swift" <<'PY'
from pathlib import Path
import sys
repo, destination = Path(sys.argv[1]), Path(sys.argv[2])
source = (repo / 'App/State/AppStore.swift').read_text()
properties = source[source.index('    @Published var context:'):source.index('    // MARK: derived')]
derived = source[source.index('    var startingBlocking:'):source.index('    var allowlistedDevices:')]
methods = source[source.index('    func handle(event:'):source.index('    private func mergeDevices(')]
store = '@MainActor final class AppStore: ObservableObject {\n' + properties + derived + methods + '''
    private func mergeDevices(_ incoming: [Device]) { devices = incoming }
    private func adoptProfile(ssid: String) { profile.ssid = ssid }
    func applyDeviceBandwidth(_ readings: [String: Double]) {}
    func toast(_ message: String) { toastMessage = message }
}
'''
fixtures = (repo / 'Tests/AppState/Fixtures.swift').read_text()
coordinator = (repo / 'App/State/AppCoordinator.swift').read_text()
tests = (repo / 'Tests/AppState/AppStateTests.swift').read_text()
destination.write_text(fixtures + '\n' + store + '\n' + coordinator + '\n' + tests)
PY

models=(DeviceIdentification Device Network Profile SpeedSample EngagementScope CutTargetReconciler CutSession)
model_files=()
for model in "${models[@]}"; do model_files+=("$repo_dir/Shared/Sources/Models/$model.swift"); done
xcrun swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library \
    "${model_files[@]}" "$repo_dir/App/State/DeviceIdentityCache.swift" "$test_dir/appstate-tests.swift" -o "$test_dir/appstate-tests"
"$test_dir/appstate-tests"
