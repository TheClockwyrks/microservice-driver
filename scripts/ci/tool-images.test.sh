#!/usr/bin/env bash
# Table test for tool-images.sh. Run it directly: scripts/ci/tool-images.test.sh
#
# A copy of the script runs in a throwaway repository whose containers/tool-images.toml
# pins tool-sprite, tool-paint, tool-particle, tool-voxel, tool-mc, tool-sn, tool-dc,
# tool-sfx-synth, tool-sfx-sample and tool-music, beside a Cargo.lock naming two of them,
# with a docker stub whose registry is a file of references. The subjects are the
# reference each tool image is named by, the override, that `check` fails naming the
# pinned commit when the registry lacks it, the pin file's shape, and that `lock` holds
# the pins to the lock. The last case runs `lock` over this repository's own files.
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
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1" "expected: $2" "got:      ${3:-<empty>}"
	fi
}

check_contains() { # label needle haystack
	if grep -qF -- "$2" <<<"$3"; then
		ok "$1"
	else
		bad "$1" "expected output containing: $2" "got: ${3:-<empty>}"
	fi
}

check_lacks() { # label needle haystack
	if grep -qF -- "$2" <<<"$3"; then
		bad "$1" "expected output without: $2" "got: $3"
	else
		ok "$1"
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

readonly PIN=5555555555555555555555555555555555555555
readonly REF="testcabinet.azurecr.io/tool-sprite:${PIN}"
readonly PAINT_PIN=6666666666666666666666666666666666666666
readonly PAINT_REF="testcabinet.azurecr.io/tool-paint:${PAINT_PIN}"
readonly PARTICLE_PIN=7777777777777777777777777777777777777777
readonly PARTICLE_REF="testcabinet.azurecr.io/tool-particle:${PARTICLE_PIN}"
readonly VOXEL_PIN=8888888888888888888888888888888888888888
readonly VOXEL_REF="testcabinet.azurecr.io/tool-voxel:${VOXEL_PIN}"
readonly MC_PIN=9999999999999999999999999999999999999999
readonly MC_REF="testcabinet.azurecr.io/tool-mc:${MC_PIN}"
readonly SN_PIN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly SN_REF="testcabinet.azurecr.io/tool-sn:${SN_PIN}"
readonly DC_PIN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly DC_REF="testcabinet.azurecr.io/tool-dc:${DC_PIN}"
readonly SYNTH_PIN=cccccccccccccccccccccccccccccccccccccccc
readonly SYNTH_REF="testcabinet.azurecr.io/tool-sfx-synth:${SYNTH_PIN}"
readonly SAMPLE_PIN=dddddddddddddddddddddddddddddddddddddddd
readonly SAMPLE_REF="testcabinet.azurecr.io/tool-sfx-sample:${SAMPLE_PIN}"
readonly MUSIC_PIN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
readonly MUSIC_REF="testcabinet.azurecr.io/tool-music:${MUSIC_PIN}"
# The rows of the three audio tool repositories, which follow the model ones in every list.
readonly AUDIO_ROWS="tool-sfx-synth TOOL_SFX_SYNTH_IMAGE ${SYNTH_REF}
tool-sfx-sample TOOL_SFX_SAMPLE_IMAGE ${SAMPLE_REF}
tool-music TOOL_MUSIC_IMAGE ${MUSIC_REF}"
# The rows of the four model tool repositories, which follow tool-particle's in every list.
readonly MODEL_ROWS="tool-voxel TOOL_VOXEL_IMAGE ${VOXEL_REF}
tool-mc TOOL_MC_IMAGE ${MC_REF}
tool-sn TOOL_SN_IMAGE ${SN_REF}
tool-dc TOOL_DC_IMAGE ${DC_REF}"
repo="$tmp/repo"
mkdir -p "$repo/scripts/ci" "$repo/containers"
cp "$CI_DIR/tool-images.sh" "$CI_DIR/tcab-lib.sh" "$repo/scripts/ci/"
cat >"$tmp/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
[[ "$1 $2 $3" == "buildx imagetools inspect" ]] || exit 2
grep -qxF "$4" "$STUB_REGISTRY"
STUB
chmod +x "$tmp/docker"
# The pin file as the repository writes it: a header, then one line per repository.
write_pins() {
	cat >"$repo/containers/tool-images.toml" <<PINS
# The commit of each tool repository's image.

tool-sprite = "${PIN}"
tool-paint = "${PAINT_PIN}"
tool-particle = "${PARTICLE_PIN}"
tool-voxel = "${VOXEL_PIN}"
tool-mc = "${MC_PIN}"
tool-sn = "${SN_PIN}"
tool-dc = "${DC_PIN}"
tool-sfx-synth = "${SYNTH_PIN}"
tool-sfx-sample = "${SAMPLE_PIN}"
tool-music = "${MUSIC_PIN}"
PINS
}
write_pins
# A lock resolving tool-sprite's and tool-voxel's crates, as the driver's does.
write_lock() { # <sprite commit> <voxel commit>
	cat >"$repo/Cargo.lock" <<LOCK
[[package]]
name = "test-cabinet-draw"
version = "0.0.0"
source = "git+https://github.com/TheClockwyrks/tool-sprite?branch=master#$1"

[[package]]
name = "test-cabinet-voxel"
version = "0.0.0"
source = "git+https://github.com/TheClockwyrks/tool-voxel?branch=master#$2"

[[package]]
name = "test-cabinet-voxel-mesh"
version = "0.1.1"
source = "git+https://github.com/TheClockwyrks/tool-model-core?tag=v0.1.1#ffffffffffffffffffffffffffffffffffffffff"
LOCK
}
write_lock "$PIN" "$VOXEL_PIN"

run() {
	: >"$tmp/log"
	(cd "$tmp" && DOCKER="$tmp/docker" STUB_LOG="$tmp/log" STUB_REGISTRY="$tmp/registry" \
		"$repo/scripts/ci/tool-images.sh" "$@" 2>&1)
}

check_equal "list names every tool repository at its pin, by its build argument" \
	"tool-sprite TOOL_SPRITE_IMAGE ${REF}
tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}
tool-particle TOOL_PARTICLE_IMAGE ${PARTICLE_REF}
${MODEL_ROWS}
${AUDIO_ROWS}" "$(run list)"
check_equal "an environment variable named for the argument overrides it" \
	"tool-sprite TOOL_SPRITE_IMAGE registry.test/tool-sprite:dev
tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}
tool-particle TOOL_PARTICLE_IMAGE ${PARTICLE_REF}
${MODEL_ROWS}
${AUDIO_ROWS}" "$(TOOL_SPRITE_IMAGE=registry.test/tool-sprite:dev run list)"
check_equal "and only that repository's" \
	"tool-sprite TOOL_SPRITE_IMAGE ${REF}
tool-paint TOOL_PAINT_IMAGE registry.test/tool-paint:dev
tool-particle TOOL_PARTICLE_IMAGE ${PARTICLE_REF}
${MODEL_ROWS}
${AUDIO_ROWS}" "$(TOOL_PAINT_IMAGE=registry.test/tool-paint:dev run list)"
check_equal "tool-particle's by TOOL_PARTICLE_IMAGE" \
	"tool-sprite TOOL_SPRITE_IMAGE ${REF}
tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}
tool-particle TOOL_PARTICLE_IMAGE registry.test/tool-particle:dev
${MODEL_ROWS}
${AUDIO_ROWS}" "$(TOOL_PARTICLE_IMAGE=registry.test/tool-particle:dev run list)"
check_equal "a model tool repository's argument overrides only its own" \
	"tool-sprite TOOL_SPRITE_IMAGE ${REF}
tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}
tool-particle TOOL_PARTICLE_IMAGE ${PARTICLE_REF}
tool-voxel TOOL_VOXEL_IMAGE ${VOXEL_REF}
tool-mc TOOL_MC_IMAGE registry.test/tool-mc:dev
tool-sn TOOL_SN_IMAGE ${SN_REF}
tool-dc TOOL_DC_IMAGE ${DC_REF}
${AUDIO_ROWS}" "$(TOOL_MC_IMAGE=registry.test/tool-mc:dev run list)"
check_equal "an audio tool repository's argument overrides only its own" \
	"tool-sprite TOOL_SPRITE_IMAGE ${REF}
tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}
tool-particle TOOL_PARTICLE_IMAGE ${PARTICLE_REF}
${MODEL_ROWS}
tool-sfx-synth TOOL_SFX_SYNTH_IMAGE ${SYNTH_REF}
tool-sfx-sample TOOL_SFX_SAMPLE_IMAGE registry.test/tool-sfx-sample:dev
tool-music TOOL_MUSIC_IMAGE ${MUSIC_REF}" "$(TOOL_SFX_SAMPLE_IMAGE=registry.test/tool-sfx-sample:dev run list)"

printf '%s\n' "$REF" "$PAINT_REF" "$PARTICLE_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$DC_REF" \
	"$SYNTH_REF" "$SAMPLE_REF" "$MUSIC_REF" >"$tmp/registry"
out="$(run check)"
check_equal "check passes when the pinned images are in the registry" "0" "$?"
check_contains "and names them" "tool-sprite: ${REF}" "$out"
check_contains "each of them" "tool-paint: ${PAINT_REF}" "$out"
check_contains "tool-particle's too" "tool-particle: ${PARTICLE_REF}" "$out"
check_contains "tool-voxel's too" "tool-voxel: ${VOXEL_REF}" "$out"
check_contains "and tool-dc's" "tool-dc: ${DC_REF}" "$out"
check_contains "and the audio tools'" "tool-music: ${MUSIC_REF}" "$out"
check_equal "asking the registry about them alone" "buildx imagetools inspect ${REF}
buildx imagetools inspect ${PAINT_REF}
buildx imagetools inspect ${PARTICLE_REF}
buildx imagetools inspect ${VOXEL_REF}
buildx imagetools inspect ${MC_REF}
buildx imagetools inspect ${SN_REF}
buildx imagetools inspect ${DC_REF}
buildx imagetools inspect ${SYNTH_REF}
buildx imagetools inspect ${SAMPLE_REF}
buildx imagetools inspect ${MUSIC_REF}" "$(cat "$tmp/log")"

: >"$tmp/registry"
out="$(run check)"
check_equal "check fails when the registry lacks them" "1" "$?"
check_contains "naming the reference" "${REF} is not in the registry" "$out"
check_contains "and the commit the pin file pins" "pins tool-sprite at ${PIN}" "$out"
check_contains "for each of them" "pins tool-paint at ${PAINT_PIN}" "$out"
check_contains "tool-particle too" "pins tool-particle at ${PARTICLE_PIN}" "$out"
check_contains "the model tool repositories included" "pins tool-sn at ${SN_PIN}" "$out"
check_contains "and the audio ones" "pins tool-sfx-synth at ${SYNTH_PIN}" "$out"

printf '%s\n' "$REF" "$PARTICLE_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$DC_REF" \
	"$SYNTH_REF" "$SAMPLE_REF" "$MUSIC_REF" >"$tmp/registry"
out="$(run check)"
check_equal "check fails when the registry lacks one" "1" "$?"
check_contains "naming that one" "${PAINT_REF} is not in the registry" "$out"
check_lacks "and not the others" "${REF} is not in the registry" "$out"
check_lacks "tool-voxel's among them" "${VOXEL_REF} is not in the registry" "$out"

printf '%s\n' "$REF" "$PAINT_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$DC_REF" \
	"$SYNTH_REF" "$SAMPLE_REF" "$MUSIC_REF" >"$tmp/registry"
out="$(run check)"
check_equal "check fails when the registry lacks the tool-particle image" "1" "$?"
check_contains "naming it and its pin" "pins tool-particle at ${PARTICLE_PIN}" "$out"
check_lacks "and no other" "${PAINT_REF} is not in the registry" "$out"

printf '%s\n' "$REF" "$PAINT_REF" "$PARTICLE_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$SYNTH_REF" "$SAMPLE_REF" \
	"$MUSIC_REF" >"$tmp/registry"
out="$(run check)"
check_equal "check fails when the registry lacks a model tool image" "1" "$?"
check_contains "naming it" "${DC_REF} is not in the registry" "$out"
check_contains "and the commit the pin file pins it at" "pins tool-dc at ${DC_PIN}" "$out"
check_lacks "and not the others" "${MC_REF} is not in the registry" "$out"

printf '%s\n' "$REF" "$PAINT_REF" "$PARTICLE_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$DC_REF" "$SYNTH_REF" \
	"$SAMPLE_REF" >"$tmp/registry"
out="$(run check)"
check_equal "check fails when the registry lacks an audio tool image" "1" "$?"
check_contains "naming it" "${MUSIC_REF} is not in the registry" "$out"
check_contains "and the commit the pin file pins it at" "pins tool-music at ${MUSIC_PIN}" "$out"
check_lacks "and not the others" "${SYNTH_REF} is not in the registry" "$out"

printf '%s\n' "$PAINT_REF" "$PARTICLE_REF" "$VOXEL_REF" "$MC_REF" "$SN_REF" "$DC_REF" \
	"$SYNTH_REF" "$SAMPLE_REF" "$MUSIC_REF" >"$tmp/registry"
out="$(TOOL_SPRITE_IMAGE=registry.test/tool-sprite:dev run check)"
check_equal "an override the registry lacks fails too" "1" "$?"
check_contains "naming the variable" "TOOL_SPRITE_IMAGE names it" "$out"

echo "--- the pin file ---"
sed -i '/^tool-sprite = /d' "$repo/containers/tool-images.toml"
check_equal "a repository left out of the file is left out of the list" \
	"tool-paint TOOL_PAINT_IMAGE ${PAINT_REF}" "$(run list | head -n 1)"
write_pins
printf 'tool-sprite = "%s"\n' "$PIN" >>"$repo/containers/tool-images.toml"
out="$(run list)"
check_equal "a repository pinned twice fails" "1" "$?"
check_contains "naming the line" "tool-images.toml:13 pins tool-sprite a second time" "$out"
write_pins
printf 'tool-sprite = "1da52d0"\n' >>"$repo/containers/tool-images.toml"
out="$(run list)"
check_equal "a short commit fails" "1" "$?"
check_contains "naming the line and the shape" "tool-images.toml:13 is not \`tool-<name> = \"<full commit>\"\`" "$out"
write_pins
printf 'sprite = "%s"\n' "$PIN" >>"$repo/containers/tool-images.toml"
out="$(run list)"
check_equal "a repository that is not a tool repository fails" "1" "$?"
write_pins
printf '# nothing pinned\n' >"$repo/containers/tool-images.toml"
out="$(run list)"
check_equal "a file pinning nothing fails" "1" "$?"
check_contains "saying so" "pins no repository" "$out"
rm "$repo/containers/tool-images.toml"
out="$(run check)"
check_equal "a missing file fails check" "1" "$?"
check_contains "saying what it is" "containers/tool-images.toml is missing" "$out"
check_equal "before asking the registry anything" "" "$(cat "$tmp/log")"
write_pins

echo "--- lock ---"
out="$(run lock)"
check_equal "pins equal to the lock's commits pass" "0" "$?"
check_contains "naming each repository the lock resolves" "tool-sprite: ${PIN} (as Cargo.lock resolves it)" "$out"
check_contains "tool-voxel too" "tool-voxel: ${VOXEL_PIN}" "$out"
check_contains "and how many it compared" "2 pin(s) agree with Cargo.lock" "$out"
check_lacks "a repository the lock does not name is not compared" "tool-paint:" "$out"
check_lacks "and a lock source no pin names is not either" "tool-model-core" "$out"
write_lock "$PAINT_PIN" "$VOXEL_PIN"
out="$(run lock)"
check_equal "a pin the lock resolves elsewhere fails" "1" "$?"
check_contains "naming the pin" "pins tool-sprite at ${PIN}" "$out"
check_contains "and the lock's commit" "resolves its crates at ${PAINT_PIN}" "$out"
check_contains "and still checking the others" "tool-voxel: ${VOXEL_PIN}" "$out"
write_lock "$PIN" "$VOXEL_PIN"
printf '\n[[package]]\nname = "test-cabinet-draw-sheet"\nversion = "0.0.0"\nsource = "git+https://github.com/TheClockwyrks/tool-sprite?branch=master#%s"\n' \
	"$PAINT_PIN" >>"$repo/Cargo.lock"
out="$(run lock)"
check_equal "a lock resolving one repository at two commits fails" "1" "$?"
check_contains "saying so" "resolves tool-sprite to more than one commit" "$out"
rm "$repo/Cargo.lock"
out="$(run lock)"
check_equal "a missing lock fails" "1" "$?"
write_lock "$PIN" "$VOXEL_PIN"

echo "--- this repository's own pins ---"
out="$(cd "$CI_DIR/../.." && scripts/ci/tool-images.sh lock 2>&1)"
check_equal "agree with its Cargo.lock" "0" "$?"
check_contains "tool-sprite's, which the driver links draw from" "tool-sprite: " "$out"
check_contains "and tool-voxel's, which it links voxel from" "tool-voxel: " "$out"

out="$(run)"
check_equal "no subcommand is a usage error" "2" "$?"
check_contains "which says how to call it" "usage: scripts/ci/tool-images.sh list | check | lock" "$out"
out="$(run fetch)"
check_equal "and so is an unknown one" "2" "$?"

echo
echo "tool-images.test.sh: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
