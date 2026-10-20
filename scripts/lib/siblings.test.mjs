// How scripts/lib/siblings.mjs finds another repository of the project: the
// commit the lock resolves, a checkout an environment variable names, one beside
// this checkout in the superrepo, and a sparse clone of a mirror, tried in order.
// Every mirror here is a local repository, so nothing reaches the network.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

import { lockedCommit, SIBLINGS, siblingRoot } from "./siblings.mjs";

const tmp = mkdtempSync(join(tmpdir(), "siblings-"));
after(() => rmSync(tmp, { recursive: true, force: true }));

const COMMIT = "d3bb97ccd21640681616a9e29a9e0b6ff045cde7";
const OTHER = "1111111111111111111111111111111111111111";

/** A directory holding `paths` (each a file), returned. */
function tree(dir, paths) {
  for (const path of paths) {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), "x\n");
  }
  return dir;
}

/** A checkout root of this repository, its Cargo.lock naming `commits`. */
function checkout(dir, commits) {
  mkdirSync(dir, { recursive: true });
  const sources = commits.map(
    (commit, index) =>
      `[[package]]\nname = "c${index}"\nsource = "git+https://github.com/TheClockwyrks/engines?tag=v1.1.2#${commit}"\n`,
  );
  writeFileSync(join(dir, "Cargo.lock"), sources.join("\n"));
  return dir;
}

const git = (dir, ...args) =>
  execFileSync("git", ["-C", dir, ...args], { stdio: "pipe" })
    .toString()
    .trim();

test("the lock's one commit of a repository is read", () => {
  const root = checkout(join(tmp, "one"), [COMMIT, COMMIT]);
  assert.equal(lockedCommit("engines", { root }), COMMIT);
});

test("a lock naming two commits, or none, is refused", () => {
  const two = checkout(join(tmp, "two"), [COMMIT, OTHER]);
  assert.throws(() => lockedCommit("engines", { root: two }), /2 commits/);
  const none = checkout(join(tmp, "none"), []);
  assert.throws(() => lockedCommit("engines", { root: none }), /0 commits/);
});

test("the checkout an environment variable names wins", () => {
  const named = tree(join(tmp, "named"), SIBLINGS.engines.paths);
  const root = checkout(join(tmp, "env", "driver"), [COMMIT]);
  assert.equal(
    siblingRoot("engines", { root, env: { TCAB_ENGINES_DIR: named } }),
    named,
  );
});

test("a named checkout without the paths is refused", () => {
  const root = checkout(join(tmp, "empty", "driver"), [COMMIT]);
  assert.throws(
    () =>
      siblingRoot("engines", {
        root,
        env: { TCAB_ENGINES_DIR: join(tmp, "empty") },
      }),
    /holds none of/,
  );
});

test("the superrepo's checkout beside this one is found", () => {
  const superrepo = join(tmp, "superrepo");
  const root = checkout(join(superrepo, "microservice-driver"), [COMMIT]);
  tree(join(superrepo, "engines"), SIBLINGS.engines.paths);
  assert.equal(
    siblingRoot("engines", { root, env: {} }),
    join(superrepo, "engines"),
  );
});

test("the backend is found at the superrepo's root while it holds the packs", () => {
  const superrepo = tree(
    join(tmp, "packs"),
    SIBLINGS["microservice-backend"].paths,
  );
  const root = checkout(join(superrepo, "microservice-driver"), [COMMIT]);
  assert.equal(
    siblingRoot("microservice-backend", { root, env: {} }),
    superrepo,
  );
});

test("otherwise a sparse clone of a mirror at the locked commit holds the paths alone", (t) => {
  const mirror = tree(join(tmp, "mirror"), [
    ...SIBLINGS.engines.paths,
    "crates/big/src/lib.rs",
  ]);
  git(mirror, "init", "--quiet");
  git(mirror, "config", "uploadpack.allowFilter", "true");
  git(mirror, "config", "uploadpack.allowAnySHA1InWant", "true");
  git(mirror, "add", "-A");
  git(
    mirror,
    "-c",
    "user.name=t",
    "-c",
    "user.email=t@t",
    "commit",
    "--quiet",
    "-m",
    "init",
  );
  const head = git(mirror, "rev-parse", "HEAD");
  const root = checkout(join(tmp, "alone", "driver"), [head]);
  const original = SIBLINGS.engines.mirrors;
  SIBLINGS.engines.mirrors = [join(tmp, "no-such-mirror"), `file://${mirror}`];
  t.after(() => {
    SIBLINGS.engines.mirrors = original;
  });
  const clone = siblingRoot("engines", { root, env: {} });
  assert.equal(
    clone,
    join(root, "node_modules", ".cache", "siblings", "engines"),
  );
  assert.equal(git(clone, "rev-parse", "HEAD"), head);
  assert.ok(existsSync(join(clone, SIBLINGS.engines.paths[0])));
  assert.ok(
    !existsSync(join(clone, "crates/big/src/lib.rs")),
    "the clone is not sparse",
  );
});
