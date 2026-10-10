// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// True transmission is isolated from ordinary opaque/cut-out entities.
// A gem item, tool or piece of armour (diamond_mode not 0) is drawn with
// this blended variant, so its crystal can let the scene through
// (GOANNA_DIAMOND_TRANSMISSION, diamond_refraction.gdshaderinc).
// EntityRenderer::materialForMeshTexture (src/goanna_entities.cpp) picks
// the variant; everything else is entity_common.gdshaderinc.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// How far the crystal lets the scene through, 0 opaque. Default only in
// play; project/diamond_study.gd sets it for comparisons.
uniform float diamond_transparency : hint_range(0.0, 1.0) = 1.0;
#define GOANNA_DIAMOND_TRANSMISSION
#include "res://shaders/entity_common.gdshaderinc"
