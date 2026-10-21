// The staged manifests name nothing a model must not learn.
//
// A package staged by stage-tcab-packages.mjs is vendored into a model's workspace,
// its `package.json` included, so the manifest is held to the strict vocabulary
// list that the engines repository's scripts/ci/seeded-contract-check.sh (its
// `seeded-contract` gate) holds the seeded packages and the generated asset
// contract to. A manifest published to the project's feed carries the feed's URL
// (`publishConfig`) and the project's `repository`, `homepage` and `bugs`, so the
// staging script drops them; this stages the real closure and reads every manifest
// it wrote. The list is read from the engines repository at the commit Cargo.lock
// resolves it to (scripts/lib/siblings.mjs), since the feed carries no scripts.
//
// It also holds the npm workspace's dependency on each shippable package to the
// engines tag Cargo.lock pins, so the libraries a run is seeded with are the ones
// the driver's engine crates were built from.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { siblingRoot } from "./lib/siblings.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Read from the gate rather than copied, so the two lists cannot drift.
const gate = readFileSync(
  join(siblingRoot("engines"), "scripts/ci/seeded-contract-check.sh"),
  "utf8",
);
const strict = (() => {
  const source = gate.match(/^readonly STRICT='([^']+)'$/m)?.[1];
  assert.ok(source, "could not read STRICT from seeded-contract-check.sh");
  return new RegExp(source, "i");
})();

// The packages the gate holds to the list: the engines repository's own count
// of what is seeded into a run, which must be what this script stages.
const seeded = (() => {
  const source = gate.match(/^readonly SEEDED=\(([^)]*)\)$/m)?.[1];
  assert.ok(source, "could not read SEEDED from seeded-contract-check.sh");
  return source.trim().split(/\s+/);
})();

// The validator harness is staged into the same store but never seeded into a run
// workspace (the reporter reads it once the container is gone), and its own name
// is a word the list bans, so it is the one manifest the list does not apply to.
const NEVER_SEEDED = new Set(["@clockwyrks/case-harness"]);

const REGISTRY_FIELDS = ["publishConfig", "repository", "homepage", "bugs"];

let outDir;
let manifests;

before(() => {
  outDir = mkdtempSync(join(tmpdir(), "stage-tcab-packages-"));
  execFileSync(
    process.execPath,
    [
      join(repoRoot, "scripts/stage-tcab-packages.mjs"),
      "--manifests-only",
      outDir,
    ],
    { cwd: repoRoot, stdio: "pipe" },
  );
  manifests = readdirSync(outDir, { recursive: true })
    .filter((path) => path.split(/[\\/]/).at(-1) === "package.json")
    .map((path) => ({ path, text: readFileSync(join(outDir, path), "utf8") }));
});

after(() => {
  if (outDir) rmSync(outDir, { recursive: true, force: true });
});

test("the closure is staged, the asset contract with it", () => {
  const names = manifests.map(({ text }) => JSON.parse(text).name);
  assert.ok(names.includes("@clockwyrks/voxel-runtime"), names.join(", "));
  assert.ok(names.includes("@clockwyrks/asset-contract"), names.join(", "));
});

test("no staged manifest keeps a registry field", () => {
  for (const { path, text } of manifests) {
    const manifest = JSON.parse(text);
    for (const field of REGISTRY_FIELDS) {
      assert.ok(!(field in manifest), `${path} keeps ${field}`);
    }
  }
});

test("the gate checks every staged package a run is seeded with", () => {
  const script = readFileSync(
    join(repoRoot, "scripts/stage-tcab-packages.mjs"),
    "utf8",
  );
  const list = script.match(/^const SHIPPABLE = \[([\s\S]*?)^\];$/m)?.[1];
  assert.ok(list, "could not read SHIPPABLE from stage-tcab-packages.mjs");
  const shippable = [
    ...list.replace(/\/\/.*$/gm, "").matchAll(/"@clockwyrks\/([^"]+)"/g),
  ].map((match) => match[1]);
  const staged = shippable.filter(
    (name) => !NEVER_SEEDED.has(`@clockwyrks/${name}`),
  );
  assert.deepEqual([...staged].sort(), [...seeded].sort());
});

test("no seeded manifest names what a model must not learn", () => {
  for (const { path, text } of manifests) {
    if (NEVER_SEEDED.has(JSON.parse(text).name)) continue;
    const hits = text.split("\n").filter((line) => strict.test(line));
    assert.deepEqual(hits, [], `${path} names what a model must not learn`);
  }
});

// The lock that records what the driver builds with. Inside the superrepo cargo
// rewrites this checkout's Cargo.lock to the sibling checkouts the superrepo's patch
// table names, which leaves no source of the project's repositories in it, and that
// copy is never committed (the Repositories development page, "The record of what
// builds together"); the record is then the lock HEAD commits.
function recordedLock() {
  const working = readFileSync(join(repoRoot, "Cargo.lock"), "utf8");
  if (/^source = "git\+https:\/\/github\.com\/TheClockwyrks\//m.test(working)) {
    return working;
  }
  return execFileSync("git", ["show", "HEAD:./Cargo.lock"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

test("the workspace depends on each shippable package at the pinned engines tag", () => {
  const lock = recordedLock();
  const tags = new Set(
    [
      ...lock.matchAll(
        /^source = "git\+https:\/\/github\.com\/TheClockwyrks\/engines\?tag=v([^#"]+)#/gm,
      ),
    ].map((match) => match[1]),
  );
  assert.equal(tags.size, 1, `Cargo.lock names engines tags ${[...tags]}`);
  const [version] = tags;
  const { dependencies = {} } = JSON.parse(
    readFileSync(join(repoRoot, "package.json"), "utf8"),
  );
  const script = readFileSync(
    join(repoRoot, "scripts/stage-tcab-packages.mjs"),
    "utf8",
  );
  const list = script.match(/^const SHIPPABLE = \[([\s\S]*?)^\];$/m)?.[1];
  assert.ok(list, "could not read SHIPPABLE from stage-tcab-packages.mjs");
  for (const [, name] of list
    .replace(/\/\/.*$/gm, "")
    .matchAll(/"(@clockwyrks\/[^"]+)"/g)) {
    assert.equal(dependencies[name], version, `package.json pins ${name}`);
  }
});
