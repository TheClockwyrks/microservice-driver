#!/usr/bin/env bash
# Table test for lattice-training.sh. Run it directly: scripts/ci/lattice-training.test.sh
#
# A copy of the script runs in a throwaway checkout of this repository, beside which a
# case may put a `test-suites` checkout, with TCAB_DEFINITIONS_ROOT naming another and
# TCAB_TEST_SUITES_MIRROR a local git repository standing in for the public mirror. The
# subjects are the order the checkouts are looked for in, what `stage` copies, and what
# moves `digest`.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CI_DIR
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
	fail=$((fail + 1))
	printf 'FAIL  %s\n' "$1"
	shift
	printf '        %s\n' "$@"
}
check_equal() { # label expected actual
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "got:      ${3:-<empty>}"; fi
}
check_contains() { # label needle haystack
	if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "expected output containing: $2" "got: ${3:-<empty>}"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

readonly TRAINING="test-cases/performance/hard/lattice/v1.0.0/references/training"
repo="$tmp/work/microservice-driver"
mkdir -p "$repo/scripts/ci"
cp "$CI_DIR/lattice-training.sh" "$CI_DIR/tcab-lib.sh" "$repo/scripts/ci/"

# A test-suites tree holding the set: two scenarios, each a file, and a label.
suites() { # <root> <label>
	mkdir -p "$1/$TRAINING/curve" "$1/$TRAINING/side-load" "$1/test-cases/other"
	echo "{\"scenario\":\"curve\"}" >"$1/$TRAINING/curve/scenario.json"
	echo "{\"scenario\":\"side-load\",\"label\":\"$2\"}" >"$1/$TRAINING/side-load/scenario.json"
	echo "not training" >"$1/test-cases/other/case.toml"
}

# The mirror: a git repository with the set on master.
mirror="$tmp/mirror"
suites "$mirror" mirror
git -C "$mirror" init -q -b master
# As a hosted mirror does, so the partial clone is served as asked.
git -C "$mirror" config uploadpack.allowFilter true
git -C "$mirror" add -A
git -C "$mirror" -c user.name=t -c user.email=t@t commit -q -m init

run() {
	(cd "$tmp" && TCAB_TEST_SUITES_MIRROR="file://$mirror" "$repo/scripts/ci/lattice-training.sh" "$@" 2>&1)
}

echo "--- the mirror ---"
out="$(run locate)"
check_equal "with nothing beside it, the mirror is cloned" "0" "$?"
check_equal "under target/siblings" "$repo/target/siblings/test-suites" "$out"
check_equal "holding the set" "1" "$(find "$repo/target/siblings/test-suites/$TRAINING" -name scenario.json -path '*curve*' | wc -l)"
check_equal "and nothing else of the catalog" "0" "$(find "$repo/target/siblings/test-suites/test-cases/other" 2>/dev/null | wc -l)"
mirror_digest="$(run digest)"
check_equal "the digest is 32 hex characters" "1" "$(grep -cxE '[0-9a-f]{32}' <<<"$mirror_digest")"

echo "--- a checkout beside this one ---"
suites "$tmp/work/test-suites" mirror
out="$(run locate)"
check_equal "is taken over the mirror" "$tmp/work/test-suites" "$out"
check_equal "and the same bytes have the same digest wherever they are" "$mirror_digest" "$(run digest)"
echo '{}' >"$tmp/work/test-suites/$TRAINING/curve/expected.json"
check_equal "a file added moves it" "1" "$(test "$(run digest)" != "$mirror_digest" && echo 1)"
rm "$tmp/work/test-suites/$TRAINING/curve/expected.json"
echo "changed" >"$tmp/work/test-suites/test-cases/other/case.toml"
check_equal "a file outside the set does not" "$mirror_digest" "$(run digest)"
echo '{"scenario":"curve","changed":true}' >"$tmp/work/test-suites/$TRAINING/curve/scenario.json"
check_equal "a file changed does" "1" "$(test "$(run digest)" != "$mirror_digest" && echo 1)"

echo "--- TCAB_DEFINITIONS_ROOT ---"
suites "$tmp/named" named
out="$(TCAB_DEFINITIONS_ROOT="$tmp/named" run locate)"
check_equal "is taken over the checkout beside" "$tmp/named" "$out"
mkdir -p "$tmp/empty"
out="$(TCAB_DEFINITIONS_ROOT="$tmp/empty" run locate)"
check_equal "naming a directory without the set fails" "1" "$?"
check_contains "saying which" "TCAB_DEFINITIONS_ROOT=$tmp/empty holds no $TRAINING" "$out"

echo "--- stage ---"
out="$(TCAB_DEFINITIONS_ROOT="$tmp/named" run stage "$tmp/out/training")"
check_equal "copies the set" "0" "$?"
check_equal "file for file" "$(cd "$tmp/named/$TRAINING" && find . -type f | sort)" "$(cd "$tmp/out/training" && find . -type f | sort)"
check_contains "and says how many" "staged 2 training file(s)" "$out"
echo stale >"$tmp/out/training/stale.json"
TCAB_DEFINITIONS_ROOT="$tmp/named" run stage "$tmp/out/training" >/dev/null
check_equal "replacing what an earlier stage left" "" "$(find "$tmp/out/training" -name stale.json)"
out="$(cd "$tmp/out" && TCAB_DEFINITIONS_ROOT="$tmp/named" TCAB_TEST_SUITES_MIRROR="file://$mirror" \
	"$repo/scripts/ci/lattice-training.sh" stage relative 2>&1)"
check_equal "a relative destination is the caller's" "2" "$(find "$tmp/out/relative" -name scenario.json | wc -l)"

echo "--- a mirror without the set ---"
rm -rf "$tmp/work/test-suites"
git -C "$mirror" rm -rq test-cases/performance
git -C "$mirror" -c user.name=t -c user.email=t@t commit -q -m drop
out="$(run locate)"
check_equal "fails" "1" "$?"
check_contains "saying the set moved" "at master holds no $TRAINING" "$out"
out="$(TCAB_TEST_SUITES_MIRROR="file://$tmp/nowhere" "$repo/scripts/ci/lattice-training.sh" locate 2>&1)"
check_equal "and an unreachable mirror fails" "1" "$?"
check_contains "saying what to set" "Set TCAB_DEFINITIONS_ROOT" "$out"

echo "--- usage ---"
out="$(run)"
check_equal "no subcommand is a usage error" "2" "$?"
out="$(run stage)"
check_equal "stage without a directory is too" "2" "$?"
out="$(run digest extra)"
check_equal "and so is an extra argument" "2" "$?"

echo
echo "lattice-training.test.sh: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
