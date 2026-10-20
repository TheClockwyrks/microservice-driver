#!/usr/bin/env bash
# Provisions the pinned Node for a pipeline job, into a directory the job names, and puts
# it on PATH for every later step of the job.
#
#   scripts/ci/provision-node.sh <dir>
#
# The audio store jobs run it (.azure/project/jobs.yml): the stager is a Node script,
# and a hosted or pool agent's Node is whichever its image shipped, so the job takes the
# one it names instead.
#
# The version is NODE_VERSION, which the job sets beside the step, and which the script
# requires: a version taken from whatever the agent had would be a build nobody chose.
# The official tarball for this machine is unpacked into <dir>/node, unless what is
# there already reports that version, and `##vso[task.prependpath]` puts <dir>/node/bin
# on PATH for the job's later steps. Outside a pipeline that line is inert text, so a
# developer can run this against a scratch directory to reproduce a job's provisioning.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/tcab-lib.sh
source "$here/tcab-lib.sh"

if [[ $# -ne 1 || -z "$1" ]]; then
	echo "usage: scripts/ci/provision-node.sh <dir>" >&2
	exit 2
fi
mkdir -p "$1"
cache="$(cd "$1" && pwd)"
readonly cache

node_version="${NODE_VERSION:-}"
if [[ ! "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "provision-node.sh: NODE_VERSION must name the Node release to provision, as 24.16.0; it is '${node_version}'" >&2
	exit 1
fi
readonly node_version
case "$(uname -m)" in
	x86_64 | amd64) node_arch=x64 ;;
	aarch64 | arm64) node_arch=arm64 ;;
	*)
		echo "no Node build is published for $(uname -m)" >&2
		exit 1
		;;
esac
readonly node_dir="$cache/node"

log "Node $node_version -> $node_dir"
if [[ -x "$node_dir/bin/node" && "$("$node_dir/bin/node" --version 2>/dev/null)" == "v$node_version" ]]; then
	echo "Node v$node_version is already there"
else
	staging="$(mktemp -d)"
	trap 'rm -rf "$staging"' EXIT
	curl -fsSL --retry 5 --retry-delay 5 \
		"https://nodejs.org/dist/v${node_version}/node-v${node_version}-linux-${node_arch}.tar.xz" \
		-o "$staging/node.tar.xz"
	rm -rf "$node_dir"
	mkdir -p "$node_dir"
	tar -xJf "$staging/node.tar.xz" -C "$node_dir" --strip-components=1
	"$node_dir/bin/node" --version
fi
echo "##vso[task.prependpath]$node_dir/bin"
