#!/usr/bin/env bash
# Installs @geslar/cli at an EXACT version, without running any install script, into a private prefix, and checks that
# the binary reports that very version. No range, no tag, no default: the caller names the version.
set +x
set -euo pipefail

fail() {
  printf '::error::%s\n' "$1"
  exit 1
}

version=${GESLAR_CLI_VERSION-}
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "The 'version' input must be an exact version like 1.2.3 (no ranges, no tags such as latest)."
fi
runner_temp=${RUNNER_TEMP-}
if [ -z "$runner_temp" ]; then
  fail "RUNNER_TEMP is not set; this script only runs inside a workflow step."
fi

prefix="$runner_temp/geslar-cli"
mkdir -p "$prefix"
# --ignore-scripts twice over (flag and environment): nothing of the package or its dependencies runs at install time.
npm_config_ignore_scripts=true npm install --prefix "$prefix" --ignore-scripts --no-audit --no-fund --no-save "@geslar/cli@${version}"

bin="$prefix/node_modules/.bin"
reported=$("$bin/geslar" --version)
if [ "$reported" != "$version" ]; then
  fail "The installed CLI reports a different version than requested."
fi

if [ -n "${GITHUB_PATH-}" ]; then
  printf '%s\n' "$bin" >>"$GITHUB_PATH"
fi
printf 'Installed @geslar/cli %s\n' "$version"
