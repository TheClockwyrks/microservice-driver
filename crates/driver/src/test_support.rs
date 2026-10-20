//! The files this package's tests read from outside it.
//!
//! The contract fixtures belong to the contracts repository and the engine
//! manifests to the engines repository, and the tests read them off the crates
//! this repository depends on, at the versions it pins, never off a copy:
//! `cargo metadata` says where Cargo put each crate. On its own that is the git
//! checkout of the tag the root `Cargo.toml` names, which holds the whole
//! repository; inside the superrepo, whose `.cargo/config.toml` patches the
//! source to the sibling checkout, it is that checkout. Either way a test reads
//! the files of the version the driver was built against.
//!
//! A file that cannot be found fails the test asking for it. A test that skipped
//! would stay green while asserting nothing.
//!
//! Three test targets compile this file: the library's unit tests, the `tcab`
//! binary's and the `manifests_are_valid` integration test. Each uses a part of
//! it, so what one leaves unused is not dead code.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

/// The directory holding the manifest of every package the workspace resolves,
/// by name, asked of Cargo once per test process.
fn packages() -> &'static BTreeMap<String, Vec<PathBuf>> {
    static LOCATED: OnceLock<BTreeMap<String, Vec<PathBuf>>> = OnceLock::new();
    LOCATED.get_or_init(locate)
}

/// Ask Cargo where the workspace's packages are.
fn locate() -> BTreeMap<String, Vec<PathBuf>> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let output = Command::new(&cargo)
        .args(["metadata", "--format-version", "1", "--manifest-path"])
        .arg(&manifest)
        .output()
        .unwrap_or_else(|err| {
            panic!(
                "running `{} metadata` failed, so the files of the other repositories cannot be found: {err}",
                cargo.to_string_lossy()
            )
        });
    assert!(
        output.status.success(),
        "`cargo metadata --manifest-path {}` failed, so the files of the other repositories \
         cannot be found:\n{}",
        manifest.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("cargo metadata prints JSON");
    let mut packages: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
    for package in metadata["packages"]
        .as_array()
        .expect("cargo metadata lists the packages")
    {
        let (Some(name), Some(path)) =
            (package["name"].as_str(), package["manifest_path"].as_str())
        else {
            continue;
        };
        let directory = Path::new(path)
            .parent()
            .expect("a manifest path has a directory")
            .to_path_buf();
        packages.entry(name.to_owned()).or_default().push(directory);
    }
    packages
}

/// The directory of the one package called `name` the workspace takes up.
pub(crate) fn package_dir(name: &str) -> PathBuf {
    let found = packages().get(name).map(Vec::as_slice).unwrap_or_default();
    assert_eq!(
        found.len(),
        1,
        "cargo metadata lists {} {name} packages, where the workspace takes exactly one up: {found:?}",
        found.len()
    );
    found[0].clone()
}

/// A directory that must exist.
fn directory(path: PathBuf) -> PathBuf {
    assert!(path.is_dir(), "{} is missing", path.display());
    path
}

/// The contract fixtures, the `fixtures/` directory of the `test-cabinet-contracts`
/// crate.
pub(crate) fn contract_fixtures() -> PathBuf {
    directory(package_dir("test-cabinet-contracts").join("fixtures"))
}

/// The root of the engines repository the `test-cabinet-engines` crate was taken
/// from, two levels above the crate (`crates/engines/`).
pub(crate) fn engines_checkout() -> PathBuf {
    directory(package_dir("test-cabinet-engines").join("../.."))
}
