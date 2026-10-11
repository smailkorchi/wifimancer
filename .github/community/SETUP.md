# Community publication setup

Launch completed on 2026-10-11; see [publication status](../../docs/COMMUNITY_STATUS.md) for actual links and verification. This checklist remains for maintainers preparing future launches. Pinning the Welcome discussion is optional and was not performed by the API publication.

1. Confirm the approved MIT license and contribution policy are present in the public package. Review third-party code/assets and retain their required notices.
2. Complete the public-content and history audit before changing visibility or pushing. Remove private identifiers from screenshots, test fixtures, logs and generated artifacts as well as Markdown.
3. Enable Issues and Discussions in repository settings. Keep GitHub Actions workflows absent until an actual runner/build matrix is established.
4. Use GitHub's default categories below. Publish the Welcome starter in Announcements; no separate Welcome category is needed. Confirm GitHub's actual category slugs match the form filenames before publishing forms to the default branch.
5. Enable private vulnerability reporting, then check the Report a vulnerability action using an ordinary signed-in account. SECURITY.md deliberately does not claim that it is enabled.
6. Publish the starter drafts below. Pin the Welcome post in Announcements. Review body text for stale links or claims before posting.
7. Review the [initial issue drafts](ISSUES.md) against the current source, then seed only actionable issues with source references and acceptance criteria. Use the command catalog as an inventory; do not create a misleading issue claiming each unverified command is broken.

| Category | Format | Intended use | Form |
| --- | --- | --- | --- |
| Announcements | Announcement | Welcome post, maintainer updates and project boundaries | No form; maintainer posts |
| Ideas | Open-ended discussion | Proposals before implementation | `ideas.yml` |
| Q&A | Question and answer | Usage/design questions with accepted answers | `q-a.yml` |
| Show and tell | Open-ended discussion | Redacted fixtures, UI work and measured results | `show-and-tell.yml` |

Optional labels to create before applying: `bug`, `device-identification`, `documentation`, `offline-tests`, `session-lifecycle`, `needs-evidence`, `good first issue`, `help wanted`. Forms do not assume these labels already exist. Apply `good first issue` only to a scoped task with clear acceptance criteria.

## Starter discussions

| Draft | Category | Proposed title |
| --- | --- | --- |
| [WELCOME.md](WELCOME.md) | Announcements | Welcome: what Wifi Mancer can prove today |
| [ROADMAP.md](ROADMAP.md) | Ideas | Reliability roadmap: lifecycle, observations and honest status |
| [COMPATIBILITY.md](COMPATIBILITY.md) | Q&A | Share a redacted device or compatibility observation |
| [FIRST_CONTRIBUTIONS.md](FIRST_CONTRIBUTIONS.md) | Show and tell | Start with an offline fixture or a readable UI improvement |

GitHub references: [discussion category forms](https://docs.github.com/en/discussions/managing-discussions-for-your-community/syntax-for-discussion-category-forms), [issue forms](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms), [private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).
