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
#   Tools/gallery.sh sundown atlantis  # just these
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
# reads. Every shot uses 14, the farthest the game itself will draw, so the
# gallery is the game at its best settings and never further than it can see.
#
# The first four open the README; the rest are the website's gallery too.
SHOTS=(
"burj-khalifa-sunset|_DEMO=1 _RADIUS=14 _POS=-42,78,-72 _YAW=180 _PITCH=25 _TIME=0.5"
"sun-over-the-lake|_RADIUS=14 _POS=0,92,0 _YAW=90 _PITCH=-3 _TIME=0.47"
"great-pyramid-dawn|_DEMO=1 _RADIUS=14 _POS=75,80,38 _YAW=118 _PITCH=2 _TIME=0.03"
"sundown|_RADIUS=14 _POS=-8,94,6 _YAW=92 _PITCH=-5 _TIME=0.505"
"the-park-from-above|_DEMO=1 _RADIUS=14 _POS=10,95,95 _YAW=160 _PITCH=-6 _TIME=0.47"
"city-in-the-sky|_DEMO=1 _RADIUS=14 _POS=-12,72,100 _YAW=0 _PITCH=12 _TIME=0.3"
"twin-towers-at-dusk|_DEMO=1 _RADIUS=14 _POS=-142,100,-40 _YAW=180 _PITCH=14 _TIME=0.49"
"eiffel-tower-sunset|_DEMO=1 _RADIUS=14 _POS=-10,70,40 _YAW=122 _PITCH=14 _TIME=0.45"
"castle-at-night|_DEMO=1 _RADIUS=14 _POS=0,70,-8 _YAW=180 _PITCH=10 _TIME=0.62"
"atlantis|_DEMO=1 _RADIUS=14 _REVEAL=1 _POS=-112,50,60 _YAW=270 _PITCH=-4 _TIME=0.3"
"garden-on-the-moon|_STORY=moon _RADIUS=14 _POS=-10,75,-2 _YAW=82 _PITCH=-9 _TIME=0.3"
"fizzlers-at-dusk|_FIZZLERS=1 _RADIUS=14 _YAW=130 _PITCH=-8 _TIME=0.53"
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
	# One retry: a window that comes up occluded renders no frames at all,
	# and the second attempt almost always gets a visible one.
	env "${env_args[@]}" "$BIN" >/dev/null 2>&1 \
		|| env "${env_args[@]}" "$BIN" >/dev/null 2>&1 \
		|| { echo "FAILED"; exit 1; }

	if command -v magick >/dev/null; then
		magick "$SCRATCH/$name.png" -resize 1600x -strip -quality 95 "$OUT/$name.jpg"
		echo "$OUT/$name.jpg"
	else
		echo "$SCRATCH/$name.png (install ImageMagick to publish it)"
	fi
done
