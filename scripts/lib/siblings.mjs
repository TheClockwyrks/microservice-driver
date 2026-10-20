// The files this repository's scripts read from another repository of the project.
//
// Two are read across a data edge no manifest can name:
//
//   - the sample packs the audio store is staged from, which `microservice-backend`
//     publishes (`containers/sample-packs/`), read through that repository's own clip
//     store module (`scripts/lib/audio-store.mjs`), so the hashing that names a
//     published clip has one source. This is the data edge
//     `microservice-driver -> microservice-backend` the Repositories development
//     page records.
//   - the `seeded-contract` gate's word list in the engines repository
//     (`scripts/ci/seeded-contract-check.sh`), which the package store's staged
//     manifests are held to by scripts/stage-tcab-packages.test.mjs. The engines
//     packages are installed from the feed, which carries no scripts, so the list is
//     read from the engines repository at the commit Cargo.lock resolves it to.
//
// A repository is found in this order:
//
//   1. the directory its environment variable names (`TCAB_BACKEND_DIR`,
//      `TCAB_ENGINES_DIR`), for a checkout kept anywhere else;
//   2. its checkout beside this one in the superrepo, where every repository is a
//      submodule. While the superrepo still holds the sample packs itself, its own
//      root is the backend's place too;
//   3. otherwise a shallow, sparse clone of its public mirror, holding the named
//      paths alone, made under `node_modules/.cache/siblings/` on every run: at the
//      commit Cargo.lock resolves for engines, at `master` for the backend. That is
//      how the pipeline, which checks this repository out on its own, reads them. It
//      sits under the workspace's `node_modules` so a module read from it resolves
//      its own imports (`smol-toml`) from this workspace. The backend's mirrors are
//      tried in order: its own repository's, then the superrepo's, which holds the
//      packs until the backend's extraction moves them.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

/** This checkout's root (the parent of `scripts/`). */
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * Each repository a script reads, with where to find it: the variable naming a
 * checkout of it, its places relative to the superrepo's root, its public mirrors,
 * the commit a clone takes, and the paths a script reads from it, which a clone
 * checks out alone.
 */
export const SIBLINGS = {
  "microservice-backend": {
    env: "TCAB_BACKEND_DIR",
    superrepo: ["microservice-backend", "."],
    mirrors: [
      "https://github.com/TheClockwyrks/microservice-backend",
      "https://github.com/TheClockwyrks/TheTestCabinet",
    ],
    paths: ["containers/sample-packs", "scripts/lib/audio-store.mjs"],
  },
  engines: {
    env: "TCAB_ENGINES_DIR",
    superrepo: ["engines"],
    mirrors: ["https://github.com/TheClockwyrks/engines"],
    // The commit the driver builds with, as Cargo.lock records it.
    locked: true,
    paths: ["scripts/ci/seeded-contract-check.sh"],
  },
};

/** Whether every one of `paths` exists under `root`. */
const holds = (root, paths) =>
  paths.every((path) => existsSync(join(root, path)));

/**
 * The commit `root`'s Cargo.lock resolves the named repository's crates to. Throws
 * unless the lock names exactly one.
 */
export function lockedCommit(name, { root = ROOT } = {}) {
  const lock = readFileSync(join(root, "Cargo.lock"), "utf8");
  const pattern = new RegExp(
    `^source = "git\\+https://github\\.com/TheClockwyrks/${name}(?:\\.git)?(?:\\?[^#"]*)?#([0-9a-f]{40})"$`,
    "gm",
  );
  const commits = new Set([...lock.matchAll(pattern)].map((match) => match[1]));
  if (commits.size !== 1) {
    throw new Error(
      `Cargo.lock resolves ${name} to ${commits.size} commits (${[...commits].join(", ") || "none"}); expected one`,
    );
  }
  return [...commits][0];
}

/** A shallow clone of `mirror` at `ref` (a branch or a full commit), sparse to `paths`. */
function sparseClone(mirror, ref, paths, clone) {
  rmSync(clone, { recursive: true, force: true });
  mkdirSync(clone, { recursive: true });
  const git = (...args) =>
    execFileSync("git", ["-C", clone, ...args], {
      stdio: ["ignore", "ignore", "pipe"],
    });
  git("init", "--quiet");
  git("remote", "add", "origin", mirror);
  // A leading slash anchors each path, as non-cone mode asks of a single file.
  git(
    "sparse-checkout",
    "set",
    "--no-cone",
    ...paths.map((path) => `/${path}`),
  );
  git("fetch", "--quiet", "--depth", "1", "--filter=blob:none", "origin", ref);
  git("-c", "advice.detachedHead=false", "checkout", "--quiet", "FETCH_HEAD");
}

/**
 * The root of the named repository's checkout, found as the header says. Throws
 * with what to do when none is reachable.
 */
export function siblingRoot(name, { root = ROOT, env = process.env } = {}) {
  const sibling = SIBLINGS[name];
  if (sibling === undefined) throw new Error(`no sibling repository ${name}`);

  const named = env[sibling.env];
  if (named) {
    if (!holds(named, sibling.paths)) {
      throw new Error(
        `${sibling.env}=${named} holds none of ${sibling.paths.join(", ")}`,
      );
    }
    return resolve(named);
  }

  for (const place of sibling.superrepo) {
    const inSuperrepo = resolve(root, "..", place);
    if (holds(inSuperrepo, sibling.paths)) return inSuperrepo;
  }

  const ref = sibling.locked ? lockedCommit(name, { root }) : "master";
  const clone = join(root, "node_modules", ".cache", "siblings", name);
  const failures = [];
  for (const mirror of sibling.mirrors) {
    try {
      sparseClone(mirror, ref, sibling.paths, clone);
    } catch (error) {
      failures.push(
        `${mirror}: ${String(error.stderr ?? error.message).trim()}`,
      );
      continue;
    }
    if (holds(clone, sibling.paths)) return clone;
    failures.push(
      `${mirror} at ${ref} holds none of ${sibling.paths.join(", ")}`,
    );
  }
  throw new Error(
    `could not read ${sibling.paths.join(", ")} from ${name}:\n  ${failures.join("\n  ")}\n` +
      `Set ${sibling.env} to a checkout of ${name}, or update scripts/lib/siblings.mjs if they moved.`,
  );
}

/**
 * The backend's clip store module, `scripts/lib/audio-store.mjs`, imported from
 * wherever `siblingRoot` finds the backend. Its `PACKS_DIR` and
 * `OBJECTS_LOCK_PATH` name the backend's `containers/sample-packs/`.
 */
export async function loadAudioStore(options) {
  const backend = siblingRoot("microservice-backend", options);
  return import(
    pathToFileURL(join(backend, "scripts", "lib", "audio-store.mjs")).href
  );
}
