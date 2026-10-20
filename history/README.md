# history

The record of how this repository's history was extracted from the monorepo,
[The Test Cabinet](https://github.com/TheClockwyrks/TheTestCabinet), where the
driver, the CLI, the harnesses, the orchestrators and the run-container images
here lived until the extraction. Nothing builds or tests against these files;
they are kept so the provenance outlives the scratch clone the extraction ran
in.

## The extraction

The history below the scaffold commit is the monorepo's `issue/repos-11` branch
at `baada99d09de416d74e69db8617ab32b40e1b7ff` (its `nightly` plus the commits
that prepared the extraction: the driver's dependencies moving onto one
contracts tag, and the kit's pipeline for this repository), filtered to the
paths in [`paths.txt`](paths.txt) by git filter-repo 2.47.0:

```sh
git clone -q --no-local --single-branch --branch issue/repos-11 --no-tags \
  <the-test-cabinet> x
cd x
uvx --from git-filter-repo==2.47.0 git-filter-repo --force \
  --paths-from-file ../paths.txt --prune-empty always --preserve-commit-hashes
```

Of the 7,015 commits reachable from that commit, 884 touched a path in the list
and were kept (115 of them merges); the rest were pruned. No tag was carried.
The tip tree of every moved path hashes the same as the monorepo's at that
commit, 2,196 files:

```text
crates/driver   e1faadec78a05cf2c361eee3350e62071dcadcfd
crates/cli      ecfbecc32b39eadf3af6f4ff4782edeb21c4708f
harnesses       ce6375272a5a414993a680ffb665861d61974041
orchestrators   7069a7361d1e113488addb57ddb1c6caa952ef13
```

and `containers/` without `containers/sample-packs/` (the sample packs are the
backend's), `.env.runner.example`, `scripts/stage-tcab-packages.mjs`,
`scripts/stage-tcab-packages.test.mjs`, `scripts/stage-audio-store.mjs` and
`scripts/fetch-audio-store.sh`.

The paths are kept where they were in the monorepo, so the filter needed no
rename and every relative path inside the crate (the harness and orchestrator
manifests it embeds, the copies of committed case versions under
`crates/driver/testdata/definitions/`) works as it did. The commits above this
history then changed what the extraction could not keep as it was: the CLI's
crate, `crates/cli`, became the second binary of the driver's package
(`crates/driver/src/bin/tcab/`), its copies of case versions being a subset of
the driver's; the dependencies on the other repositories are named by their
public sources at the versions this repository pins; and the tests that read
the contract fixtures and the engine manifests locate them off the pinned
crates rather than by a path out of the repository.

## The files

- [`paths.txt`](paths.txt) is the list handed to `--paths-from-file`
  (sha256 `e290366f7d12cd3066f9dff316aeb869e16810b61a72327d72bde7ca86a1acc3`).
  It is generated, not hand-written: the 44 moved paths (each directory of
  `containers/` but `sample-packs/` named on its own), and every path a tracked
  file under them had before a rename or copy, collected by
  `git log --follow --name-status -M -C` over each of the 2,196 files, so a
  file's history reaches back past the commits that moved it into place.
- [`commit-map`](commit-map) is filter-repo's map from each monorepo commit (left)
  to the commit it became here (right), all zeros for a pruned one.
  `--preserve-commit-hashes` left the commit ids quoted in the messages as they
  were, so an id in a message below the scaffold commit names a monorepo commit,
  and this map translates it.

## The live-path review

`paths.txt` names 3,751 paths outside the moved set. Every one is a path a file
here had before it was moved or copied into place, and none is live in the
monorepo's tree at the extraction commit, so the scaffold commit deletes
nothing:

- `test-cases/**` (2,145 paths) and `game-jams/**` (14): the catalog as the
  monorepo held it before the test suites repository took it. The copies of
  committed case versions under `crates/driver/testdata/definitions/` were
  copied from there.
- `crates/core/**` (1,408 paths): the monorepo's run engine before it was
  renamed the driver, with its sources, tests and test data.
- `crates/code-analysis/**` (170 paths): the static code analyzer before it
  became the driver's `analyzer` module.
- `crates/worker/src/kubernetes.rs` and its test: the Kubernetes runtime the
  driver's began as a copy of.
- `crates/cli/src/commands/engines.test.rs`: the CLI's engine selection test
  under its earlier name.
- `containers/asset-gen/Dockerfile`: the asset-generation run image before it
  became the sprite image.
- `packages/ui/**` (10 paths): the engine assets (the `foray` and `lattice`
  sheets, palettes and wasm) a copy under the test data began as, before the
  console moved to the ui-common repository.
