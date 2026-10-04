# Security Policy

The Geslar secrets action handles credentials. We take reports about it seriously and we would rather hear about a problem early and informally than late and perfectly written up.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting on this repository:

**[→ Report a vulnerability](https://github.com/geslar-eu/secrets-action/security/advisories/new)**

This opens a private advisory visible only to you and to Geslar d.o.o. If you cannot use GitHub, write to `security@geslar.app`.

Please include, as far as you have it: the action reference you used (commit SHA or tag), the `@geslar/cli` version, the runner (`ubuntu-24.04`, `macos-14`, ...), and the steps to reproduce. **Redact any real secret, token, or vault content** — a redacted report is more useful to us than one we have to handle as an incident.

## What to expect

- **Acknowledgement within 3 working days.**
- An initial assessment, with our view of severity and whether we consider it in scope, **within 10 working days**.
- Progress updates at least every 14 days until the report is closed.
- Credit in the release notes and in the published advisory, under whatever name or handle you prefer, unless you ask us not to.

We ask you to give us a reasonable window to ship a fix before publishing. We will agree a disclosure date with you rather than impose one, and we will not ask you to stay quiet indefinitely.

## Supported versions

Security fixes are shipped in a new release on the current release line. Older releases are not patched in place. Always report against the latest release if you can reproduce there.

## Scope

**In scope**

- The scripts and `action.yml` in this repository: how the token and the resolved values are handled, masked, validated and exported
- Ways to make the action print the token or a value, export something that was not asked for, or accept a name, reference, version or event it should refuse
- Weaknesses in how this repository pins and verifies what it runs

**Out of scope**

- The known limitations stated in [README.md](./README.md#what-this-protects-against--and-what-it-does-not): for example that values written to `GITHUB_ENV` are visible to later steps of the same job, or that GitHub masks only the exact strings it was told about. If you have found a way around a control we *do* claim, that is very much in scope.
- Vulnerabilities in the Geslar CLI itself (report those in [geslar-eu/geslar-cli](https://github.com/geslar-eu/geslar-cli/security/advisories/new)), in GitHub Actions, or in third-party actions you combine this one with.
- Attacks that require control of the runner, of the workflow file, or of the repository's settings.
- Social engineering of Geslar staff or users, and denial of service through volume.

## Safe harbour

We will not pursue or support legal action against anyone who reports a vulnerability to us in good faith, keeps to the scope above, avoids privacy violations and service degradation, and does not access, modify, or retain data belonging to anyone else. If you are unsure whether something is in bounds, ask us first.

We do not currently run a paid bug bounty programme.
