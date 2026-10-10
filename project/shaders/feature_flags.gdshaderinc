// SPDX-License-Identifier: LGPL-2.1-or-later
// Per-view feature gates, with on defaults in project.godot.
//
// One float global per render feature switch, 1.0 on and 0.0 off. main.gd
// copies them from render_features.gd's SHADER_FLAGS per view, so each
// player's RenderScope can differ in local play. The graphics tiers
// (graphics_profiles.gd) keep all of these on at every tier except the fire
// shimmer, which is off on Lowest and Low. The switches are in
// docs/systems/render-feature-switches.md, the tiers in
// docs/systems/graphics-tiers.md. Included by water, ice, lava,
// grass_volume, waving_leaves, waving_plants and weather_common; the guard
// lets one shader reach it through more than one include.
#ifndef GOANNA_FEATURE_FLAGS
#define GOANNA_FEATURE_FLAGS
// render_water_waves, render_water_reflections: water.gdshader.
global uniform float goanna_render_water_waves;
global uniform float goanna_render_water_reflections;
// render_wet_surfaces: the rain's darkening and gloss on terrain, plants
// and water.
global uniform float goanna_render_wet_surfaces;
// render_foliage_wind: the sway in waving_leaves and waving_plants.
global uniform float goanna_render_foliage_wind;
// render_grass_interaction: procedural blades bending away from actors.
global uniform float goanna_render_grass_interaction;
// render_ice_detail, render_lava_detail: each material's extra detail.
global uniform float goanna_render_ice_detail;
global uniform float goanna_render_lava_detail;
// render_fire_shimmer: read by flame_shimmer.gdshader, which declares it
// itself rather than including this file.
global uniform float goanna_render_fire_shimmer;
#endif
