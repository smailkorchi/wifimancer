# Community publication status

Published 2026-10-11. Original source is MIT; third-party vendor data retains the terms in THIRD_PARTY_NOTICES.md. The approved banner is in docs/assets/banner.png.

## Community spaces

- [Welcome: what Wifi Mancer can prove today](https://github.com/smailkorchi/wifimancer/discussions/1)
- [Reliability roadmap: lifecycle, observations and honest status](https://github.com/smailkorchi/wifimancer/discussions/2)
- [Share a redacted device or compatibility observation](https://github.com/smailkorchi/wifimancer/discussions/3)
- [Start with an offline fixture or a readable UI improvement](https://github.com/smailkorchi/wifimancer/discussions/4)

## Initial backlog

- [Report cleanup completion separately from stopping a session](https://github.com/smailkorchi/wifimancer/issues/5)
- [Apply identification evidence expiry consistently](https://github.com/smailkorchi/wifimancer/issues/6)
- [Correct observed traffic semantics and surface capture health](https://github.com/smailkorchi/wifimancer/issues/7)
- [Separate remembered devices from fresh ownership and inferred presence](https://github.com/smailkorchi/wifimancer/issues/8)
- [Finish app/helper pairing and safe upgrade packaging](https://github.com/smailkorchi/wifimancer/issues/9)
- [Track all 99 command recipes against the readiness inventory](https://github.com/smailkorchi/wifimancer/issues/10)
- [Make unfinished scheduling and automatic hog blocking explicit in the UI](https://github.com/smailkorchi/wifimancer/issues/11)

All 99 command recipes and their remaining work are recorded in [COMMAND_STATUS.md](COMMAND_STATUS.md). Seven issues organize priority work; they do not certify that the rest is complete. The command readiness classifications are audit labels and are not yet runtime execution guards.

## Verified for this source baseline

- Release arm64 build from the sanitized snapshot succeeded with Xcode selected for that command; deep/strict signature verification passed.
- Context, Identification and MediaCommand offline runners passed after private fixture identifiers were replaced with synthetic values.
- Catalog IDs, totals, source fingerprint, YAML parsing and local Markdown links passed their checks.
- GitHub reports Issues, Discussions and private vulnerability reporting enabled.
- The public main branch starts from sanitized source. Earlier history and live screenshots are excluded from that branch. Preserved private forks and GitHub cached views are not erased by history replacement.

No installation, app launch, live network disruption, radio operation or playback was performed for publication. Build warnings about concurrency/deprecated APIs remain. No certified/notarized binary release or completed security audit is claimed.

Old clones must not merge their previous history into main. Start from a fresh public clone, or port a small reviewed patch onto the new baseline. See GitHub's [history rewrite guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
