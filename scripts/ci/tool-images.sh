#!/usr/bin/env bash
# The `tool-*` images the run-container images copy their tool binaries from, at the
# commits the driver pins.
#
#   scripts/ci/tool-images.sh list    # `<repository> <build-arg> <reference>` per tool image
#   scripts/ci/tool-images.sh check   # fails, naming the commit, when a reference is not pushed
#   scripts/ci/tool-images.sh lock    # fails when a pin differs from the commit Cargo.lock resolves
#
# Each `tool-*` repository's pipeline builds its image on every gated push to master and
# staging and pushes the multi-arch `testcabinet.azurecr.io/<repository>:<commit>` (see
# "The microservice images" at
# https://docs.testcabinet.ai/development/releasing/#the-microservice-images). A run
# image copies the binaries out of that image at the commit the driver pins: a run
# image's Dockerfile declares `ARG <build-arg>` (`TOOL_SPRITE_IMAGE` for `tool-sprite`)
# and copies from `FROM ${<build-arg>} AS <repository>`.
#
# THE PIN is the repository's line in containers/tool-images.toml, the record of which
# commit of each tool repository this repository's run images build together with. The
# file lists every repository a run image copies from, in the order `list` prints them.
#
# An environment variable named for the build argument (`TOOL_SPRITE_IMAGE=<reference>`)
# overrides that repository's reference, as containers/build.sh takes it.
#
# containers/build.sh passes the references as build arguments, scripts/ci/run-image-inputs.sh
# puts them into the inputs digest of every image that copies from one, and
# scripts/ci/run-images.sh runs `check` before it builds anything, so a pin of a commit
# the repository's pipeline has not published fails before the first build rather than
# at the first image that copies from it.
#
# `lock` holds the pins to Cargo.lock. The driver links crates of some tool repositories
# (tool-sprite's `test-cabinet-draw`, tool-voxel's `test-cabinet-voxel`), and the lock
# records the commit it resolved each to; a run image carrying another commit's binary
# would hand a run a tool the driver was not built against. Every repository the lock
# names a source of must be pinned at that one commit. The shell-tests gate runs it
# over this repository's own files.
set -euo pipefail

usage() {
	echo "usage: scripts/ci/tool-images.sh list | check | lock" >&2
	exit 2
}

[[ $# -eq 1 ]] || usage
command="$1"
case "$command" in
	list | check | lock) ;;
	*) usage ;;
esac
readonly command

# shellcheck source=scripts/ci/tcab-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tcab-lib.sh"

readonly PIN_FILE="containers/tool-images.toml"
readonly LOCK_FILE="Cargo.lock"
# Where a tool repository's crates are fetched from, as the workspace's manifests name
# them and Cargo.lock records them: `git+<base>/<repository>?<ref>#<commit>`.
readonly SOURCE_BASE="https://github.com/TheClockwyrks"

# `tool-sprite` -> `TOOL_SPRITE_IMAGE`.
build_arg_of() {
	local repository="$1"
	repository="${repository^^}"
	printf '%s_IMAGE\n' "${repository//-/_}"
}

# `<repository> <commit>` per line of the pin file, in its order. Anything but a
# comment, a blank line or `<repository> = "<40 hex>"` is refused, naming the line, as
# is a repository pinned twice.
pins() {
	local line number=0 repository commit
	local -A seen=()
	if [[ ! -f "$PIN_FILE" ]]; then
		echo "tool-images.sh: ${PIN_FILE} is missing; it pins the tool images the run images copy from." >&2
		return 1
	fi
	while IFS= read -r line || [[ -n "$line" ]]; do
		number=$((number + 1))
		line="${line%$'\r'}"
		[[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
		if [[ ! "$line" =~ ^(tool-[a-z0-9]+(-[a-z0-9]+)*)\ =\ \"([0-9a-f]{40})\"$ ]]; then
			echo "tool-images.sh: ${PIN_FILE}:${number} is not \`tool-<name> = \"<full commit>\"\`: ${line}" >&2
			return 1
		fi
		repository="${BASH_REMATCH[1]}"
		commit="${BASH_REMATCH[3]}"
		if [[ -n "${seen[$repository]:-}" ]]; then
			echo "tool-images.sh: ${PIN_FILE}:${number} pins ${repository} a second time." >&2
			return 1
		fi
		seen["$repository"]=1
		printf '%s %s\n' "$repository" "$commit"
	done <"$PIN_FILE"
	if [[ ${#seen[@]} -eq 0 ]]; then
		echo "tool-images.sh: ${PIN_FILE} pins no repository." >&2
		return 1
	fi
}

# `<repository> <build-arg> <reference>` lines, one per repository.
table() {
	local lines repository commit arg override
	lines="$(pins)" || return 1
	while read -r repository commit; do
		arg="$(build_arg_of "$repository")"
		override="${!arg:-}"
		if [[ -n "$override" ]]; then
			printf '%s %s %s\n' "$repository" "$arg" "$override"
			continue
		fi
		printf '%s %s %s/%s:%s\n' "$repository" "$arg" "$CI_REGISTRY" "$repository" "$commit"
	done <<<"$lines"
}

check() {
	local docker="${DOCKER:-docker}" lines repository arg ref failed=0
	lines="$(table)" || return 1
	while read -r repository arg ref; do
		[[ -n "$repository" ]] || continue
		if "$docker" buildx imagetools inspect "$ref" >/dev/null 2>&1; then
			echo "${repository}: ${ref}"
			continue
		fi
		failed=1
		echo "tool-images.sh: ${ref} is not in the registry." >&2
		if [[ -n "${!arg:-}" ]]; then
			echo "       ${arg} names it." >&2
		else
			echo "       ${PIN_FILE} pins ${repository} at ${ref##*:}, and ${repository}'s pipeline" >&2
			echo "       pushes ${repository}:<commit> only on a gated push to its master or staging:" >&2
			echo "       pin a commit that pipeline has published, or wait for its run." >&2
		fi
	done <<<"$lines"
	return "$failed"
}

# The commits Cargo.lock resolves a repository's crates to, one per line, deduplicated.
locked_commits() {
	local repository="$1"
	grep -oE "^source = \"git\\+${SOURCE_BASE}/${repository}(\\.git)?\\?[^#\"]*#[0-9a-f]{40}\"$" "$LOCK_FILE" \
		| sed -E 's/.*#([0-9a-f]{40})"$/\1/' | sort -u || true
}

lock() {
	local lines repository commit locked failed=0 compared=0
	if [[ ! -f "$LOCK_FILE" ]]; then
		echo "tool-images.sh: ${LOCK_FILE} is missing." >&2
		return 1
	fi
	lines="$(pins)" || return 1
	while read -r repository commit; do
		locked="$(locked_commits "$repository")"
		[[ -n "$locked" ]] || continue
		compared=$((compared + 1))
		if [[ "$(wc -l <<<"$locked")" -ne 1 ]]; then
			failed=1
			echo "tool-images.sh: ${LOCK_FILE} resolves ${repository} to more than one commit:" >&2
			sed 's/^/       /' <<<"$locked" >&2
			continue
		fi
		if [[ "$locked" != "$commit" ]]; then
			failed=1
			echo "tool-images.sh: ${PIN_FILE} pins ${repository} at ${commit}," >&2
			echo "       but ${LOCK_FILE} resolves its crates at ${locked}." >&2
			echo "       A run image would carry another commit's binary than the driver links: move the" >&2
			echo "       pin to the lock's commit, or update the lock to the pin." >&2
			continue
		fi
		echo "${repository}: ${commit} (as ${LOCK_FILE} resolves it)"
	done <<<"$lines"
	if [[ "$failed" -eq 0 ]]; then
		echo "${compared} pin(s) agree with ${LOCK_FILE}"
	fi
	return "$failed"
}

case "$command" in
	list) table ;;
	check) check ;;
	lock) lock ;;
esac
