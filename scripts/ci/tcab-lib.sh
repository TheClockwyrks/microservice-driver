# shellcheck shell=bash
# The shared helpers of this repository's own CI scripts under scripts/ci/.
#
# This directory holds two kinds of script. The repository kit renders some of
# them (the gates' pipeline plumbing: build-context.sh, git-sources.sh,
# image.sh, manifest.sh, mirror.sh, npm-feed.sh and the rest), and each of those
# stands alone. The repository's own scripts, which run its own pipeline jobs
# and stages (.azure/project/), source this file. It is named for the project
# so a kit update never renders over it.
#
# Sourced (not executed) by each script. It resolves the repository root from
# this file's own location and changes into it, so every CI script behaves
# identically regardless of the directory it is invoked from. The Azure pipeline
# calls these scripts, and a developer reproduces any of its jobs by running the
# same script locally.

# Resolve the repo root two levels up from scripts/ci/ and work from there.
CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_LIB_DIR/../.." && pwd)"
readonly CI_LIB_DIR REPO_ROOT
cd "$REPO_ROOT" || exit 1

# Print a labelled step header so the CI logs are easy to scan.
log() {
	printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

# The Test Cabinet's Azure Container Registry. The pipeline pushes the driver image,
# the run-container images and the audio store here, and a deployment pulls them.
readonly CI_REGISTRY="testcabinet.azurecr.io"
export CI_REGISTRY

# The architecture name an image is published under for this machine: amd64 or arm64.
ci_arch() {
	case "$(uname -m)" in
		x86_64 | amd64) echo amd64 ;;
		aarch64 | arm64) echo arm64 ;;
		*)
			echo "unsupported architecture '$(uname -m)'" >&2
			return 1
			;;
	esac
}
