#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root / 'App/Features/Arsenal/ArsenalStore.swift').read_text()
start = source.index('    func compatibleTargets(')
end = source.index('    // MARK: - dispatch', start)
(work / 'TargetSelection.swift').write_text(
    'struct ArsenalStore { var selectedAttack: Attack?\n' + source[start:end] + '\n}')
PY
swiftc "$ROOT/Shared/Sources/Models/DeviceIdentification.swift" "$ROOT/Shared/Sources/Models/Device.swift" "$ROOT/App/Kali/Attack.swift" \
    "$ROOT/App/Kali/AttackCatalog.swift" "$ROOT/App/Kali/MediaAudioCommand.swift" \
    "$WORK/TargetSelection.swift" "$ROOT/Tests/MediaCommand/CommandTests.swift" -o "$WORK/tests"
"$WORK/tests"
