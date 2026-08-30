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
# steady state at 2560x1371, GPU bound in every row):
#
#                 vista by day          night in the village
#   ultra         +4% med               under noise
#   high          -3% med, +43% low     -10% med, -13% low
#   medium        -24% med, -37% low    -25% med, -30% low
#
# Noise floor 1.7% of the median by day and 3.3% at night, from three
# measurements of the control spread through each plan. Both scenes are
# needed and neither is enough: shadow_lamps is most of what separates the
# tiers after dark and costs nothing at noon with nothing lit, while the
# view and detail distances need somewhere with distance in it.
#
# **Ultra and High are not far apart on hardware like this, and that is the
# honest reading.** It is not that the tiers do nothing. Counted at the same
# vista, settling each tier from the coarsest up so the LOD hysteresis
# cannot carry fine tiers down into a lower one:
#
#              draw calls   primitives   resident blocks
#   medium          2507        3.65M          783
#   high            2619        4.24M          936
#   ultra           3066        6.41M         1278
#
# Ultra draws 76 per cent more geometry than Medium for 24 per cent more
# frame time, because a 3090 is nowhere near geometry limited at this
# scale. Two checks that this is about the machine and not the tiers: the
# same sweep at 1600x900 gave a *wider* spread (-9 and -32 per cent), so
# more pixels shrink the gap and this is not a fill rate story; and turning
# every material and lighting quality channel off at Medium bought only a
# further 10 per cent, so the frame is not sitting in those either. What
# the tiers buy should grow on a card that is geometry limited, which is
# the hardware they exist for and is not the hardware they were measured
# on. Treat the percentages as a floor, not an estimate.
#
# Two more things the numbers do not say. The server under test granted 512
# far nodes, and the client takes the lesser of the grant and the setting,
# so ultra and high shared a far distance and only medium's 256 was
# smaller; on a more generous server the top gap would be wider. And these
# are settled frames with the camera still, which is the kindest case for
# settings that govern how much world is streamed: the cost of a bigger
# view lands while it arrives, not once it has.
#
# Forcing the resolution: the plans ask for one and Wayland refuses to let
# a client resize its own window, so the harness notes the mismatch and
# measures whatever it got. Point GODOT_BIN at a wrapper passing
# `--resolution WxH` to set it at window creation, or the numbers are of
# the default window and not of the plan.
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
