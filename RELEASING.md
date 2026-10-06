# Releasing

Releases (the tags `v1.0.0` and the moving `v1`) are created **by a maintainer at Geslar, by hand**, after the checks below. The repository ruleset protects the release tags; nothing in this repository creates one.

## Mandatory checks before the first tag

Two things cannot be proven by the fake-CLI tests in `tests/run.sh` and **must** be verified on a real runner with the real CLI, at the version named in the e2e workflow's `version` input, before any tag exists. Record the result of each in the release issue/PR (run link and what you saw).

### A. The calling step's `env:` reaches the composite action's inner steps

The action reads `GESLAR_SERVICE_TOKEN` from the environment of its inner steps, and the caller sets it as `env:` on the `uses:` step. That this is inherited is an assumption until it has run for real.

1. Run the **e2e** workflow (Actions → *e2e (manual, real runners, real CLI)* → Run workflow) with `version` = the CLI version being verified and `reference` = the probe item (setup below).
2. Expected on every OS: the step *load the probe secret…* **passes**, and the step *negative control — without the token the action must fail* is shown as failed-but-allowed (`continue-on-error`) while *the negative control really failed* is **skipped**.
3. If the first step fails with `GESLAR_SERVICE_TOKEN is not set`, the assumption is wrong: stop, the token handoff has to change (for example an explicit `env:` in `action.yml` fed from an input that is a secret reference) before release.

### B. The real CLI with a service token

1. In Geslar (web): create a **test Vault** holding one **probe item** (a throw-away value, for example `probe-` plus random characters) and a **service account** ("Service (CI)") with access to only that Vault and the shortest expiry that covers the test.
2. In this repository: Settings → Secrets and variables → Actions → **New repository secret** `GESLAR_SERVICE_TOKEN` = the token shown once at creation.
3. Run the e2e workflow as in A with `reference` = `geslar://<Vault name>/<item name>/password` (or the field you used).
4. Expected on `ubuntu-24.04`, `macos-14` and `windows-2022`: install succeeds with the exact version; `geslar --version` equals it; the probe value is exported; the step *the value reached the environment and is masked* prints a length and `***` for the value.
5. Note the Windows result separately: Windows runners are not part of the regular CI and the action's support statement depends on this run.

### C. The raw log

Download the raw log of the run (Actions → the run → ⋮ → *Download log archive*) and search it for: the probe value, the token, and each half of the token (the first 43 and the next 43 characters after the `gsm_` prefix). **None** may appear. `::add-mask::` commands must not appear in the raw log either (the runner consumes them).

### D. Fork pull request and `pull_request_target`

Open a pull request from a fork that changes nothing relevant. The `ci` workflow runs without secrets; a workflow that uses the action must fail with the fork message rather than run without them. A `pull_request_target` workflow must be refused by the action.

### E. Pins

Every `uses:` in `action.yml` and `.github/workflows/*` is a full commit SHA; the linter download in `ci.yml` carries a version and a SHA-256. Check the pins are current and that `ci` is green on `main`.

## Releasing

Only when A–E are recorded: a maintainer creates the tag `v1.0.0` on the verified commit and moves `v1` to it. Documentation then tells people to pin the action by **commit SHA**; the tags are for people who accept moving references.

If A or B fails, nothing is tagged. The CLI is only ever installed by its exact version; the action refuses `latest` and `next`.
