# Contributing to Wifi Mancer

Start with a reproducible observation, a small change and an offline check. Wifi Mancer is experimental: current targeting covers IPv4 on compatible local networks, and an armed engine does not prove another device has lost internet access. IPv6, client isolation and limited capture visibility can change the result.

## Permission and scope

Source contributions are accepted under the project's [MIT license](LICENSE). Submit only work you have the right to contribute, and identify third-party sources and their licenses. Copyright remains with its owners; this guide does not require a contributor agreement or ownership transfer. The MIT license does not grant rights to third-party trademarks or assets.

Use only networks and devices you own or are explicitly authorized to administer. Ordinary development uses recorded or synthetic fixtures. Do not run catalog commands, blocking tests or media playback against someone else's devices to reproduce a report.

## Good first contributions

- An offline fixture for a wrong device name, classification or icon.
- A regression for session transitions, cleanup reporting or stale observations.
- A normal-window layout fix that preserves readable labels and controls.
- Clear diagnostics that distinguish unavailable observations from zero traffic.
- Documentation corrections and redacted compatibility reports.

Read the roadmap in the README before proposing a new engine or dependency. Router credentials, endpoint enrollment, extra hardware and automatic exploit or wireless-disruption fallbacks are outside the selected direction. Manufacturer/OUI or private-MAC evidence alone must not identify a device as a phone or an exact model.

## Build locally

The project declares macOS 14.0 or later. The build script currently selects Apple Silicon (`arm64`); this is a declared build target, not a verified matrix of all macOS versions or Macs. Development needs Xcode and its command-line tools, XcodeGen and Python 3 for the relevant test runners. `Scripts/bootstrap.sh` installs development packages through Homebrew; Homebrew is not an intended requirement for recipients of a built app.

From the repository root:

```bash
./Scripts/bootstrap.sh
./Scripts/build.sh
```

The app is generated at `build/Build/Products/Release/Wifi Mancer.app`. Building creates an ad-hoc signed personal build. It does not install or authorize the root helper. Installing an updated app changes the exact client signature accepted by the helper; follow the README's installation steps only when deliberately testing an installation. Do not weaken signature checks to make a development build connect.

## Verify the relevant behavior

These existing runners use offline fixtures; run the ones affected by your change:

```bash
bash Tests/Identification/run.sh
bash Tests/IdentityCache/run.sh
bash Tests/Session/run.sh
bash Tests/PacketSafety/run.sh
bash Tests/AppState/run.sh
```

Additional scoped runners are under `Tests/Bonjour`, `Tests/ReverseName`, `Tests/UPnP`, `Tests/Context`, `Tests/Authentication`, `Tests/Media` and `Tests/MediaCommand`. Inspect a runner before executing it. The media fixtures do not justify playing content on a real device. Offline success does not establish live network compatibility.

There is no promised CI coverage or release certification in this guide. State the commands, results, OS and architecture actually checked. A live test needs separate explicit approval, a bounded scope and a restoration plan; never infer authorization from an issue or an old test.

## Prepare a focused pull request

1. Explain the concrete before/after behavior and link the issue.
2. Preserve existing edits and unrelated code. Add a regression when correcting consequential behavior.
3. Include actual verification results and any remaining uncertainty.
4. Run `git diff --check` and review the staged diff for private data.

Remove credentials, tokens, SSIDs, real IP/MAC addresses, serial numbers, device UUIDs, personal hostnames, usernames, home paths and unrelated screenshot content. Replace them consistently with synthetic identifiers so the reproduction still makes sense. Do not upload packet captures or unredacted diagnostic archives to public issues. Use the [security policy](SECURITY.md) for vulnerabilities.

Maintainers review source changes and dependency licenses before acceptance. Follow the [code of conduct](CODE_OF_CONDUCT.md).
