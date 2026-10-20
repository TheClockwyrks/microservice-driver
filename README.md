# microservice-driver

The run engine: tcab-driver, the tcab CLI and the run-container images.

This repository is one component of
[The Test Cabinet](https://github.com/TheClockwyrks/TheTestCabinet). What it is
and how it fits with the others is stated by the documentation site, which
lives in the superrepo at `apps/docs/src/content/docs/`. Its Repositories page,
`apps/docs/src/content/docs/development/repositories.md`, draws the edges
between the repositories.

## Getting started

Open the superrepo in its devcontainer, which carries every toolchain the
repositories need, and work from this repository's root.
A build here inherits the superrepo's Cargo configuration, which redirects
every dependency on another repository to the sibling checkout, so nothing is
fetched from a mirror.

One command runs every gate:

```sh
make gate
```

Each gate is a file under `ci/gates/` whose stem is the gate's id.
`uv run --quiet --project ci gate list` names them all, and
`azure-pipelines.yml` runs each one as a step of its own on every push, inside
the CI images the superrepo builds.

## The image

The `Dockerfile` at the root is the repository's image, built from the root
with `.dockerignore` as its allowlist. On every gated push to `master` and
`staging` the pipeline builds it natively for amd64 and arm64
(`scripts/ci/image.sh`) and fuses the two into the multi-arch
`testcabinet.azurecr.io/microservice-driver:<commit>` a deployment pins
(`scripts/ci/manifest.sh`).
The `build-context` gate holds every `COPY` to the allowlist and the Rust pin
to `rust-toolchain.toml`. The kit wrote the `Dockerfile` once, and it is the
repository's to grow.

## What it holds

- `crates/driver`, the `test-cabinet-driver` package, with two binaries over
  one library: `tcab-driver`, the per-run executor a dispatcher's Job runs (see
  the [driver overview](https://docs.testcabinet.ai/components/driver/overview/)),
  and `tcab`, the command line interface (`src/bin/tcab/`; see the
  [CLI overview](https://docs.testcabinet.ai/components/cli/overview/)). The
  library is the run engine: execution, the harness registry, the
  orchestrators, events, validation and the static code analyzer. The gg
  release the driver runs is declared once, in `crates/driver/gg-release-version`.
- `harnesses/` and `orchestrators/`: the harness and orchestrator manifests
  and scripts the library embeds.
- `containers/`: the run-container images a run's sandbox executes in, built
  by `containers/build.sh` from the binaries the tool repositories' images
  carry (see `containers/README.md`).
- `.env.runner.example`: the configuration `tcab` loads from `.env.runner`.

The portable static builds are `cargo build-portable` (`tcab`) and
`cargo build-portable-driver` (`tcab-driver`). A release build of the CLI is
`cargo build --release -p test-cabinet-driver --bin tcab`.

## Tests that read other repositories

A few tests read the contract fixtures and the engine manifests off the
`test-cabinet-contracts` and `test-cabinet-engines` dependencies, located with
`cargo metadata` (`crates/driver/src/test_support.rs`), and fail where Cargo
lists none. The tests that read case versions read the copies under
`crates/driver/testdata/definitions/`; the checks that hold the whole
committed catalog to a rule are the backend's. The tests that drive Node or a
browser skip without one, unless `TCAB_REQUIRE_BROWSER=1`, which the
pipeline's Rust job sets, makes a missing toolchain a failure.
