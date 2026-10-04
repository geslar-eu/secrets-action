# Geslar secrets action

A GitHub Action that loads secrets from [Geslar](https://geslar.app) into a workflow job, **masked**, using a Geslar **service account** token.

> **Status: not released yet.** There is no `v1` tag and no `v1.0.0` release; pin to a full commit SHA until there is (see [Pin it](#pin-it)). The `@geslar/cli` version this action installs is yours to choose with the `version` input and has to be a release that supports service tokens.

## What it does

1. Installs `@geslar/cli` at the **exact version you name** (`npm install --ignore-scripts` into a private directory, then checks that `geslar --version` reports that version).
2. Reads the token from the environment (`GESLAR_SERVICE_TOKEN`, **never** an input), checks its shape and **masks it** (whole, and its two halves) before anything else.
3. Validates your list of references, resolves each with `geslar read`, **masks each value the moment it is resolved** (one `::add-mask::` per line, `%` / CR / LF escaped), and only after **every** reference resolved writes the values to `GITHUB_ENV` with a fresh random delimiter. One failure means **nothing** is exported.

The token and the values are never printed, never put in an input or an output, and never exported to a child process by the script.

## Use

```yaml
permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production        # protect it: required reviewers, branch rules (recommended)
    steps:
      - uses: geslar-eu/secrets-action@<full-40-character-commit-sha>   # pin by SHA
        with:
          version: 1.2.3            # exact @geslar/cli version — required, no default
          secrets: |
            DB_PASSWORD=geslar://Production/database/password
            API_TOKEN=geslar://Production/payments/token
            # lines starting with # and blank lines are ignored
        env:
          GESLAR_SERVICE_TOKEN: ${{ secrets.GESLAR_SERVICE_TOKEN }}   # the token goes here, as a secret

      - run: ./deploy.sh            # DB_PASSWORD and API_TOKEN are in the environment from here on
```

Each line of `secrets` is `NAME=geslar://vault/item[/field]`. Vaults and items are given **by name** (the machine identity sees only the Vaults you gave it); the field defaults to `password`. A `NAME` is a plain variable name; names that would change how later steps run are refused (`PATH`, `NODE_OPTIONS`, `LD_*`, `BASH_ENV`, `GITHUB_*`, `RUNNER_*`, `GESLAR_*` and the like). At most 100 secrets per step; each name once.

### Inputs

| Input | Required | Meaning |
|---|---|---|
| `version` | yes | Exact `@geslar/cli` version: `x.y.z`, or one exact pre-release such as `1.0.0-rc.1`. No default, no range, no tag (`latest` and `next` are refused). |
| `secrets` | yes | The list above. |

The token is deliberately **not** an input: inputs appear in the invocation log. Pass it as the `env:` of the step, from a repository or environment **secret** (never from `vars`).

## Pin it

Pin this action by **full commit SHA**, and pin the CLI with `version`. Both are code that runs next to your token; neither should change unless you change the line. This repository pins every action it uses by SHA and verifies the one binary it downloads for linting by checksum.

## What this protects against — and what it does not

**It does:**

- Print the token or a value in the log: they are masked before they could appear (and the script never prints them at all).
- Run for a **fork pull request**: GitHub does not give secrets to those runs, and the action refuses a pull request it cannot show to come from the same repository. It also **refuses `pull_request_target`**, which runs with secrets while the pull request is not trusted code. Do not check out and run a pull request's code in a workflow that holds this token.
- Half-load: if any reference fails, nothing is exported.
- Let a secret name rewrite the environment of later steps (`PATH`, `NODE_OPTIONS`, ...): such names are refused.

**It does not:**

- Protect a value from the **steps that run after it in the same job**. Anything written to `GITHUB_ENV` is visible to every later step, including third-party actions. If one step needs a secret, prefer `geslar run -- your-command` in that step (the value then exists only in that process) over loading it for the whole job.
- Mask a value that has been **transformed** (base64, URL-encoded, split, reversed). GitHub masks the exact strings it was told about.
- Stop someone who can edit the workflow or its dependencies from printing the secrets in a way you did not mask. Keep the workflow behind branch protection and review.
- Make a leaked service token harmless. Whoever holds it reads everything it may read until it is revoked.

### The service account

Give the token the least it needs:

- a **separate service account**, read-only by design (a service identity cannot write);
- **one Vault per repository** (or per environment), holding only what that pipeline needs;
- a **short expiry** and a rotation habit (issue a new one, update the secret, revoke the old one);
- keep it in a GitHub **environment** secret with required reviewers where you can; never put it in `vars`;
- every read is recorded on the Geslar side; look at it.

Workflows triggered by a fork get no secrets, so the action stops there with a clear message rather than running without them.

### Runners

Tested in this repository's CI on `ubuntu-24.04` and `macos-14` (the scripts are plain bash and avoid features missing from the bash 3.2 that macOS ships). Windows runners are not tested.

## Failure behaviour

| Situation | Result |
|---|---|
| `GESLAR_SERVICE_TOKEN` missing or malformed | Step fails; the message never contains the token |
| Reference cannot be resolved | Step fails; names the variable; **nothing** exported; the CLI's own message is shown, prefixed, so it can never be read as a workflow command |
| A reference resolves to an empty value | Step fails |
| Bad `version`, bad list, reserved or duplicate name | Step fails **before** the CLI is called |
| Fork pull request, `pull_request_target`, unreadable event payload | Step fails (fail-closed) |

## Development

```sh
bash tests/run.sh      # tests with a fake CLI: masking order, multi-line values, delimiter, token never logged, bad references, name/ref validation, install flags
```

CI runs actionlint (pinned, checksum-verified), shellcheck and the tests on Linux and macOS.

## Security

Please read [SECURITY.md](./SECURITY.md) and report privately.

## License

See [LICENSE.md](./LICENSE.md).
