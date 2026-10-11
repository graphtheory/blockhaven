# Blockhaven — developer shortcuts.
#
#   make play       — build and play (release). The one to use.
#   make run        — the same thing, kept as the older name
#   make demo       — build and open the demo world (release)
#   make check      — run every headless check
#   make build      — quick compile check (debug)
#   make run-debug  — play under the debugger, slowly
#   make shaders    — recompile the Metal shader library
#   make mac-app    — the Mac app to hand out, as dist/mac/Blockhaven-Mac.dmg
#   make release    — publish this commit at john-z.com/games (Tools/release.sh)
#   make clean      — wipe build products

.PHONY: build build-release play run demo check run-debug shaders clean mac-app release

# Every headless check, by the environment variable that asks for it. Each
# runs the whole binary and exits nonzero on a failed claim. A `_STRESS`
# check follows the one it stresses: same system, adversarial inputs. They
# are here rather than behind their own target because all seven together
# cost under two seconds, and a check nobody runs is a check that rots.
CHECKS := STAIRS BOOK CREATIVE SURVIVAL AXOLOTL ANIMALS PLANTS LIGHT TNT PET \
	RAILS DEMO HOUSE FURNACE SIGNAL SENSOR SENSOR_STRESS THERMAL \
	THERMAL_STRESS THERMAL_EDGE_STRESS RUINS CROP DANGER BREED HOPPER \
	WEATHER ORE HOMESTEAD BUCKET WATERFLOW COMPASS SAPLING LAVA SKELETON \
	SKELETON_STRESS MASON CAVERN ARMOR BLUEPRINT VAULT SPIRE WRECK GRAVE \
	SAVEALL GRAVITY GRAVITY_STRESS DEMOLITION CONVEYOR CONVEYOR_STRESS INDUSTRY \
	INDUSTRY_STRESS MIGRATION

# The Metal compiler ships with Xcode, not the Command Line Tools, so the
# shader step points at Xcode explicitly while the Swift build keeps using
# whatever `xcode-select` has active.
XCODE_DEVELOPER := /Applications/Xcode.app/Contents/Developer
METALLIB := Sources/Blockhaven/Resources/default.metallib

# Every .metal file has to land in this one library: a bundle has exactly
# one default library, and RealityKit will only link a surface shader out
# of the default one. So sources compile to .air separately and are linked
# together, rather than each producing its own .metallib.
METAL_SOURCES := $(wildcard Shaders/*.metal)
AIR_DIR := .build/metal
AIR := $(patsubst Shaders/%.metal,$(AIR_DIR)/%.air,$(METAL_SOURCES))

# Debug, because this target's job is to answer "does it compile" and it
# does that in about three seconds where release takes twenty.
build:
	@mkdir -p .build/module-cache .build/tmp
	env TMPDIR=$(CURDIR)/.build/tmp SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/module-cache swift build --disable-sandbox

# Everything a build depends on. A whole-tree `find` rather than a list of
# `.swift` globs on purpose: the texture atlas and the compiled
# `default.metallib` live under `Sources` too, and running a *stale* binary
# is a far worse outcome than a redundant twenty-second build.
SOURCES := $(shell find Sources -type f) Package.swift
RELEASE_BIN := .build/release/Blockhaven

# The real rule, with real prerequisites — so `make play` on an unchanged
# tree starts the game immediately instead of paying SwiftPM's planning
# pass to be told there is nothing to do.
$(RELEASE_BIN): $(SOURCES)
	@mkdir -p .build/module-cache .build/tmp
	env TMPDIR=$(CURDIR)/.build/tmp SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/module-cache swift build -c release --disable-sandbox
	@touch $@

# The name the other targets ask for. Phony, so `make build-release` always
# does go and ask SwiftPM — that is what you want when you are checking that
# it still compiles, and the opposite of what you want when you are trying
# to play.
build-release: $(RELEASE_BIN)

# Playing means release, and it is not a close call. Over 600 frames at
# render distance 10, chunk streaming costs 0.68 ms a frame here and
# 20.27 ms under `build` — but the mean is the flattering half. The worst
# frame is 3.47 ms against 171.18 ms, and 171 ms is seventeen dropped
# frames in a row, which is the hitch you feel walking into new terrain.
# The world is octaves of noise and small vector maths, and all of it is real function
# calls until the optimiser gets at it. Every headless check pays the same
# toll: the vegetation check is 0.7 s here and 39 s under `build`.
run play: $(RELEASE_BIN)
	$(RELEASE_BIN)

# The demo world: three landmarks, a railway and a coaster. It never writes
# a save, so unlike every other way into the game this one needs no care
# about which world it might land on top of.
demo: $(RELEASE_BIN)
	BLOCKHAVEN_DEMO=1 $(RELEASE_BIN)

# All of them, stopping at the first failure. Saves go to a scratch
# directory rather than the real one — the house check writes a world, and
# it must never be able to write it next to somebody's.
check: build-release
#
# The output is captured rather than piped, because the exit status of a
# pipeline is `tail`'s and a failing check would be reported as a pass.
	@for name in $(CHECKS); do \
		printf '%-20s ' "$$name"; \
		out=$$(env BLOCKHAVEN_NO_SAVE=1 BLOCKHAVEN_SAVE_DIR=$(CURDIR)/.build/check-saves BLOCKHAVEN_CHECK_$$name=1 .build/release/Blockhaven 2>&1) || { echo; echo "$$out" | tail -5; exit 1; }; \
		echo "$$out" | tail -1; \
	done

# The exception, for when a breakpoint has to land somewhere meaningful
# and an optimised frame has inlined the line you wanted to stop on.
run-debug: build
	BLOCKHAVEN_DEBUG_PLAY=1 .build/debug/Blockhaven

# The .metallib is checked in so a plain `swift build` works without the
# Metal toolchain; rerun this after editing Shaders/*.metal.
shaders: $(METALLIB)

$(AIR_DIR)/%.air: Shaders/%.metal
	@mkdir -p $(AIR_DIR)
	DEVELOPER_DIR=$(XCODE_DEVELOPER) xcrun -sdk macosx metal -O2 -c $< -o $@

$(METALLIB): $(AIR)
	@mkdir -p $(dir $@)
	DEVELOPER_DIR=$(XCODE_DEVELOPER) xcrun -sdk macosx metallib -o $@ $^

mac-app:
	Tools/mac/make-app.sh

release:
	Tools/release.sh

clean:
	swift package clean
