#!/usr/bin/env bash
# Prints, for every run-container image, a digest of the inputs its build reads, and the
# images it is built from.
#
#   scripts/ci/run-image-inputs.sh [<name>...]
#
# One line per image, `<name> <digest> <parent>[,<parent>...]` (`-` when it has no
# parent), for every name containers/image-names.sh lists, or for the names given. The
# digest is 32 hex characters of a SHA-256 over:
#
#   - INPUTS_SCHEMA below, bumped by hand when what a build does changes without any
#     of the following changing: an unpinned upstream (a base image named by tag, an
#     apt package set, a toolchain fetched by version) that has to be refreshed, or
#     an edit to containers/build.sh that alters a build's flags. Bumping it makes
#     every image's digest new, so every image is rebuilt once.
#   - the image's Dockerfile (containers/<name>/Dockerfile; containers/gg/Dockerfile
#     for every `-gg` variant), as the index records it: mode and blob id.
#   - every context path the Dockerfile copies (`COPY`/`ADD` sources that are not
#     `--from=` another stage), as `git ls-files -s` lists the tracked files under
#     it. A Dockerfile that copies `.` reads the whole build context, which is the
#     repository root filtered by the root .dockerignore, so its inputs are that file
#     and every tracked file under each path the allowlist re-includes (its `!` lines).
#     A superset of what the build reads is fine: it can only rebuild too often, never
#     too seldom.
#   - the digests of the images it is built from (its `FROM` parents and the builder
#     stages it copies out of), so a change anywhere below an image reaches it.
#   - for every `-gg` variant, the reference of the gg toolchain image it copies its tree
#     out of: `test-cabinet-gg-toolchains:<version>`, the release the driver pins
#     (scripts/ci/gg-release.sh toolchains-image, or GG_TOOLCHAINS_IMAGE as
#     containers/build.sh takes it). The gg repository publishes a version once, so the
#     tag names the tree, and a bump of the pin rebuilds every variant.
#   - for every image whose Dockerfile declares a tool image's build argument
#     (`ARG TOOL_SPRITE_IMAGE`), that image's reference as scripts/ci/tool-images.sh lists
#     it: `testcabinet.azurecr.io/<repository>:<commit>` at the commit
#     containers/tool-images.toml pins, or the environment variable named for the
#     argument, as containers/build.sh takes it. A `tool-*` repository's pipeline
#     publishes a commit's image once, so the tag names the binaries, and a bump of the
#     pin rebuilds every image that copies from it (and, through the parent digests,
#     everything built from those).
#   - for every image whose Dockerfile declares `ARG LATTICE_TRAINING_DIR` (the
#     performance image), the digest of the Lattice training scenarios it bakes, which
#     containers/build.sh stages into the context from a test-suites checkout:
#     scripts/ci/lattice-training.sh digest, or LATTICE_TRAINING_DIGEST when it is set.
#     The COPY of the staged directory names it by that argument, so the listing above
#     leaves it out, and the scenarios are no file of this repository's index.
#
# scripts/ci/run-images.sh writes this table and containers/build.sh reads it in its
# reuse mode: an image whose digest already names a pushed image in the registry is
# retagged for this commit instead of being built and pushed again. The digest is
# computed from the index, not the working tree: it describes a commit, which is what
# a CI checkout is. What the digest deliberately leaves out is anything the build
# fetches from the network, which is why the schema exists.
#
# The parent map below mirrors containers/build.sh's dispatch (`build_one` and the
# layer rules above it); the two must agree, and build.sh's header says so.
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tcab-lib.sh"

readonly INPUTS_SCHEMA="v1"
readonly CONTAINERS="containers"

# The images an image is built from, or `-`.
parents_of() {
	local name="$1"
	case "$name" in
		base | blender) echo "-" ;;
		# The full-stack images copy their binaries out of the tool images, none an image
		# built here: the references are inputs of theirs, not parents.
		adversarial | performance | full-stack-2d | full-stack-3d) echo "base-wasm" ;;
		game-jam) echo "full-stack-2d" ;;
		*-gg) echo "${name%-gg}" ;;
		# base-wasm and every asset image. An asset image's binaries are copied out of
		# its tool image (tool-sprite, tool-paint, tool-particle, tool-voxel, tool-mc,
		# tool-sn, tool-dc, tool-sfx-synth, tool-sfx-sample or tool-music), which is not
		# an image built here either.
		*) echo "base" ;;
	esac
}

dockerfile_of() {
	local name="$1"
	case "$name" in
		*-gg) echo "${CONTAINERS}/gg/Dockerfile" ;;
		*) echo "${CONTAINERS}/${name}/Dockerfile" ;;
	esac
}

# The context sources a Dockerfile's COPY and ADD instructions read: every source
# argument of an instruction that does not name another stage with `--from=`, with the
# destination (the last argument) dropped, continuation lines joined and comments
# skipped. A source that expands a variable is left out: the build arguments here
# name images, whose content the parents' digests cover.
context_sources() {
	local dockerfile="$1"
	awk '
		/^[[:space:]]*#/ { next }
		{
			line = $0
			while (line ~ /\\[[:space:]]*$/) {
				sub(/\\[[:space:]]*$/, "", line)
				if ((getline next_line) <= 0) break
				line = line " " next_line
			}
			if (line !~ /^[[:space:]]*(COPY|ADD)[[:space:]]/) next
			if (line ~ /--from=/) next
			n = split(line, parts, /[[:space:]]+/)
			for (i = 2; i < n; i++) {
				if (parts[i] ~ /^--/) continue
				if (parts[i] ~ /\$/) continue
				print parts[i]
			}
		}
	' "$dockerfile"
}

# The paths the root .dockerignore re-includes: what a `COPY . .` can read.
allowlisted_paths() {
	grep -E '^!' .dockerignore | sed -E 's/^!\/?//; s/\/$//' | sort -u
}

# `git ls-files -s` over paths, which is empty for a path with no tracked file.
listing() {
	git ls-files -s -- "$@"
}

declare -A DIGESTS=()

digest_of() {
	local name="$1"
	if [[ -n "${DIGESTS[$name]:-}" ]]; then
		echo "${DIGESTS[$name]}"
		return 0
	fi
	local dockerfile parents parent source arg training parts=""
	dockerfile="$(dockerfile_of "$name")"
	if [[ ! -f "$dockerfile" ]]; then
		echo "run-image-inputs.sh: no Dockerfile for '${name}' at ${dockerfile}" >&2
		return 1
	fi
	parts+="schema ${INPUTS_SCHEMA}"$'\n'
	parts+="$(listing "$dockerfile")"$'\n'
	while IFS= read -r source; do
		[[ -n "$source" ]] || continue
		if [[ "$source" == "." || "$source" == "./" ]]; then
			parts+="$(listing .dockerignore)"$'\n'
			# shellcheck disable=SC2046 # one pathspec per allowlisted path
			parts+="$(listing $(allowlisted_paths))"$'\n'
		else
			parts+="$(listing "${source#./}")"$'\n'
		fi
	done < <(context_sources "$dockerfile")
	if [[ "$name" == *-gg ]]; then
		parts+="gg-toolchains ${GG_TOOLCHAINS_REF}"$'\n'
	fi
	if grep -qE '^ARG LATTICE_TRAINING_DIR(=|$)' "$dockerfile"; then
		training="$(lattice_training_digest)" || return 1
		parts+="lattice-training ${training}"$'\n'
	fi
	while IFS= read -r arg; do
		[[ -n "$arg" ]] || continue
		if [[ -z "${TOOL_IMAGE_REFS[$arg]:-}" ]]; then
			echo "run-image-inputs.sh: ${dockerfile} declares ARG ${arg}, which scripts/ci/tool-images.sh does not list" >&2
			return 1
		fi
		parts+="tool-image ${arg} ${TOOL_IMAGE_REFS[$arg]}"$'\n'
	done < <(grep -oE '^ARG TOOL_[A-Z0-9_]+_IMAGE' "$dockerfile" | sed 's/^ARG //' | sort -u)
	parents="$(parents_of "$name")"
	if [[ "$parents" != "-" ]]; then
		for parent in ${parents//,/ }; do
			parts+="parent ${parent} $(digest_of "$parent")"$'\n'
		done
	fi
	DIGESTS[$name]="$(printf '%s' "$parts" | sha256sum | cut -c 1-32)"
	echo "${DIGESTS[$name]}"
}

# The Lattice training scenarios' digest, computed on first use: finding them may clone
# test-suites, which only the performance image needs. Kept in a file, because the
# digests are computed in subshells, which would each compute it again.
TRAINING_DIGEST_FILE="$(mktemp)"
trap 'rm -f "$TRAINING_DIGEST_FILE"' EXIT
lattice_training_digest() {
	if [[ -n "${LATTICE_TRAINING_DIGEST:-}" ]]; then
		echo "$LATTICE_TRAINING_DIGEST"
		return 0
	fi
	if [[ ! -s "$TRAINING_DIGEST_FILE" ]]; then
		scripts/ci/lattice-training.sh digest >"$TRAINING_DIGEST_FILE" || return 1
	fi
	cat "$TRAINING_DIGEST_FILE"
}

# The gg toolchain image the `-gg` variants copy, read once.
GG_TOOLCHAINS_REF="${GG_TOOLCHAINS_IMAGE:-}"
if [[ -z "$GG_TOOLCHAINS_REF" ]]; then
	GG_TOOLCHAINS_REF="$(scripts/ci/gg-release.sh toolchains-image)"
fi
readonly GG_TOOLCHAINS_REF

# The tool images the run images copy binaries from, by build argument, read once.
declare -A TOOL_IMAGE_REFS=()
tool_images_table="$(scripts/ci/tool-images.sh list)"
while read -r _ tool_arg tool_ref; do
	[[ -n "${tool_arg:-}" ]] || continue
	TOOL_IMAGE_REFS["$tool_arg"]="$tool_ref"
done <<<"$tool_images_table"
unset tool_images_table tool_arg tool_ref

main() {
	local -a names=()
	if [[ $# -gt 0 ]]; then
		names=("$@")
	else
		mapfile -t names < <("${CONTAINERS}/image-names.sh")
	fi
	local name digest
	for name in "${names[@]}"; do
		digest="$(digest_of "$name")"
		printf '%s %s %s\n' "$name" "$digest" "$(parents_of "$name")"
	done
}

main "$@"
