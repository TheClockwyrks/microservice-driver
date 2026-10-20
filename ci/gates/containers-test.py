"""Run containers/build.sh's table test, which drives the run-image build through a docker stub.

`containers/build.test.sh` runs the build script against a stub daemon that
keeps the local store and the registry in files, and reads back which images
were built, pulled, retagged and pushed: the content-addressed reuse of
`REUSE_INPUTS`, the tool images taken at the commits
`containers/tool-images.toml` pins or built from a checkout beside this one,
and the gg toolchain image. It reaches no container runtime, registry or
network. The `shell-tests` gate runs the tests under `scripts/` alone, so this
one has a gate of its own.
"""

from the_test_cabinet_ci import enter_repo_root, fail, run, say

# From the workspace root, so the path printed below is the one a developer
# types back.
enter_repo_root()

TEST = "containers/build.test.sh"

if run([TEST]).returncode != 0:
    fail("", "containers/build.sh's table test failed. Run it on its own to see its cases:", f"    {TEST}")

say("containers/build.sh's table test passes.")
