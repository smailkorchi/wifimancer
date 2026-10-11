# Community roadmap

This is an experimental source project. A command template, an active packet engine and verified Internet loss are different facts. Current targeting covers IPv4 on compatible local networks. No universal device/router claim is accepted without evidence.

The shipping direction stays native SwiftUI + Swift/C helper + authenticated XPC. Ordinary use must not require router credentials/API access, endpoint enrollment or additional hardware. Bettercap and other projects are research references, not bundled dependencies or proof of compatibility.

## Ordered work

| Priority | Workstream | Completion evidence |
| --- | --- | --- |
| P0 | Preserve the baseline and reproduce stop/cleanup failures offline. | Injected restore failure demonstrates the defect; existing protections remain covered. |
| P1 | Make session and cleanup status accurate across every screen. | Stop waits for cleanup outcome; failures remain visible; late results cannot alter a newer session. |
| P2 | Separate remembered identity from fresh address ownership and inferred presence. | Clock-driven stale/reassigned-address tests; bounded discovery; newcomers reconciled without restarting. Silence alone never proves departure. |
| P3 | Version helper events, reconnect snapshots and a bounded local journal. | Ordered replay, explicit gaps, disconnected subscriber removal; history never rearms a session. |
| P4 | Correct traffic semantics and capture ownership. | Fixture counters have documented meaning; open/read failures surface; repeated capture start/stop has bounded resources. |
| P5 | Improve identity, icons and the operations UI. | Evidence source/age/confidence displayed; unknown remains unknown; consistent state vocabulary and normal-window layouts. |
| P6 | Evaluate broader protocol coverage independently. | Read-only inventory and offline correctness first; an explicitly authorized owned-network test before activation. Unsupported paths remain visible. |
| P7 | Harden installation and release packaging. | Reviewed app/helper pair, exact signature pin, clean-machine checks and rollback procedure. No helper-authentication shortcut. |

The detailed [evolution plan](docs/EVOLUTION_PLAN.md) records source findings, decisions, acceptance gates and primary research references. Those are implementation targets, not claims of completed work.

## Arsenal backlog

All 99 recipes are listed in [COMMAND_STATUS.md](docs/COMMAND_STATUS.md), with a [machine-readable inventory](docs/command-status.json). The inventory separates template-only actions, concrete defects, dependency/platform gaps and missing verification. Optional remote tools are not part of native engine compatibility.

Priorities are accurate names and previews, explicit dependencies, bounded execution/cancellation, precise authorized target scope, reliable output/error handling and offline regressions. Do not expand disruptive reach or substitute automated fallback attacks for an unsupported network path.

## Useful first contributions

- Add a small sanitized identification fixture with evidence that distinguishes a TV, computer, printer or unknown adapter.
- Reproduce a normal-window clipping problem and repair the affected layout.
- Add a deterministic test for a lifecycle, freshness or parsing defect before changing its implementation.
- Correct a command description or dependency declaration without running it against live devices.
- Improve build documentation using a fresh checkout and report the exact host/toolchain tested.

No schedule, browser screenshot or old test result certifies a release. Contributions should state what was observed, what was tested offline and what still needs live acceptance. Follow [CONTRIBUTING.md](CONTRIBUTING.md).
