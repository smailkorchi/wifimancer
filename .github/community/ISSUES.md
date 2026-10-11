# Initial issue drafts

Review these against the exact published revision before creating GitHub issues. They describe source-inspected gaps, not completed fixes or authorization for live tests.

## Report cleanup completion separately from stopping a session

Suggested labels: `bug`, `session-lifecycle`, `offline-tests`.

The current stop path can emit Idle before restoration finishes. A restoration failure tagged with the old session generation can then be discarded. Users need the cleanup outcome even when packet actors have already stopped.

Affected source: `Helper/Sources/Service/HelperService.swift`, `Helper/Sources/Spoof/ARPSpoofer.swift`, session/app state models and status presentation.

Acceptance:

- An offline injected restoration failure reaches the RPC caller and displayed state.
- Holding cleanup does not falsely report successful completion.
- Late cleanup cannot stop, relabel or restore stale bindings into a newer session.
- Cancellation, own-Mac/router/trusted exclusions and one-time handle closure remain intact.
- Relevant Session, PacketSafety and AppState regressions pass; no live disruption is required for this ticket.

## Apply identification evidence expiry consistently

Suggested labels: `device-identification`, `offline-tests`.

Identification already uses several evidence sources, but expiry is not consistently applied to every source. Old model/name evidence can outlive its authority and produce an incorrect label or icon.

Affected source: `App/State/DeviceIdentityCache.swift`, `Shared/Sources/Models/DeviceIdentification.swift`, identification presentation.

Acceptance:

- Clock-controlled fixtures expire evidence from each supported source.
- Expired strong evidence does not permanently override fresh weak evidence; remaining uncertainty is visible.
- Address reassignment does not inherit another device's name, model or trust.
- Manufacturer-only evidence and private MACs do not become guessed phone or exact-model classifications.
- Relevant Identification and IdentityCache regressions pass without contacting devices.

## Correct observed traffic semantics and surface capture health

Suggested labels: `bug`, `offline-tests`.

Capture counters currently account for frame bytes against both endpoint MACs, while the app interprets selected counters as upload/download. This does not establish WAN direction or reclaimed bandwidth. Capture failure must also differ from zero traffic.

Affected source: `Helper/CSources/wm_pcap.c`, `Helper/Sources/Service/HelperService.swift`, `Shared/Sources/Models/SpeedSample.swift`, `App/State/AppCoordinator.swift`, throughput presentation.

Acceptance:

- Independent Ethernet fixtures establish observed source/destination direction and capture totals without double counting.
- Control traffic, truncation, overflow and capture-epoch changes have explicit behavior.
- Missing capture visibility or a read failure displays unavailable/degraded state rather than zero usage.
- WAN direction and application/process attribution are shown only when supported by the actual observation path.
- Tests remain offline. Capture ownership/leak remediation needs its own measured lifecycle proof before releasing contexts still used by a pump.
