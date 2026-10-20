#!/usr/bin/env bash
# Checks the engines repository out at the commit a Cargo.lock resolves it to.
#
#   scripts/engines-checkout.sh <Cargo.lock> <dest>
#
# The adversarial and performance run images bake tooling compiled from the engines
# repository (the `foray` and `lattice` CLIs, the reference controllers, the buildkit
# crates), which must be the engine the driver scores against. The driver names engines
# by its public source at a tag, and its Cargo.lock records the commit that tag
# resolved to, so the lock is the one record of which engines this repository builds
# with. Each of those Dockerfiles copies the lock and this script into its build stage
# and runs it there.
#
# The lock must name exactly one engines commit. The commit is fetched from the source
# the lock names (ENGINES_SOURCE overrides it, for a mirror), and <dest> is left holding
# its tree with a copy of the lock as its Cargo.lock: engines is a library and commits no
# lock, so cargo resolves its workspace against the driver's, trimming what engines does
# not use and completing what the driver does not, and every crate the two share is
# built at the version the driver links.
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
	echo "usage: scripts/engines-checkout.sh <Cargo.lock> <dest>" >&2
	exit 2
fi
readonly lock="$1" dest="$2"

if [[ ! -f "$lock" ]]; then
	echo "engines-checkout.sh: there is no lock at ${lock}" >&2
	exit 1
fi

# `<url> <commit>` of every engines source the lock records, deduplicated.
sources="$(grep -oE '^source = "git\+https://github\.com/TheClockwyrks/engines(\.git)?(\?[^#"]*)?#[0-9a-f]{40}"$' "$lock" \
	| sed -E 's/^source = "git\+([^?#]+)(\?[^#]*)?#([0-9a-f]{40})"$/\1 \3/' | sort -u || true)"
if [[ -z "$sources" ]]; then
	echo "engines-checkout.sh: ${lock} resolves no crate of the engines repository" >&2
	exit 1
fi
if [[ "$(wc -l <<<"$sources")" -ne 1 ]]; then
	echo "engines-checkout.sh: ${lock} resolves the engines repository more than once:" >&2
	printf '    %s\n' "${sources//$'\n'/$'\n'    }" >&2
	exit 1
fi
read -r url commit <<<"$sources"
url="${ENGINES_SOURCE:-$url}"

if [[ -e "$dest" ]]; then
	echo "engines-checkout.sh: ${dest} already exists" >&2
	exit 1
fi
mkdir -p "$dest"
git -C "$dest" init --quiet
git -C "$dest" fetch --quiet --depth 1 "$url" "$commit"
git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
actual="$(git -C "$dest" rev-parse HEAD)"
if [[ "$actual" != "$commit" ]]; then
	echo "engines-checkout.sh: ${url} answered ${actual} for ${commit}" >&2
	exit 1
fi
rm -rf "$dest/.git"
cp "$lock" "$dest/Cargo.lock"
echo "engines ${commit} from ${url} at ${dest}"
