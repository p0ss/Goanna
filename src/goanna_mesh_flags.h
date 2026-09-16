// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

#include <cstdint>

// Carry light-source ownership through tile batching, then in Irrlicht's
// CPU-only vertex Aux field. The remaining bits retain the texture index.
// These flags are stripped before the Godot mesh attributes are written.
constexpr uint8_t GOANNA_TILE_GLOWS = 0x80;
constexpr uint16_t GOANNA_VERTEX_GLOWS = 0x8000;
constexpr uint16_t GOANNA_VERTEX_TEXTURE_MASK = 0x7fff;

// Switches consulted by the transplanted meshing code.
// When true, Luanti's baked vertex lighting and directional face shading are
// bypassed (vertex colour = tile colour only) so Godot lights the world.
extern bool g_goanna_no_light;

// The active transient form is borrowed only by the struck mapblock's inline
// mesh job. Workers have no matching crack position and never read the form.
// Its mesh includes the neighbouring faces uncovered by this cut, so replacing
// or cancelling it closes the geometry atomically across mapblock boundaries.
namespace goanna { struct RadialForm; }
extern const goanna::RadialForm *g_goanna_carve;

// Depth per fifth of a completed dig (legacy GOANNA_CARVE units); zero disables.
extern float g_goanna_carve_depth;

// Static review row at world Y/Z; disabled when Y is zero.
extern int g_goanna_carve_demo;
extern int g_goanna_carve_demo_z;

// Block edge bevelling: chamfer width as a fraction of a node (0 = off). The
// meshing code chamfers exposed edges of NDT_NORMAL nodes classified by group
// (grass/dirt: horizontal edges; trees: vertical; sand/gravel/snow: both).
extern float g_goanna_bevel;
