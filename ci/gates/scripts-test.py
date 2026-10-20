"""Run the Node scripts' tests with Node's own test runner.

The repository's Node scripts keep their `*.test.mjs` beside them under
`scripts/`: the package store's stager, `scripts/stage-tcab-packages.mjs`,
whose test stages the real closure out of the installed workspace and holds it
to the engines repository's `seeded-contract` word list and to the engines tag
`Cargo.lock` pins. The root `test:scripts` script runs every test there with
`node --test`; the packages it stages are the npm workspace's dependencies, so
the workspace is installed first.

Asked for artifacts, the runner also writes a JUnit report. The reporters are
handed to it through `NODE_OPTIONS`, because the script names its files before
any flag npm could append, and Node reads a flag after the files as the tests'
own argument. Node's JUnit reporter labels every case `test`, so two files with a
test of the same name would read as one test run twice: each case is relabelled
with the file it is in and the suites it is nested in before the report is kept.
"""

import os
import xml.etree.ElementTree as ET
from pathlib import Path

from the_test_cabinet_ci import GIT_LOCATION_VARIABLES, artifacts_dir, enter_repo_root, fail, run, say

# From the workspace root, so the script's file pattern finds the tests
# regardless of the caller's working directory.
root = enter_repo_root()

if not (root / "node_modules").is_dir():
    fail("The npm workspace is not installed. Install it first:", "    npm ci")


def relabel(report: Path) -> None:
    """Name each case's `classname` after its file and its enclosing suites."""
    tree = ET.parse(report)

    def visit(element: ET.Element, suites: list[str]) -> None:
        for child in element:
            if child.tag == "testsuite":
                visit(child, [*suites, child.get("name") or ""])
            elif child.tag == "testcase":
                file = child.get("file") or ""
                where = os.path.relpath(file, root) if file else "scripts"
                child.set("classname", "/".join([Path(where).as_posix(), *suites]))

    visit(tree.getroot(), [])
    tree.write(report, encoding="utf-8", xml_declaration=True)


artifacts = artifacts_dir()
environment: dict[str, str] = {}
if artifacts is not None:
    reporters = (
        "--test-reporter=spec --test-reporter-destination=stdout "
        f"--test-reporter=junit --test-reporter-destination={artifacts / 'junit.xml'}"
    )
    environment["NODE_OPTIONS"] = f"{os.environ.get('NODE_OPTIONS', '')} {reporters}".strip()

ran = run(["npm", "run", "--silent", "test:scripts"], env=environment, unset=GIT_LOCATION_VARIABLES)

if artifacts is not None and (artifacts / "junit.xml").is_file():
    relabel(artifacts / "junit.xml")

if ran.returncode != 0:
    fail(
        "",
        "The Node scripts' tests failed. Reproduce them with:",
        "    npm run test:scripts",
    )

say("The Node scripts' tests pass.")
