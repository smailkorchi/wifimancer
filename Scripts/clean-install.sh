#!/usr/bin/env bash
# Retired: the old implementation deleted matching apps across the disk and
# reset unrelated macOS caches. Keep this entry point fail-closed.
set -euo pipefail
printf '%s\n' \
  'The legacy broad cleanup installer is disabled.' \
  'Build as your normal user with ./Scripts/build.sh.' \
  'Review README.md for app placement and the separate helper installation.' >&2
exit 1
