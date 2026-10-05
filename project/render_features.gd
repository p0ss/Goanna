# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends RefCounted

# Independent pass gates. Strength/quality settings remain unchanged so live
# comparisons can restore exactly the same presentation after each variant.
const DEFAULTS := {
	"render_sky_clouds": true,
	"render_cloud_shadows": true,
	"render_atmosphere": true,
	"render_ssao": true,
	# Off unless a profile or the player turns it on: it costs frame time,
	# and before 2026-10-02 nothing drew it.
	"render_ssr": false,
	"render_bloom": true,
	"render_shafts": true,
	"render_sun_shadows": true,
	"render_underwater_volume": true,
	"render_dynamic_lights": true,
	"render_carried_light": true,
	"render_water_waves": true,
	"render_water_reflections": true,
	"render_wet_surfaces": true,
	"render_foliage_wind": true,
	"render_grass_interaction": true,
	"render_grass_aa": true,
	"render_ice_detail": true,
	"render_ice_transmission": true,
	"render_lava_detail": true,
	# The heat shimmer over flames (flame_glow.gdshader). Off on Lowest and Low.
	"render_fire_shimmer": true,
}

# Float globals are isolated by each player RenderScope.
const SHADER_FLAGS := {
	"render_water_waves": "goanna_render_water_waves",
	"render_water_reflections": "goanna_render_water_reflections",
	"render_wet_surfaces": "goanna_render_wet_surfaces",
	"render_foliage_wind": "goanna_render_foliage_wind",
	"render_grass_interaction": "goanna_render_grass_interaction",
	"render_ice_detail": "goanna_render_ice_detail",
	"render_lava_detail": "goanna_render_lava_detail",
	"render_fire_shimmer": "goanna_render_fire_shimmer",
}
