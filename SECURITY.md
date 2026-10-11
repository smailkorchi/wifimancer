# Security policy

Wifi Mancer includes a root helper and network-facing discovery parsers. Treat authentication failures, unsafe helper operations, malformed-input handling and private-data exposure as security issues.

## Report privately

Do not post vulnerability details, exploits, credentials, packet captures or private network data in an issue or discussion.

Private vulnerability reporting is enabled for this repository (verified 2026-10-11). Use GitHub's **Report a vulnerability** action on the [security advisories page](https://github.com/smailkorchi/wifimancer/security/advisories). If the action is unavailable, open an issue titled **Private security contact requested**, with no technical details or attachments, and wait for a maintainer to provide a private route.

Include privately:

- Affected revision, macOS version and architecture.
- Impact and the smallest offline reproduction available.
- Expected and observed behavior, with secrets removed.
- Whether any installed helper or network state was changed, and any safe recovery information.

Do not test an impact on other people's devices. A report never authorizes live disruption or disclosure of someone else's information.

## Support and disclosure

This is an experimental project. There is no supported release series, security-response SLA or completed security audit claimed by this policy. Report against an exact revision; maintainers will determine affected versions and coordinate a fix and advisory where appropriate. Coordinate public disclosure after a private assessment.

The helper's exact client-signature pin, root-owned installation paths and network/target exclusions are security boundaries. Do not bypass them as a workaround. The app's experimental IPv4 targeting is not an assurance of network isolation, access control or complete internet blocking.
