# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Complete quality presets: the same controlled keys in every tier.
# Appearance, accessibility, controls and worker scheduling stay independent.
# See docs/graphics-tiers.md for the visual contract and calibration status.
# Historical measurements in docs/perf describe their recorded configurations,
# not these revised candidates. Hardware targets are not measured guarantees.
extends RefCounted

# far_distance -1 requests the server grant rather than an explicit cap.
# Ultra retains the owner's 48 shadow lamps / 256 pool: reducing that pool
# previously made village lamps disappear a few buildings away.
const PROFILES := {
	"lowest": {
		"light_sdfgi": 0,
		"mat_parallax": 0,
		"mat_hair_shader": 0,
		"procedural_grass": 0,
		"solid_ice": 0,
		"view_range": 4,
		"lod_distance": 6,
		"far_distance": 96,
		"shadow_lamps": 0,
		"light_pool": 24,
		"terrain_occlusion": 1,
		"lamp_occlusion": 0,
		"screen_space_detail": 0,
		"shadow_detail": 0,
		"light_ssil": 0,
		"cloud_quality": 0,
		"cloud_layer_count": 1,
		"atmosphere_quality": 0,
		"render_sky_clouds": 1,
		"render_cloud_shadows": 1,
		"render_atmosphere": 0,
		"render_ssao": 0,
		"render_bloom": 1,
		"render_shafts": 0,
		"render_sun_shadows": 1,
		"render_underwater_volume": 0,
		"render_dynamic_lights": 1,
		"render_carried_light": 1,
		"render_water_waves": 1,
		"render_water_reflections": 1,
		"render_wet_surfaces": 1,
		"render_foliage_wind": 1,
		"render_grass_interaction": 1,
		"render_grass_aa": 1,
		"render_ice_detail": 1,
		"render_ice_transmission": 1,
		"render_lava_detail": 1,
		"cloud_style": 0,
		"grass_density": 0.2,
		"grass_draw_distance": 12,
		"grass_interaction_distance": 0,
		"grass_interactors": 0,
		"grass_antialiasing": 0,
		"lamp_shadow_distance": 16,
	},
	"low": {
		"light_sdfgi": 0,
		"mat_parallax": 0,
		"mat_hair_shader": 0,
		"procedural_grass": 0,
		"solid_ice": 0,
		"view_range": 6,
		"lod_distance": 8,
		"far_distance": 128,
		"shadow_lamps": 0,
		"light_pool": 32,
		"terrain_occlusion": 1,
		"lamp_occlusion": 0,
		"screen_space_detail": 0,
		"shadow_detail": 0,
		"light_ssil": 0,
		"cloud_quality": 1,
		"cloud_layer_count": 1,
		"atmosphere_quality": 0.35,
		"render_sky_clouds": 1,
		"render_cloud_shadows": 1,
		"render_atmosphere": 1,
		"render_ssao": 1,
		"render_bloom": 1,
		"render_shafts": 1,
		"render_sun_shadows": 1,
		"render_underwater_volume": 1,
		"render_dynamic_lights": 1,
		"render_carried_light": 1,
		"render_water_waves": 1,
		"render_water_reflections": 1,
		"render_wet_surfaces": 1,
		"render_foliage_wind": 1,
		"render_grass_interaction": 1,
		"render_grass_aa": 1,
		"render_ice_detail": 1,
		"render_ice_transmission": 1,
		"render_lava_detail": 1,
		"cloud_style": 1,
		"grass_density": 0.3,
		"grass_draw_distance": 20,
		"grass_interaction_distance": 4,
		"grass_interactors": 1,
		"grass_antialiasing": 1,
		"lamp_shadow_distance": 24,
	},
	"medium": {
		"light_sdfgi": 1.4,
		"mat_parallax": 1,
		"mat_hair_shader": 1,
		"procedural_grass": 1,
		"solid_ice": 0,
		"view_range": 8,
		"lod_distance": 12,
		"far_distance": 256,
		"shadow_lamps": 0,
		"light_pool": 48,
		"terrain_occlusion": 1,
		"lamp_occlusion": 0,
		"screen_space_detail": 1,
		"shadow_detail": 1,
		"light_ssil": 0,
		"cloud_quality": 1,
		"cloud_layer_count": 2,
		"atmosphere_quality": 0.65,
		"render_sky_clouds": 1,
		"render_cloud_shadows": 1,
		"render_atmosphere": 1,
		"render_ssao": 1,
		"render_bloom": 1,
		"render_shafts": 1,
		"render_sun_shadows": 1,
		"render_underwater_volume": 1,
		"render_dynamic_lights": 1,
		"render_carried_light": 1,
		"render_water_waves": 1,
		"render_water_reflections": 1,
		"render_wet_surfaces": 1,
		"render_foliage_wind": 1,
		"render_grass_interaction": 1,
		"render_grass_aa": 1,
		"render_ice_detail": 1,
		"render_ice_transmission": 1,
		"render_lava_detail": 1,
		"cloud_style": 2,
		"grass_density": 0.4,
		"grass_draw_distance": 32,
		"grass_interaction_distance": 6,
		"grass_interactors": 2,
		"grass_antialiasing": 2,
		"lamp_shadow_distance": 32,
	},
	"high": {
		"light_sdfgi": 1.4,
		"mat_parallax": 1,
		"mat_hair_shader": 1,
		"procedural_grass": 1,
		"solid_ice": 0,
		"view_range": 12,
		"lod_distance": 20,
		"far_distance": 1024,
		"shadow_lamps": 8,
		"light_pool": 64,
		"terrain_occlusion": 1,
		"lamp_occlusion": 0,
		"screen_space_detail": 2,
		"shadow_detail": 1,
		"light_ssil": 1.4,
		"cloud_quality": 2,
		"cloud_layer_count": 3,
		"atmosphere_quality": 1,
		"render_sky_clouds": 1,
		"render_cloud_shadows": 1,
		"render_atmosphere": 1,
		"render_ssao": 1,
		"render_bloom": 1,
		"render_shafts": 1,
		"render_sun_shadows": 1,
		"render_underwater_volume": 1,
		"render_dynamic_lights": 1,
		"render_carried_light": 1,
		"render_water_waves": 1,
		"render_water_reflections": 1,
		"render_wet_surfaces": 1,
		"render_foliage_wind": 1,
		"render_grass_interaction": 1,
		"render_grass_aa": 1,
		"render_ice_detail": 1,
		"render_ice_transmission": 1,
		"render_lava_detail": 1,
		"cloud_style": 2,
		"grass_density": 0.7,
		"grass_draw_distance": 48,
		"grass_interaction_distance": 10,
		"grass_interactors": 4,
		"grass_antialiasing": 2,
		"lamp_shadow_distance": 48,
	},
	"ultra": {
		"light_sdfgi": 1.4,
		"mat_parallax": 1,
		"mat_hair_shader": 1,
		"procedural_grass": 1,
		"solid_ice": 0,
		"view_range": 16,
		"lod_distance": 32,
		"far_distance": -1,
		"shadow_lamps": 48,
		"light_pool": 256,
		"terrain_occlusion": 1,
		"lamp_occlusion": 0,
		"screen_space_detail": 3,
		"shadow_detail": 2,
		"light_ssil": 1.4,
		"cloud_quality": 2,
		"cloud_layer_count": 3,
		"atmosphere_quality": 1,
		"render_sky_clouds": 1,
		"render_cloud_shadows": 1,
		"render_atmosphere": 1,
		"render_ssao": 1,
		"render_bloom": 1,
		"render_shafts": 1,
		"render_sun_shadows": 1,
		"render_underwater_volume": 1,
		"render_dynamic_lights": 1,
		"render_carried_light": 1,
		"render_water_waves": 1,
		"render_water_reflections": 1,
		"render_wet_surfaces": 1,
		"render_foliage_wind": 1,
		"render_grass_interaction": 1,
		"render_grass_aa": 1,
		"render_ice_detail": 1,
		"render_ice_transmission": 1,
		"render_lava_detail": 1,
		"cloud_style": 2,
		"grass_density": 1,
		"grass_draw_distance": 80,
		"grass_interaction_distance": 16,
		"grass_interactors": 8,
		"grass_antialiasing": 3,
		"lamp_shadow_distance": 64,
	},
}

const ORDER := ["lowest", "low", "medium", "high", "ultra"]

const LABELS := {
	"lowest": "Lowest",
	"low": "Low",
	"medium": "Medium",
	"high": "High",
	"ultra": "Ultra",
	"custom": "Custom"
}

const BLURBS := {
	"lowest": "Compact views with block clouds, sun shadows, surface detail and local lights. The starting candidate for handheld local multiplayer; hardware target not yet validated.",
	"low": "A wider view with fluffy rounded block clouds and some volumetric atmosphere. The starting candidate for solo handheld play; hardware target not yet validated.",
	"medium": "More distance, volumetric clouds, sparse grass, bounced light and surface depth. A candidate for modest gaming laptops; tune against the frame budget.",
	"high": "Long views, denser grass, richer indirect lighting and nearby lamp shadows. A candidate for midrange desktops.",
	"ultra": "The longest views, full cloud sampling and the largest lamp shadow budget. For spare performance after reaching your frame target.",
	"custom": "Advanced quality settings differ from the named presets."
}

# Adapter type and core count do not establish a performance budget. Keep a
# conservative initial choice until an actual calibration can recommend one.
static func for_hardware(discrete: bool, _cores: int) -> String:
	return "medium" if discrete else "low"

# The profile a set of current values corresponds to, or "custom".
# Appearance preferences are excluded; every controlled quality key is checked.
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

# Keys below the initial preset, for an informational settings note. This
# does not establish that the machine can afford a higher setting.
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

# The order a live preset change reaches the renderer in, one group at a
# time. Applying a whole preset in one frame froze the machine on
# 2026-09-29 (High to Medium in play, 512 pack, RTX 3090, NVIDIA open module
# 615): the desktop died four seconds later and nothing reached the kernel
# log. Which of the forty changes wedged the driver is not known, so the
# change is spread out instead: geometry and distance first, then lamps and
# shadow maps, then the screen space passes, then SDFGI, then the sky, with
# frames drawn between each group. Keys in no group go last.
const STAGES := [
	["view_range", "lod_distance", "far_distance", "procedural_grass",
			"grass_density", "grass_draw_distance", "grass_interaction_distance",
			"grass_interactors", "grass_antialiasing", "render_grass_aa",
			"render_grass_interaction", "render_foliage_wind", "solid_ice",
			"mat_parallax", "mat_hair_shader", "terrain_occlusion"],
	["shadow_lamps", "light_pool", "lamp_shadow_distance", "lamp_occlusion",
			"render_dynamic_lights", "render_carried_light", "render_sun_shadows",
			"shadow_detail"],
	["light_ssil", "screen_space_detail", "render_ssao", "render_bloom",
			"render_shafts"],
	["light_sdfgi"],
	["cloud_quality", "cloud_style", "cloud_layer_count", "atmosphere_quality", "render_atmosphere",
			"render_sky_clouds", "render_cloud_shadows", "render_underwater_volume"],
]

# Every quality key is cheaper at a lower value, so a lower target releases
# memory and a higher one claims it. far_distance -1 is the server's whole
# grant, the most expensive setting that key has.
static func _cost(key: String, value: float) -> float:
	if key == "far_distance" and value < 0.0:
		return INF
	return value

# The groups of {key: value} that take current to target, reductions first
# so that what a preset gives up is freed before anything it adds is
# allocated. Unchanged keys are left out, and so are empty groups.
static func transition_stages(current: Dictionary, target: Dictionary) -> Array:
	var group_of := {}
	for i in STAGES.size():
		for key in STAGES[i]:
			group_of[key] = i
	var stages: Array = []
	for raising in [false, true]:
		var groups: Array = []
		for i in STAGES.size() + 1:
			groups.append({})
		for key in target:
			var want := float(target[key])
			var have := float(current.get(key, want))
			if absf(want - have) <= 0.001:
				continue
			if (_cost(key, want) > _cost(key, have)) != raising:
				continue
			groups[group_of.get(key, STAGES.size())][key] = want
		for group in groups:
			if not group.is_empty():
				stages.append(group)
	return stages
