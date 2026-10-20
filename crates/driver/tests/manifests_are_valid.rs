//! Integration guard: every manifest this repository embeds or reads must parse
//! and resolve through the same loaders the running services use.
//!
//!   - orchestrators (`orchestrators/<slug>/…`)      via [`OrchestratorCatalog`]
//!   - engines       (`engines/<slug>/engine.toml` of the engines repository, at
//!     the version this repository pins)            via `built_in_catalog`
//!   - harnesses     (`harnesses/<slug>/harness.toml`) via [`DefaultHarnessRegistry`]
//!
//! The committed test cases, game jams and test-case groups are the test suites
//! repository's, and the checks that hold the whole catalog to a rule are the
//! backend's, which reads that catalog
//! (<https://docs.testcabinet.ai/development/building/#tests-that-read-case-versions>).
//!
//! Each loader discovers or enumerates the real on-disk files, so a newly added
//! manifest is covered automatically and a schema drift (like a required field the
//! data no longer supplies) surfaces here rather than at run time in a service.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[path = "../src/test_support.rs"]
mod test_support;

use test_cabinet_driver::engine::{BUILT_IN_SLUGS as BUILT_IN_ENGINE_SLUGS, EngineSelection};
use test_cabinet_driver::{
    BUILT_IN_SLUGS, DefaultHarnessRegistry, HarnessRegistry, HarnessSlug, OrchestratorCatalog,
    OrchestratorSelection,
};

/// The repository root (two levels up from this crate's `Cargo.toml`), which holds
/// `harnesses/` and `orchestrators/`.
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Immediate subdirectory paths of `dir`, ignoring files and hidden entries.
fn subdirs(dir: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|err| panic!("read {}: {err}", dir.display()))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir() && !is_hidden(path))
        .collect();
    dirs.sort();
    dirs
}

fn is_hidden(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with('.'))
}

/// Every committed orchestrator directory must load from disk, and every built-in
/// slug must resolve. Discovering the directories from disk means a newly added
/// `orchestrators/<slug>/` is covered without touching this test.
#[test]
fn every_orchestrator_manifest_loads() {
    let catalog = OrchestratorCatalog::new();

    let dirs = subdirs(&repo_root().join("orchestrators"));
    assert!(!dirs.is_empty(), "no orchestrator directories found");
    for dir in &dirs {
        catalog
            .resolve(&OrchestratorSelection::external(dir))
            .unwrap_or_else(|err| panic!("load orchestrator {}: {err:?}", dir.display()));
    }

    // The built-ins the services embed must also resolve by slug.
    for slug in BUILT_IN_SLUGS {
        catalog
            .resolve(&OrchestratorSelection::builtin(*slug))
            .unwrap_or_else(|err| panic!("resolve built-in orchestrator {slug}: {err:?}"));
    }
}

/// Every committed engine directory must be a built-in the catalogue knows, and
/// every built-in slug must resolve.
///
/// The engine catalogue is **closed** — there is no external-directory arm, and
/// the manifests are embedded at build time — so unlike the orchestrator test
/// this cannot discover a new directory and load it from disk. What it can do is
/// insist the two halves agree: an `engines/<slug>/` added on disk without being
/// wired into `BUILT_IN_SLUGS` (and so never compiled in, never resolvable, and
/// never validated) is caught here rather than at launch.
#[test]
fn every_engine_manifest_loads() {
    let catalog = test_cabinet_driver::engine::built_in_catalog();

    // The manifests are the engines repository's, at `engines/<slug>/` of the
    // checkout Cargo took the `test-cabinet-engines` crate from.
    let on_disk: BTreeSet<String> = subdirs(&test_support::engines_checkout().join("engines"))
        .iter()
        .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
        .collect();
    assert!(!on_disk.is_empty(), "no engine directories found");
    let known: BTreeSet<String> = BUILT_IN_ENGINE_SLUGS
        .iter()
        .map(|slug| (*slug).to_owned())
        .collect();
    assert_eq!(
        on_disk, known,
        "engines/ directories must match engine::BUILT_IN_SLUGS exactly"
    );

    // Resolving parses and validates the embedded manifest, so a malformed one
    // panics here (it is an authoring bug, not a runtime condition) and an
    // unknown slug returns an error.
    for slug in BUILT_IN_ENGINE_SLUGS {
        let engine = catalog
            .resolve(&EngineSelection::new(*slug))
            .unwrap_or_else(|err| panic!("resolve built-in engine {slug}: {err:?}"));
        assert_eq!(engine.slug(), *slug);
    }
}

/// Every committed harness manifest must parse (constructing the registry parses
/// every embedded `harness.toml`), and the on-disk `harnesses/` directories must
/// line up exactly with [`HarnessSlug::ALL`] — so a new or renamed harness dir that
/// is not wired into the enum (and thus never validated) is caught here.
#[test]
fn every_harness_manifest_parses_and_matches_the_enum() {
    // Constructing the registry parses every embedded harness manifest; an invalid
    // one panics inside `load_manifest`, failing this test.
    let registry = DefaultHarnessRegistry::new();
    for slug in HarnessSlug::ALL {
        assert!(
            registry.get(slug).is_some(),
            "registry is missing harness `{}`",
            slug.as_str()
        );
    }

    let on_disk: BTreeSet<String> = subdirs(&repo_root().join("harnesses"))
        .iter()
        .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
        .collect();
    let known: BTreeSet<String> = HarnessSlug::ALL
        .iter()
        .map(|slug| slug.as_str().to_owned())
        .collect();
    assert_eq!(
        on_disk, known,
        "harnesses/ directories must match HarnessSlug::ALL exactly"
    );
}
