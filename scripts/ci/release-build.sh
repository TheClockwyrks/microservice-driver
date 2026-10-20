#!/usr/bin/env bash
# Builds the driver crate, the `tcab` CLI among its binaries, and its tests in release mode, the exact profile shipped
# to users. The first step of the pipeline's binary jobs, on Linux and Windows:
# the release build is the slow part of that gate and its duration is a number
# worth having on its own. The tests (scripts/ci/release-test.sh and
# release-doctest.sh) and the smoke check (scripts/ci/binary-smoke.sh) follow.
#
# `--all-targets` builds the test binaries nextest will run, so the test step
# finds them up to date. The scope is the driver crate, which holds both binaries:
# only `tcab` ships as a binary file, and `tcab-driver` ships in the driver image. The
# contracts, suites and
# engines crates it links are the contracts and engines repositories', whose own
# pipelines test them.
#
# `bash` runs Git Bash on the Windows agent, so this one script drives both.
set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tcab-lib.sh"
# shellcheck source=scripts/ci/cargo-lock.sh
source "$REPO_ROOT/scripts/ci/cargo-lock.sh"
# `--locked` only where no patch table shapes the build: inside the superrepo cargo writes the lock's
# `[[patch.unused]]` block in an order that is not stable between runs (scripts/ci/cargo-lock.sh).
mapfile -t locked < <(cargo_locked_args .)

log "cargo build --release --all-targets (the driver crate)"
cargo build --release ${locked[@]+"${locked[@]}"} -p test-cabinet-driver --all-targets
