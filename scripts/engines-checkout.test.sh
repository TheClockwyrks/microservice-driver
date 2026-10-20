#!/usr/bin/env bash
# Table test for engines-checkout.sh. Run it directly: scripts/engines-checkout.test.sh
#
# A local git repository stands in for the engines source (ENGINES_SOURCE), with two
# commits, and each case writes a Cargo.lock naming one of them as the driver's names
# the engines repository. The subjects are which commit is checked out, the lock copied
# into it, and the locks refused.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/engines-checkout.sh"
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

source_repo="$tmp/engines"
mkdir -p "$source_repo/crates/foray-core"
git -C "$source_repo" init -q -b master
# As GitHub does, so a commit is fetched by its id.
git -C "$source_repo" config uploadpack.allowAnySHA1InWant true
echo 'first' >"$source_repo/crates/foray-core/lib.rs"
git -C "$source_repo" add -A
git -C "$source_repo" -c user.name=t -c user.email=t@t commit -q -m first
first="$(git -C "$source_repo" rev-parse HEAD)"
echo 'second' >"$source_repo/crates/foray-core/lib.rs"
git -C "$source_repo" -c user.name=t -c user.email=t@t commit -qam second
second="$(git -C "$source_repo" rev-parse HEAD)"

lock() { # <file> <commit>...
	local file="$1" commit
	shift
	: >"$file"
	for commit in "$@"; do
		printf '[[package]]\nname = "foray-core"\nversion = "1.1.2"\nsource = "git+https://github.com/TheClockwyrks/engines?tag=v1.1.2#%s"\n\n' \
			"$commit" >>"$file"
	done
	printf '[[package]]\nname = "test-cabinet-suites"\nversion = "0.2.3"\nsource = "git+https://github.com/TheClockwyrks/contracts?tag=v0.2.3#%s"\n' \
		"ffffffffffffffffffffffffffffffffffffffff" >>"$file"
}

run() { (cd "$tmp" && ENGINES_SOURCE="file://$source_repo" "$SCRIPT" "$@" 2>&1); }

echo "--- a lock naming one commit ---"
lock "$tmp/one.lock" "$first" "$first"
out="$(run "$tmp/one.lock" "$tmp/out/engines")"
check_equal "checks the engines out" "0" "$?"
check_equal "at that commit, not the source's tip" "first" "$(cat "$tmp/out/engines/crates/foray-core/lib.rs")"
check_equal "with the lock beside it" "$(cat "$tmp/one.lock")" "$(cat "$tmp/out/engines/Cargo.lock")"
check_equal "and no history" "" "$(find "$tmp/out/engines" -maxdepth 1 -name .git)"
check_contains "saying which" "engines ${first}" "$out"
lock "$tmp/two.lock" "$second"
out="$(run "$tmp/two.lock" "$tmp/out2/engines")"
check_equal "another lock, another commit" "second" "$(cat "$tmp/out2/engines/crates/foray-core/lib.rs")"

echo "--- the locks refused ---"
lock "$tmp/both.lock" "$first" "$second"
out="$(run "$tmp/both.lock" "$tmp/out3/engines")"
check_equal "a lock naming two commits fails" "1" "$?"
check_contains "saying so" "resolves the engines repository more than once" "$out"
check_equal "before fetching anything" "" "$(find "$tmp/out3" 2>/dev/null)"
printf '[[package]]\nname = "x"\n' >"$tmp/none.lock"
out="$(run "$tmp/none.lock" "$tmp/out4/engines")"
check_equal "a lock naming none fails" "1" "$?"
check_contains "saying so" "resolves no crate of the engines repository" "$out"
out="$(run "$tmp/missing.lock" "$tmp/out5/engines")"
check_equal "a missing lock fails" "1" "$?"
lock "$tmp/gone.lock" "1111111111111111111111111111111111111111"
status=0
out="$(run "$tmp/gone.lock" "$tmp/out6/engines")" || status=$?
check_equal "a commit the source lacks fails" "1" "$((status != 0))"
out="$(run "$tmp/one.lock" "$tmp/out/engines")"
check_equal "an existing destination fails" "1" "$?"
check_contains "rather than mixing two trees" "already exists" "$out"
out="$(run "$tmp/one.lock")"
check_equal "one argument is a usage error" "2" "$?"

echo
echo "engines-checkout.test.sh: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
