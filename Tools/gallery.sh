#!/bin/bash
#
# Regenerates every picture in the README's gallery.
#
# Each shot is the snapshot harness (`Sources/Blockhaven/App/OffscreenSnapshot.swift`)
# driven at a fixed camera, so the gallery is reproducible rather than a folder
# of pictures somebody once took: change the terrain, the shader or a landmark
# and re-running this shows you what moved. Every world shot renders through
# the real block shader and the post-processing pass, which is what puts fog,
# water swell and the daylight grade in them — the harness's default is the
# flat unlit path, and a gallery shot on that path is not what the game looks
# like.
#
#   Tools/gallery.sh                 # all of them
#   Tools/gallery.sh eiffel pyramid  # just these
#
# Captures land at 1920x1080 in a scratch directory and are downsampled to
# 1600px JPEGs in docs/screenshots. That needs ImageMagick; without it the
# full-size PNGs are left in the scratch directory and nothing is overwritten.
#
# The display has to be awake — RealityKit has no offscreen renderer, so this
# drives a real off-screen window and an asleep screen occludes it, which
# comes out as `only 0 frames rendered`. `caffeinate -du -t 600 &` first.

set -euo pipefail

cd "$(dirname "$0")/.."

BIN=.build/release/Blockhaven
OUT=docs/screenshots
SCRATCH=.build/gallery

[ -x "$BIN" ] || { echo "build first: make build-release" >&2; exit 1; }
mkdir -p "$OUT" "$SCRATCH"

# name|extra env, space separated
#
# The demo world is the only place the landmarks exist, so every shot of one
# passes _DEMO=1; the shots of a mechanic (the house, the mob lineup, the UI)
# use the ordinary spawn world, because that is where those mechanics live.
#
# Render distance is passed twice on purpose: _RADIUS decides how much world
# is built and where the fog ends, and RENDER_DISTANCE is what the live game
# reads. Sixteen rather than the shipped ten wherever a landmark has to be
# seen from far enough away to fit in the frame.
SHOTS=(
"burj-khalifa-sunset|_DEMO=1 _RADIUS=10 _POS=-42,78,-72 _YAW=180 _PITCH=25 _TIME=0.5"
"sun-over-the-lake|_RADIUS=16 _POS=0,92,0 _YAW=90 _PITCH=-3 _TIME=0.47"
"great-pyramid-dawn|_DEMO=1 _RADIUS=10 _POS=75,80,38 _YAW=118 _PITCH=2 _TIME=0.03"
"sundown|_RADIUS=16 _POS=-8,94,6 _YAW=92 _PITCH=-5 _TIME=0.505"
)

# Underwater and interior shots pass _REVEAL=1: a capture builds only the
# surface half of each chunk, exactly as the live game does for a chunk nobody
# has revealed, and without it a shot from inside the sea or a cave is a
# picture of the sky.

want=("$@")
wanted() {
	[ ${#want[@]} -eq 0 ] && return 0
	for w in "${want[@]}"; do [ "$w" = "$1" ] && return 0; done
	return 1
}

for shot in "${SHOTS[@]}"; do
	name=${shot%%|*}
	wanted "$name" || continue

	# _RADIUS carries the render distance too: the fog is pinned to how much
	# world got built, so the two have to agree or the picture shows haze at a
	# distance the game would have drawn clear.
	env_args=(BLOCKHAVEN_NO_SAVE=1 "BLOCKHAVEN_SAVE_DIR=$PWD/$SCRATCH/saves"
	          "BLOCKHAVEN_SNAPSHOT=$SCRATCH/$name.png"
	          BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1
	          BLOCKHAVEN_SNAPSHOT_SIZE=1920x1080)
	for kv in ${shot#*|}; do
		key=${kv%%=*}
		env_args+=("BLOCKHAVEN_SNAPSHOT${key}=${kv#*=}")
		[ "$key" = "_RADIUS" ] && env_args+=("BLOCKHAVEN_RENDER_DISTANCE=${kv#*=}")
	done

	printf '%-22s ' "$name"
	env "${env_args[@]}" "$BIN" >/dev/null 2>&1 || { echo "FAILED"; exit 1; }

	if command -v magick >/dev/null; then
		magick "$SCRATCH/$name.png" -resize 1600x -strip -quality 95 "$OUT/$name.jpg"
		echo "$OUT/$name.jpg"
	else
		echo "$SCRATCH/$name.png (install ImageMagick to publish it)"
	fi
done
