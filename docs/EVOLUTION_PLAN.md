# Wifi Mancer evolution plan

Decision date: 2026-10-10. Status: decisions selected; implementation deferred until the restored session continues.

## Product contract

Wifi Mancer remains a standalone native Mac app. The ordinary workflow must not require router credentials/API access, endpoint enrollment, extra hardware, Homebrew, or a second network. Existing macOS administrator and local-network consent remain legitimate platform requirements.

The goal is substantially better compatibility, accurate device information, automatic handling of newly observed devices, and trustworthy operations reporting. Compatibility is measured per network and protocol family. No universal-blocking claim is accepted without evidence; an unavailable observation or control path must be visible.

Work and any later tests stay within networks the user owns or administers. Do not play media, change TV volume, power-cycle devices, change router settings, or run another live blocking test as part of restoring this session. Live disruptive tests and installed updates need the applicable explicit confirmation. Earlier time-bounded test approval is not standing authorization for new tests.

## Decisions to follow

| ID | Decision | Reason |
| --- | --- | --- |
| D1 | Keep SwiftUI + the native Swift/C XPC helper as the shipping architecture. | Preserve the existing privileged boundary, authentication, target exclusions and lifecycle safeguards. Repair demonstrated defects before replacing the engine. |
| D2 | Use Bettercap as a pinned comparison/reference, not a release dependency now. | It offers relevant implementations, but macOS package availability does not establish feature reliability, clean packaging or license compatibility. |
| D3 | Keep router integration outside this evolution. | The user explicitly rejected additional router access and setup. |
| D4 | Separate identity, presence, requested policy, engine state, protocol coverage and observed outcome. | A configured engine, a quiet client and an internet outage are different facts. |
| D5 | Use one bounded discovery pipeline, native DNS-SD for service/address inventory, and OS path signals for lifecycle. | Avoid duplicate scanners and new runtime packages. DNS-SD supports address inventory without opening application connections. |
| D6 | Store bounded helper events with system SQLite3; use authenticated XPC for snapshots and history. | Durable history and reconnect recovery need explicit ordering. No ORM, server, cloud service or exposed HTTP command endpoint is required. |
| D7 | Keep old broad DHCP, IP-alias, DNS-interception and dormant packet layers disabled. | They are not a shortcut to selective, reversible, well-scoped control. No automatic escalation to wireless disassociation or exploit-based fallbacks. |
| D8 | Broader protocol coverage must pass an independent feasibility and safety gate. | IPv6 is a real gap, but the dormant implementation is not ready to enable. Prefer an explicit unsupported result over collateral disruption. |
| D9 | Consolidate installation at reviewed release milestones. | Preserve exact client-signature authentication for personal builds; do not weaken it to avoid administrator approval. No paid Apple Developer account is assumed. |

## Ground truth from this planning session

Source inspected at Git HEAD `2d23936a524afd3f75be06d799fa0ae45cf09752`, with extensive pre-existing uncommitted changes. HEAD alone does not describe the current app. Host: arm64, macOS 27.0.1, build 26A434. Project declares macOS 14.0 minimum and arm64 builds; this is not a tested compatibility matrix.

| Finding | Source | Implication |
| --- | --- | --- |
| Active sessions use ARPSpoofer + ARPResponder only. | `Helper/Sources/Service/HelperService.swift`, `SessionCutEngines` | Current coverage is IPv4 targeting, not complete internet enforcement. |
| Stop invalidates the active generation and emits Idle before cleanup finishes; old-generation restoration errors can be discarded. | `HelperService.swift`, `stop`, `applied`, `startFailed`; `ARPSpoofer.swift`, `close` | Stop completion and cleanup outcome need an independent lifecycle. |
| Inventory keeps missed devices indefinitely; current binding eligibility has no freshness lease. | `Shared/Sources/Models/CutSession.swift`, `acceptScan`, `targets` | Remembered identity must be separated from presence and current address ownership. |
| Discovery currently scans for two seconds, then waits five seconds. | `App/State/AppCoordinator.swift`, `startContinuousScan` | This is polling; there is no authoritative AP join/leave feed. |
| Events are unversioned Codable payloads; there is no event cursor, reconnect snapshot or durable journal. Receiver proxies accumulate. | `Shared/Sources/Protocols/HelperProtocol.swift`; `Helper/Sources/Service/EventBus.swift`; `App/State/HelperClient.swift` | Reconnect can lose history and stale subscribers need removal. |
| C counts frame length against both endpoint MACs; the app interprets self-MAC bytes as download and other MAC bytes as upload. | `Helper/CSources/wm_pcap.c`, `traffic_handler`; `AppCoordinator.swift`, `startThroughputPoll` | Current figures cannot substantiate WAN upload/download or reclaimed bandwidth. |
| Capture close intentionally leaks context/mutex; repeated opens allocate again. Capture read failures are not surfaced adequately. | `wm_pcap.c`, `wm_traffic_close`; `HelperService.swift`, throughput methods | Establish ownership and cancellation before freeing; expose capture health. |
| NDP code exists but lacks current active-engine failure/generation/restoration protections and ignores send results. IPv6 ownership/scope evidence is incomplete. | `Helper/Sources/Spoof/NDPSpoofer.swift`; `CutTargetReconciler.swift` | Do not enable it by flipping a flag. |
| Device evidence expiry is not applied consistently to every identification source. | `App/State/DeviceIdentityCache.swift` | Old model/name evidence can outlive its authority. |
| Devices still uses a Cut label/count that does not establish blocking. | `App/Features/Devices/DevicesView.swift`; `AppStore.swift`, `blockedDevices` | Status semantics must agree across every screen. |

Preserve existing protections: own Mac/router/trusted exclusions, ambiguous-owner rejection, network/session generations, stale-network callback rejection, fresh owner replacement, and no automatic rearm after reconnect. Earlier memory findings about metadata stopping actors and cross-network restoration have source fixes; do not reintroduce or report them as unfixed without a new reproduction.

## Ordered delivery phases

Each phase is a small reviewable change. Complete its acceptance checks before the next phase. No estimates below constitute evidence that a feature works.

### P0 — Preserve baseline and reproduce the first defect

- Read any available private session handoff; compare source hashes and worktree status. Private operational handoffs are excluded from the public repository. Preserve existing edits and installed rollback material.
- Review and run the relevant offline baseline runners, not a live network test.
- First implementation ticket: reproduce the stop-time restoration failure with injected packet failure. Keep the reproduction offline.
- Record current vs previous evidence separately. Do not claim old test passes certify modified code.

Exit: baseline captured; a failing regression demonstrates the cleanup-result defect; scope remains unchanged.

### P1 — Correct session lifecycle and status truth

Primary files: `HelperService.swift`, `ARPSpoofer.swift`, `ARPResponder.swift`, `SpeedSample.swift`, `HelperClient.swift`, `AppCoordinator.swift`, `AppStore.swift`, and affected status labels.

- Stop packet emission promptly, then report restoration completed, failed, or skipped because the network changed. Track cleanup separately from an active generation.
- A delayed cleanup result must not stop, re-label or restore stale bindings into a newer session.
- Keep failed cleanup visible after actors stop. Do not leave an ambiguous state looking successfully restored.
- Unify displayed states: Idle, Starting, Armed/Targeted, Stopping, and Stopped with a cleanup issue. Outcome remains unverified unless independent evidence exists.
- Remove the implication that an empty scan proves AP isolation. Show insufficient observations or a supported diagnostic reason.

Acceptance: held cleanup does not produce a false completed state; injected restore failure reaches both RPC/UI; duplicate/late callbacks are harmless; stop during start is handled; handles close once; Mac/router/trusted exclusions remain intact.

Existing runners: `Tests/Session/run.sh`, `Tests/PacketSafety/run.sh`, `Tests/AppState/run.sh`.

### P2 — Build fresh observations, presence and bounded discovery

Primary files: `Device.swift`, `CutSession.swift`, `AppCoordinator.swift`, `MDNSAppEnricher.swift`, `ReverseNameDiscovery.swift`, `UPnPDiscovery.swift`, `DeviceIdentityCache.swift`; add only small observation/presence types as needed.

- Retain remembered devices and policy separately from current IP/MAC bindings. Use an injected clock in tests.
- Initial binding-authority lifetime: 30 seconds, with refresh from qualifying current-network ownership observations. Reevaluate this value against measured scan latency before release.
- Expiry removes permission to act on an unverified binding, not remembered policy or the device row. Show degraded coverage while waiting for valid ownership evidence. This favors avoiding the wrong target over silently acting on stale addresses.
- Positive observations update presence immediately. Use Observed, Quiet/last seen, and Offline inferred; silence, failed ping or service expiry alone is not proof of departure. Debounce inferred departure over multiple successful scan rounds.
- Have one owner for scan scheduling, deduplicate concurrent requests, preserve bounded retries and use current-network generation/interface on every callback. Publish new observations as they arrive; retain bounded periodic reconciliation for silent newcomers.
- Migrate deprecated NetService discovery incrementally behind existing fixtures to DNSServiceBrowse/QueryRecord/GetAddrInfo. Disable cross-interface peer-to-peer browsing. Keep ordinary Bonjour consent in the GUI; do not move it to root to bypass privacy permission.
- Observe IPv6 addresses/routes read-only in this phase, with interface zone, expiry and ownership confidence. Never attach an address to a device merely because its name matches.

Acceptance: one missed round does not erase a peer; a stale address is never targeted/restored; reassignment and simultaneous conflicts stay protected; newly observed eligible peers are reconciled without restarting the session; late old-network callbacks do nothing; denied permission differs from an empty network; no discovery action changes radio mode or the Mac's connection.

Targets to measure, not promises: UI updates within 500 ms of helper observation under normal load; a responsive newcomer on a compatible flat LAN appears within two completed discovery rounds. Record actual end-to-end latency and false departure rate.

Existing runners: Session, Context, Bonjour, ReverseName, UPnP, Identification and IdentityCache `run.sh` files under `Tests/`. Add clock-driven presence fixtures; preserve current bounded XML/network validation.

### P3 — Reliable events, snapshots and durable history

Primary files: `HelperProtocol.swift`, `SpeedSample.swift`, `EventBus.swift`, `HelperClient.swift`, `AppStore.swift`, `Notifier.swift`; new narrowly scoped journal/envelope code.

- Negotiate protocol/schema compatibility separately from the helper's human version string. Reject incompatible control operations visibly; do not silently discard unknown state.
- Add helper-instance ID, network/session ID, sequence, event type and timestamps. Use monotonic elapsed time within a process; wall clock is for display.
- Subscription returns a snapshot and sequence boundary atomically, followed by later events. Remove receivers on disconnect/failure; bound buffers and indicate gaps.
- Use system SQLite3, one serialized helper writer, transactions, schema versioning, and bounded retention. Initial cap: 14 days or 100 MiB; coalesce counters instead of recording every packet.
- Root journal location: `/Library/Application Support/WifiMancer/events.sqlite`, private directory/files; read only through authenticated XPC. Do not derive a root path from the GUI's home directory.
- First journal stores helper observations, policy/session transitions, engine/capture health and cleanup outcomes. Keep Bonjour identity enrichment in the GUI. Replay must not misrepresent a currently known name as an observed historical name.
- History/replay is read-only and cannot emit packets, execute commands, change trust, replay control actions or rearm. Missing history is an explicit gap.
- Keep current reconnect/restart behavior that ends an existing enforcement session before ready. Snapshots are recovery of facts, not authorization to resume targeting.

Acceptance: snapshot plus events has no subscription race; duplicates/reordering cannot corrupt state; helper restart changes instance ID; disconnected subscribers are released; interrupted DB writes recover; retention is bounded; history survives restart without reviving stale presence; replay never calls control RPCs.

Add journal/replay offline tests. Extend Session RPC and AppState fixtures. Export diagnostics through SQLite's backup mechanism or a logical export, not by copying an active WAL database file alone.

### P4 — Correct traffic accounting and capture ownership

Primary files: `wm_pcap.c`, its header, `HelperService.swift`, `SpeedSample.swift`, `AppCoordinator.swift`, `AppStore.swift`, Throughput and device rate views.

- Return explicit observed source/destination bytes, capture epoch and monotonic interval. Count a frame once in capture totals; maintain endpoint direction separately.
- Separate IPv4/IPv6 data and local control traffic. Exclude reliably identifiable WifiMancer discovery/injection overhead from claimed user bandwidth. Ethernet capture alone cannot attribute arbitrary traffic to its originating app/process; do not invent that attribution.
- Display Observed sent/received and capture visibility. Only show WAN upload/download when the actual capture position establishes that direction. Missing visibility is unavailable, not zero usage.
- Surface capture read failures, counter/table overflow and interval resets. Reset deltas on interface/capture epoch changes.
- Prove one serialized owner and completion of pumps before releasing capture contexts. Then remove the active intentional leak; never free a pointer still captured by a task.
- Remove causal claims that a speed-test increase proves bandwidth was reclaimed by blocking.

Acceptance: independent Ethernet fixtures cover direction, double counting, broadcasts/multicast, control exclusion, truncation, capacity, delayed drains and interface reset. Repeated open/pump/drain/close balances resources under address/undefined-behavior sanitizers. GUI rates remain unavailable when the observer cannot establish them.

Add `Tests/Throughput/run.sh` around the existing offline pcap harness; keep PacketSafety and AppState regressions.

### P5 — Consistent identification and operations UI

- Preserve the existing evidence hierarchy and expose source, confidence, age and conflicts. Apply source TTL and `expiresAt` consistently.
- A vendor/OUI identifies a manufacturer clue, not an exact product. A private MAC never implies phone. Generic media capability never proves TV. Do not auto-merge identities or transfer trust across MAC changes from a name/vendor match.
- Use the same device classification/icon and status model in Recon, Devices, Lobby, Arsenal target selection and menu bar. Verify every chosen SF Symbol exists on the supported OS; retain a visible generic fallback.
- Keep the requested name/model information readable at normal window sizes. Group/filter dense graphs instead of shrinking labels into an unreadable ring.
- Add an operations timeline and a compact per-device inspector showing presence, addresses, requested policy, coverage, engine health and evidence. Do not expose raw protocol mechanics as ordinary user workflow.

Acceptance: known Samsung model evidence yields a TV consistently; weak Samsung vendor-only evidence remains uncertain; expiry removes stale names/models; IP reassignment inherits no old identity; all surfaces agree; normal-window layouts fit at the current minimum and dense-device fixtures remain usable.

Existing runners: Identification, IdentityCache, ReverseName, Bonjour and UPnP. Extend layout checks and add a small cross-surface presentation fixture. No audio playback is needed.

### P6 — Evaluate wider protocol coverage without adding setup

This phase is a decision gate, not permission to enable dormant packet modules.

- Pin Bettercap v2.41.7 as the initial research comparison, verify its artifact/source hash and relevant feature behavior on actual macOS/hardware. Refresh the pin only with a written reason.
- Compare only the required functionality in an explicitly approved, isolated owned-network lab. Start with recorded data/offline fixtures. Do not run the framework automatically on the user's active LAN.
- Evaluate IPv6 address/router inventory and whether a narrowly scoped implementation can preserve exact target selection, ownership freshness, Mac/trusted exclusions, cancellation and restoration.
- Require independent target-side evidence for each IP family; sender injection counts and absence of observed traffic cannot establish remote loss of internet. If extra target-side access is unavailable in normal use, display unverified coverage honestly.
- Never turn unsupported control into broad routing changes, DHCP disruption, IP claiming, wireless disassociation or attempts to evade network protections.

Adoption gate: required features demonstrate a material compatibility/reliability improvement; all lifecycle/rollback fixtures pass; feature-specific macOS results pass; distribution/signing has no extra user dependencies; license implications are accepted. Bettercap is GPL-3.0 and the EvilLimiter fork is MIT. Wifi Mancer declared all rights reserved at the planning baseline; its original public source is now MIT, with separately licensed vendor data documented in THIRD_PARTY_NOTICES.md. Do not copy GPL code or assume a subprocess boundary settles distribution obligations.

Exit: a documented go/no-go for a bounded native extension or dependency, with measured supported cases and clear failures. If the gate fails, keep that capability unavailable and deliver the completed observation/lifecycle/UI improvements. No universal router claim is inferred from a README or a small test matrix.

### P7 — Release hardening and one verified installation

- Complete the relevant offline regressions and a Release build. Keep baseline/current evidence distinct.
- Stage app/helper/protocol/signature pin as a compatible set; validate before replacing; retain a recoverable previous pair. Preserve root ownership, symlink rejection and exact client pin checks.
- Preserve personal ad-hoc builds. Improve actionable permission/version/update status; do not promise removal of macOS approval or silently introduce a paid signing requirement.
- Perform an approved installed smoke check for Connected and Idle without a blocking/media test. Later disruptive acceptance is a separate explicit gate.
- Validate every declared OS/architecture that can actually be tested. Label untested support honestly. Capture CPU, memory and discovery latency; establish measured budgets before claiming performance.

Release gate: coherent app/helper identity and protocol; no active capture leaks; no silent decode/capture/cleanup failures; no false Cut/complete-coverage claims; Mac/trusted connectivity protected; independent review passes.

## Live acceptance matrix for a later approved lab

| Case | Required evidence |
| --- | --- |
| IPv4-only, IPv6-only, dual stack | Separate observed outcomes; no family silently omitted. |
| Newly observed peer; reconnect; DHCP/IP ownership change | Correct current binding and automatic policy reconciliation without restarting the session. |
| Private/changed MAC | New identity is visible; no guessed trust transfer. |
| Existing and fresh TCP/QUIC connections | Target-side checks distinguish persistent sessions from new requests. |
| Guest isolation, mesh/roaming, distinct VLAN/subnet | Scope limits and missing visibility are reported; no cross-scope targeting. |
| Trusted peer, Mac and gateway | Connectivity and management remain intact throughout the approved test. |
| Start/cancel/stop, capture failure, helper loss, app reconnect, network change, sleep/wake | No stale active state, accidental rearm or restoration into another network; cleanup outcome recorded. |
| Cold launch, resized window, 10/25/100 synthetic devices | Controls/icons remain visible; UI stays responsive. |

Disable cellular/secondary connectivity only on the test endpoint when verifying its Wi-Fi path. No claim about all devices is derived from one successful test. Inventory observations can be near real time; physical association/departure cannot always be known from a peer Mac.

## Research evidence and limits

Sources checked 2026-10-10. These establish available implementations and constraints, not successful execution on this Mac.

- [Bettercap installation](https://www.bettercap.org/project/installation/), [v2.41.7 release](https://github.com/bettercap/bettercap/releases/tag/v2.41.7), [license](https://github.com/bettercap/bettercap/blob/master/LICENSE.md): macOS distribution exists; dependencies and GPL obligations need explicit treatment before adoption.
- [Bettercap events](https://www.bettercap.org/modules/core/eventsstream/) and [session/events API](https://www.bettercap.org/modules/core/apirest/): useful reference for typed events, snapshots and replay. The app will keep authenticated XPC, not adopt an exposed command server.
- [Bettercap macOS issue #1121](https://github.com/bettercap/bettercap/issues/1121): a historical, feature-specific report; not proof of current OS success or universal failure.
- [Maintained EvilLimiter fork](https://github.com/DavidsonRafaelK/evillimiter), [watcher](https://github.com/DavidsonRafaelK/evillimiter/blob/master/evillimiter/networking/watch.py), [identity](https://github.com/DavidsonRafaelK/evillimiter/blob/master/evillimiter/networking/host.py): implemented reconnect and identity paths; Linux-specific runtime, so not a drop-in Mac backend.
- [EvilLimiter persistence issue #130](https://github.com/bitbrute/evillimiter/issues/130): similar symptom reported by others; proposed explanations are hypotheses, not the diagnosis of this app.
- [Apple TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api), [DNSServiceGetAddrInfo](https://developer.apple.com/documentation/dnssd/dnsservicegetaddrinfo(_:_:_:_:_:_:_:)), [NetService](https://developer.apple.com/documentation/foundation/netservice): choose DNS-SD for inventory without application connections; migrate deprecated APIs surgically.
- [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [private Wi-Fi addresses](https://support.apple.com/en-us/102509): consent and changing network identities are real constraints, not discovery bugs to conceal.
- [NetAlertX discovery plugins](https://docs.netalertx.com/PLUGINS_OVERVIEW/) and [false offline results](https://docs.netalertx.com/FIX_OFFLINE_DETECTION/): multiple observation sources help; missing responses do not establish departure.
- [SQLite transactions/application format](https://www.sqlite.org/appfileformat.html), [WAL](https://www.sqlite.org/wal.html), [online backup](https://www.sqlite.org/backup.html): system database with bounded, transactional history; safe export must account for WAL.
- [Apple NetworkExtension overview](https://developer.apple.com/videos/play/wwdc2025/234/?time=520) and [Wi-Fi tracing](https://developer.apple.com/documentation/network/recording-a-wi-fi-packet-trace): local APIs/capture do not automatically control or expose other clients' traffic.

## Implementation boundary at handoff

Only this plan and `NEXT_SESSION.md` are written by this planning turn. No app source, installer, installed helper, router, TV or network state is changed. No new builds, regression runs or live tests are claimed. Resume at P0, then the P1 offline reproduction; do not restart research or perform an installation first.
