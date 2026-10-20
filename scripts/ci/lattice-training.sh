#!/usr/bin/env bash
# The training scenarios the performance run image bakes, found in a test-suites checkout.
#
#   scripts/ci/lattice-training.sh locate         # the test-suites root holding them
#   scripts/ci/lattice-training.sh stage <dir>    # a copy of them at <dir>
#   scripts/ci/lattice-training.sh digest         # 32 hex characters naming their content
#
# containers/performance/Dockerfile copies the labelled practice set of the Lattice
# case's frozen version to /opt/lattice/training, so a model iterates against the very
# scenarios the case was authored with. They belong to the `test-suites` repository,
# which no manifest of this one can name: they are the data edge
# `microservice-driver -> test-suites` the Repositories development page records. So
# containers/build.sh stages them into the build context (`stage`) before it builds the
# image, and scripts/ci/run-image-inputs.sh puts their `digest` into the image's inputs.
#
# A checkout is found in this order:
#
#   1. the directory TCAB_DEFINITIONS_ROOT names, the catalog root every tool of the
#      project reads case versions from;
#   2. `test-suites` beside this repository's checkout, which in the superrepo is its
#      submodule;
#   3. otherwise a shallow, sparse clone of the public mirror's `master`
#      (TCAB_TEST_SUITES_MIRROR overrides it), holding the training set alone, made
#      under target/siblings/ on every call. That is how the pipeline, which checks this
#      repository out on its own, reads it.
#
# The version is frozen: runs are recorded against it, so its files never change, and a
# checkout at any commit since it was exported holds the same bytes.
set -euo pipefail

usage() {
	echo "usage: scripts/ci/lattice-training.sh locate | stage <dir> | digest" >&2
	exit 2
}

[[ $# -ge 1 ]] || usage
command="$1"
shift
dest=""
case "$command" in
	locate | digest) [[ $# -eq 0 ]] || usage ;;
	stage)
		[[ $# -eq 1 && -n "$1" ]] || usage
		# Resolved before tcab-lib.sh moves to the repository root, so a relative path
		# means what it meant to the caller.
		dest="$(realpath -m -- "$1")"
		;;
	*) usage ;;
esac
readonly command dest

# shellcheck source=scripts/ci/tcab-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tcab-lib.sh"

# The training set's place in a test-suites checkout: the frozen version the image bakes.
readonly TRAINING="test-cases/performance/hard/lattice/v1.0.0/references/training"
readonly MIRROR="${TCAB_TEST_SUITES_MIRROR:-https://github.com/TheClockwyrks/test-suites}"
readonly CLONE="${REPO_ROOT}/target/siblings/test-suites"

holds() { [[ -d "$1/$TRAINING" ]]; }

# The root of a test-suites checkout holding the training set, as the header says.
locate() {
	local named="${TCAB_DEFINITIONS_ROOT:-}" beside
	if [[ -n "$named" ]]; then
		if ! holds "$named"; then
			echo "lattice-training.sh: TCAB_DEFINITIONS_ROOT=${named} holds no ${TRAINING}." >&2
			return 1
		fi
		(cd "$named" && pwd)
		return 0
	fi
	beside="$(cd "$REPO_ROOT/.." && pwd)/test-suites"
	if holds "$beside"; then
		printf '%s\n' "$beside"
		return 0
	fi
	rm -rf "$CLONE"
	mkdir -p "$(dirname "$CLONE")"
	if ! git clone --quiet --depth 1 --filter=blob:none --sparse --branch master "$MIRROR" "$CLONE" >&2 \
		|| ! git -C "$CLONE" sparse-checkout set --no-cone "/${TRAINING}" >&2; then
		echo "lattice-training.sh: could not clone ${MIRROR} for ${TRAINING}." >&2
		echo "       Set TCAB_DEFINITIONS_ROOT to a checkout of test-suites." >&2
		return 1
	fi
	if ! holds "$CLONE"; then
		echo "lattice-training.sh: ${MIRROR} at master holds no ${TRAINING};" >&2
		echo "       if the set moved, update scripts/ci/lattice-training.sh." >&2
		return 1
	fi
	printf '%s\n' "$CLONE"
}

# Every file of the set, `<sha256>  <path relative to the set>`, sorted by path. Its
# digest names the content alone: where the checkout sits and when it was made do not
# move it.
listing() {
	local root="$1"
	(cd "$root/$TRAINING" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

root="$(locate)"
case "$command" in
	locate) printf '%s\n' "$root" ;;
	stage)
		if [[ -z "$(listing "$root")" ]]; then
			echo "lattice-training.sh: ${root}/${TRAINING} holds no file." >&2
			exit 1
		fi
		rm -rf "$dest"
		mkdir -p "$(dirname "$dest")"
		cp -R "$root/$TRAINING" "$dest"
		echo "staged $(listing "$root" | wc -l) training file(s) from ${root} into ${dest}" >&2
		;;
	digest) listing "$root" | sha256sum | cut -c 1-32 ;;
esac
