# syntax=docker/dockerfile:1
# The image of microservice-driver: `tcab-driver`, the run engine one driver Job
# runs per run, with everything a run reaches on the driver's side of the sandbox.
# Its pipeline builds it on every gated push to master and staging, natively once
# per architecture (scripts/ci/image.sh), and fuses the two into the multi-arch
# `testcabinet.azurecr.io/microservice-driver:<commit>` a deployment pins
# (scripts/ci/manifest.sh). The run-container images under containers/ are not
# built here: containers/build.sh builds them (see containers/README.md).
#
# The build context is the repository root, held to what .dockerignore admits,
# and the `build-context` gate holds every COPY below to that allowlist and the
# Rust pin to rust-toolchain.toml's channel.
#
# A manifest names a dependency on another repository by its public source,
# which a build cannot reach while the mirrors are private. The pipeline hands
# the build the git configuration scripts/ci/git-sources.sh wrote, which
# rewrites each public source to Azure and carries the job's token, as the
# secret `gitconfig`, and the npm configuration scripts/ci/npm-feed.sh wrote,
# which carries the same token as the credential of the project's package feed,
# as the secret `npmrc`. Each is mounted for the one RUN that fetches and never
# enters a layer. A build without them fetches from the public sources as named,
# and cannot install the project's packages.

# The commit the image is built from, which the build context, carrying no
# `.git`, cannot tell; the pipeline passes it. The build stamps it into the
# binary, and it names the audio store below.
ARG TCAB_BUILD_COMMIT

# The audio store the runtime copies in: every published audio pack, as the
# data-only image containers/audio-store/Dockerfile describes, which this
# repository's pipeline pushes at each gated commit before it builds this image.
# So the default is the store of the commit being built. A build of another
# commit, or of a store staged from a checkout (`containers/build.sh
# audio-store`), names it. It is declared before the first FROM, the only scope a
# FROM resolves an argument from.
ARG AUDIO_STORE_IMAGE=testcabinet.azurecr.io/test-cabinet-audio-store:${TCAB_BUILD_COMMIT}

# ── The driver ──────────────────────────────────────────────────────────────
# `tcab-driver`, and the browser driver it load-checks and screenshots a build
# through. The cargo registry, the git checkouts and target/ are cache mounts, so
# a source change compiles only what changed. BuildKit replays the mtimes a file
# had in the context when a COPY is served from cache, so the sources are touched
# first and cargo never takes an artifact of another build as fresh.
#
# THE BROWSER DRIVER belongs to the contracts repository
# (`packages/browser-driver`), at the version this repository pins: the git
# checkout cargo fetched for `test-cabinet-contracts` holds the whole repository,
# and `cargo metadata` says where it is. The checkouts are a cache mount, so the
# driver is copied out in the same RUN.
FROM docker.io/library/rust:1.97.1-bookworm AS build
WORKDIR /src
# What the workspace compiles, and nothing else of the context, so a change to the
# run images or the scripts never invalidates the compile. The harness and
# orchestrator manifests are embedded by the driver library with include_str!.
COPY Cargo.toml Cargo.lock rust-toolchain.toml /src/
COPY .cargo /src/.cargo
COPY crates /src/crates
COPY harnesses /src/harnesses
COPY orchestrators /src/orchestrators
ARG TCAB_BUILD_COMMIT
RUN --mount=type=secret,id=gitconfig,target=/root/.gitconfig,required=false \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    find /src -path /src/target -prune -o -type f -exec touch {} + \
    && TCAB_BUILD_COMMIT="${TCAB_BUILD_COMMIT}" cargo build --release --locked -p test-cabinet-driver --bin tcab-driver \
    && mkdir -p /out/browser-driver \
    && cp target/release/tcab-driver /out/ \
    && contracts="$(cargo metadata --format-version 1 --locked \
         | grep -o '"manifest_path":"[^"]*/crates/contracts/Cargo.toml"' \
         | sed 's#^"manifest_path":"##; s#/crates/contracts/Cargo.toml"$##')" \
    && [ "$(printf '%s\n' "$contracts" | wc -l)" -eq 1 ] && [ -n "$contracts" ] \
    && driver="$contracts/packages/browser-driver" \
    # The driver, the sibling ES modules it imports (the `ttc` reporter kit and
    # the `validation` runtime) and its manifest. driver.mjs imports them by
    # relative path, so a missing sibling is a runtime ERR_MODULE_NOT_FOUND at
    # render time: keep this list in step with driver.mjs's imports.
    && cp "$driver/package.json" "$driver/driver.mjs" "$driver/ttc.mjs" "$driver/validation.mjs" \
         /out/browser-driver/

# ── The gg release ──────────────────────────────────────────────────────────
# The first-party `gg` harness, as the `gg` repository's pipeline released it:
# this stage does not build gg, it fetches the release the driver pins, the one
# line of crates/driver/gg-release-version, which the driver also compiles in as
# its default. scripts/ci/gg-release.sh reads the pin and fetches the static-musl
# binary of this stage's architecture (`uname -m`, which under `--platform` is the
# target's whether the builder is native or emulated), and refuses one whose
# `gg --version` is not the pinned version.
#
# ONLY THE THREE FILES THE FETCH READS are mounted, never the context: the layer is
# keyed on the pin and the helper alone, so a source change does not download the
# binary again, and a pin bump does. TCAB_GG_RELEASE_VERSION and
# TCAB_GG_RELEASE_URL, the names the driver reads at run time, override the pin
# and the release container for one build (a prerelease such as 0.7.1-rc1, or a
# mirror); they are build arguments only and never reach the runtime image.
FROM docker.io/library/debian:bookworm-slim AS gg-release
ARG TCAB_GG_RELEASE_VERSION=
ARG TCAB_GG_RELEASE_URL=
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=scripts/ci/gg-release.sh,target=/src/scripts/ci/gg-release.sh \
    --mount=type=bind,source=scripts/ci/tcab-lib.sh,target=/src/scripts/ci/tcab-lib.sh \
    --mount=type=bind,source=crates/driver/gg-release-version,target=/src/crates/driver/gg-release-version \
    TCAB_GG_RELEASE_VERSION="${TCAB_GG_RELEASE_VERSION}" \
    TCAB_GG_RELEASE_URL="${TCAB_GG_RELEASE_URL}" \
    bash /src/scripts/ci/gg-release.sh fetch /gg-release \
  && chmod 0755 /gg-release/gg \
  && /gg-release/gg --version

# ── The package store ───────────────────────────────────────────────────────
# A case that declares `packages`, and every engine a run selects, has its
# `@clockwyrks/*` runtime libraries vendored into the run repository at seed time
# out of a host package store. The libraries are the engines repository's, which
# its pipeline publishes to the project's feed at each tag, and this repository's
# npm workspace depends on them at the tag it pins. `npm ci` installs them, built,
# from the feed, with the feed's credential mounted for that RUN alone (the
# project's .npmrc names the feed for the `@clockwyrks` scope), and
# scripts/stage-tcab-packages.mjs stages each publish-shaped copy under
# /opt/tcab-packages. Only the workspace's dependencies are installed, not its
# development tools.
FROM docker.io/library/node:24-bookworm-slim AS tcab-packages
WORKDIR /repo
COPY package.json package-lock.json .npmrc /repo/
COPY scripts/stage-tcab-packages.mjs /repo/scripts/stage-tcab-packages.mjs
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,required=false \
    --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && node scripts/stage-tcab-packages.mjs /opt/tcab-packages

# ── The audio store ─────────────────────────────────────────────────────────
# The driver stages each run's declared audio packs into its run container out of
# a host audio store (crates/driver `audio_stage` -> `/opt/audio`). Staging the
# store reads the private audio object store with the read-scoped R2 presign
# credentials, so it is published once as its own data-only image and copied in
# from there: this build needs no audio credential. A tag that cannot be resolved
# fails the build here rather than shipping a driver whose every full-stack,
# game-jam, sfx-sample and music run fails at container start.
FROM ${AUDIO_STORE_IMAGE} AS audio-store

# ── The runtime ─────────────────────────────────────────────────────────────
# The dispatcher creates one driver Job per run; each driver pod runs this image,
# resolves the run from the backend, and, under TCAB_DRIVER_RUNTIME=kubernetes,
# spawns one untrusted sandbox pod through the Kubernetes API, execs the harness
# session into it, streams the run's live events and preview back to the backend,
# uploads the produced tree to the artifact service, and exits. It needs no
# container daemon and runs unprivileged.
#
# It drives a run end to end in this process, which shells out to three tools:
#   - `git`, to seed each run's fresh repository; a missing git fails every run at
#     "failed to seed run repository".
#   - a shell and `node`/`npm`, to run an end-to-end case's manifest build steps
#     (`npm ci`, `npm run build`) against the produced source the sandbox returned.
#   - `node`, the browser driver and a Playwright-managed Chromium, to load-check
#     the build and screenshot it for the per-view checks. A missing browser
#     degrades a run to a build-only signal rather than failing it.
FROM docker.io/library/node:24-bookworm-slim

# Where the Playwright-managed Chromium is installed, at build and at run time.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

COPY --from=build /out/browser-driver /opt/browser-driver/

# ca-certificates covers the driver's outbound HTTPS (the Kubernetes API, the
# backend and artifact service over TLS, telemetry export); git seeds each run's
# repository; the fonts are what test cases render with (the slim base ships
# none). The npm install skips Playwright's own browser download so only the one
# Chromium asked for lands, with the libraries it links (`--with-deps`).
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       git \
       fonts-dejavu-core fonts-liberation fonts-noto-core \
  && cd /opt/browser-driver \
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev --no-audit --no-fund \
  && npx --yes playwright install --with-deps chromium \
  && rm -rf /var/lib/apt/lists/* /root/.npm

COPY --from=build /out/tcab-driver /usr/local/bin/tcab-driver

# The static-musl gg the driver copies into each sandbox run pod, so a Kubernetes
# gg run installs locally with no release download. It is the release the `-gg`
# run images were self-checked against. World-readable, so the unprivileged
# `node` user reads it.
COPY --from=gg-release --chmod=0755 /gg-release/gg /usr/local/lib/tcab/gg

# The host package store the seeder vendors a run's runtime libraries out of
# (crates/driver `TCAB_PACKAGES_DIR`), and the host audio store a run's declared
# packs are staged out of (crates/driver `TCAB_AUDIO_STORE`). Both are read by the
# unprivileged `node` user below, so both are made world-readable.
COPY --from=tcab-packages /opt/tcab-packages /opt/tcab-packages
COPY --from=audio-store /opt/tcab-audio /opt/tcab-audio
RUN chmod -R a+rX /opt/tcab-packages /opt/tcab-audio

# An unprivileged user: the Kubernetes runtime needs only API access (its
# ServiceAccount token), never host privileges. The Node base ships the non-root
# `node` user (uid 1000); its home is writable for the build and seed scratch and
# Node's caches, and the browsers installed above are world-readable.
USER node
WORKDIR /home/node

# The Kubernetes runtime by default; the dispatcher sets the TCAB_K8S_* specifics
# and the per-job environment (id, token, run request) when it creates each driver
# Job. TCAB_BROWSER_DRIVER points the load-check at the baked driver whatever the
# working directory, and TCAB_GG_BINARY the gg install at the baked release.
ENV TCAB_DRIVER_RUNTIME=kubernetes \
    TCAB_BROWSER_DRIVER=/opt/browser-driver/driver.mjs \
    TCAB_GG_BINARY=/usr/local/lib/tcab/gg

ENTRYPOINT ["tcab-driver"]
