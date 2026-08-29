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
# What the tiers themselves come to, measured 2026-08-30 on that machine as
# live sweeps against the client's own defaults as the control
# (tools/bench_plans/profiles.json by day, profiles-night.json after dark;
# steady state, GPU bound in every row):
#
#                 vista by day          night in the village
#   ultra         under noise           +3% med, +13% low
#   high          -9% med, -20% low     -13% med, +12% low
#   medium        -32% med, -35% low    -33% med, -32% low
#
# Noise floor 8.4% of the median by day and 4.2% at night, from three
# measurements of the control spread through each plan. Both scenes are
# needed and neither is enough: shadow_lamps is most of what separates the
# tiers after dark and costs nothing at noon with nothing lit, while the
# view and detail distances need somewhere with distance in it.
#
# Two things the numbers do not say. The server under test granted 512 far
# nodes, and the client takes the lesser of the grant and the setting, so
# ultra and high shared a far distance and only medium's 256 was smaller;
# on a more generous server the top gap would be wider. And high gave up
# 12% on the 1% low at night while taking 13% off the median, on four times
# the hitches, which is one measurement and not yet a story.
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
# a frame rate on Medium, the missing knobs are the next thing to measure,
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
	"ultra": {
		"view_range": 16,
		"lod_distance": 32,
		"far_distance": -1,
		"shadow_lamps": 16,
		"light_pool": 96,
		"terrain_occlusion": 1,
	},
	"high": {
		"view_range": 12,
		"lod_distance": 20,
		"far_distance": 1024,
		"shadow_lamps": 8,
		"light_pool": 64,
		"terrain_occlusion": 1,
	},
	"medium": {
		"view_range": 8,
		"lod_distance": 12,
		"far_distance": 256,
		"shadow_lamps": 0,
		"light_pool": 48,
		"terrain_occlusion": 1,
	},
}

# Cheapest first, which is the order the picker shows.
const ORDER := ["medium", "high", "ultra"]

const LABELS := {
	"medium": "Medium",
	"high": "High",
	"ultra": "Ultra",
	"custom": "Custom",
}

const BLURBS := {
	"medium": "Draws less world and lights fewer lamps. For integrated graphics, or when a bigger view costs more than it is worth.",
	"high": "Most of the view distance and half the lamp shadows. The middle of the range, and the one to try first if Ultra will not hold a frame rate.",
	"ultra": "As much world as the server will send and every lamp shadow the pool allows. What a discrete card with cores to spare should run.",
	"custom": "Settings that do not match any profile, because something in Advanced has been moved.",
}

# What a machine should open on. The same two facts main.gd could already
# read: a discrete adapter shares no memory with the rest of the system, and
# core count stands in for how much meshing can run beside the game.
static func for_hardware(discrete: bool, cores: int) -> String:
	if discrete and cores >= 12:
		return "ultra"
	if discrete:
		return "high"
	return "medium"

# The profile a set of current values corresponds to, or "custom".
# Compared only on the keys a profile actually names, so a player who has
# moved a quality channel is still on a named profile: those channels are
# not what a profile is about.
#
# A negative target is the "whatever the server granted" sentinel and matches
# any value, for the same reason below_hardware skips it: the client reports
# the number it is currently tracking, never the -1 that asked for it, so
# comparing the two literally made the top profile read as Custom in every
# session that had a grant at all.
static func matches(values: Dictionary) -> String:
	for name in ORDER:
		var same := true
		for key in PROFILES[name]:
			if float(PROFILES[name][key]) < 0.0:
				continue
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
