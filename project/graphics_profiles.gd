# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Named graphics profiles: what a player picks instead of thirty sliders.
#
# A profile is a set of settings-panel keys and values, applied over the
# compiled-in defaults. The settings panel (ui/game_ui.gd) shows the picker
# and puts everything a profile touches, plus the rest of the quality knobs,
# behind Advanced. main.gd picks the opening profile from the hardware.
#
# What the tiers differ on, and what they deliberately do not:
#
# They differ only on settings measured to cost frames, on a scene with
# buildings, lit lamps, water, foliage and distance in it (docs/benchmark.md,
# tools/bench_plans/graphics.json). On an RTX 3090 at 1600x900:
#
#   shadow_lamps 16 -> 0     median -17%, 1% low -16%, GPU 7.66 -> 6.02ms
#   far_distance -> 0        median -9%, 1% low -26%, renderer CPU 3.68 -> 2.00ms
#   lod_distance 32 -> 12    median -6%, and 57% fewer LOD surfaces
#   terrain_occlusion off    median +5%, 1% low +19%, so it stays on everywhere
#
# They do not differ on the material and lighting quality channels: normal
# strength, occlusion, roughness, specular, surface detail, leaf
# translucency, bevel, motes, corner shading, light shafts, volumetric
# atmosphere, sky fill, bounced light. Those have not been measured on a
# scene where they can act, so degrading them in a lower tier would be a
# guess dressed as a number. They stay at the compiled defaults in every
# profile until there is a measurement to move them.
#
# So a lower tier buys frames by drawing less world and lighting fewer lamps,
# not by making what it does draw look worse. If a machine still cannot hold
# a frame rate on Modest, the missing knobs are the next thing to measure,
# not the next thing to assume.
extends RefCounted

# Key to value, applied over the compiled defaults. A key absent from a
# profile keeps whatever the client already has, which is how the quality
# channels stay untouched.
#
# far_distance -1 means "whatever the server granted", which is what
# set_far_distance treats as unset; naming a number would cap a server that
# grants more.
const PROFILES := {
	"rich": {
		"view_range": 16,
		"lod_distance": 32,
		"far_distance": -1,
		"shadow_lamps": 16,
		"light_pool": 96,
		"terrain_occlusion": 1,
	},
	"balanced": {
		"view_range": 12,
		"lod_distance": 20,
		"far_distance": 1024,
		"shadow_lamps": 8,
		"light_pool": 64,
		"terrain_occlusion": 1,
	},
	"modest": {
		"view_range": 8,
		"lod_distance": 12,
		"far_distance": 256,
		"shadow_lamps": 0,
		"light_pool": 48,
		"terrain_occlusion": 1,
	},
}

# Cheapest first, which is the order the picker shows.
const ORDER := ["modest", "balanced", "rich"]

const LABELS := {
	"modest": "Modest",
	"balanced": "Balanced",
	"rich": "Rich",
	"custom": "Custom",
}

const BLURBS := {
	"modest": "Draws less world and lights fewer lamps. For integrated graphics, or when a bigger view costs more than it is worth.",
	"balanced": "Most of the view distance and half the lamp shadows. The middle of the range, and the one to try first if Rich will not hold a frame rate.",
	"rich": "As much world as the server will send and every lamp shadow the pool allows. What a discrete card with cores to spare should run.",
	"custom": "Settings that do not match any profile, because something in Advanced has been moved.",
}

# What a machine should open on. The same two facts main.gd could already
# read: a discrete adapter shares no memory with the rest of the system, and
# core count stands in for how much meshing can run beside the game.
static func for_hardware(discrete: bool, cores: int) -> String:
	if discrete and cores >= 12:
		return "rich"
	if discrete:
		return "balanced"
	return "modest"

# The profile a set of current values corresponds to, or "custom".
# Compared only on the keys a profile actually names, so a player who has
# moved a quality channel is still on a named profile: those channels are
# not what a profile is about.
static func matches(values: Dictionary) -> String:
	for name in ORDER:
		var same := true
		for key in PROFILES[name]:
			if not values.has(key):
				same = false
				break
			if absf(float(values[key]) - float(PROFILES[name][key])) > 0.001:
				same = false
				break
		if same:
			return name
	return "custom"

# True when `values` sits below what this machine's profile would give it on
# any key the profile raises. This is the stale seed case: goanna.cfg is
# written on the first run with whatever the hardware default picked then,
# and from that point the stored value always wins, so a config first
# written by an older build, or on a run that detected shared graphics,
# pins a capable machine to the low tier for ever with nothing on screen to
# say so.
static func below_hardware(values: Dictionary, want: String) -> Array:
	var short: Array = []
	if not PROFILES.has(want):
		return short
	for key in PROFILES[want]:
		if not values.has(key):
			continue
		var target: float = float(PROFILES[want][key])
		if target < 0.0:          # far_distance "server grant" is not a floor
			continue
		if float(values[key]) < target - 0.001:
			short.append(key)
	return short
