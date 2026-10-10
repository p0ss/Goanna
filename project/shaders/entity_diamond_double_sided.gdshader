// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Armour atlases retain the server model's two-sided rendering.
// entity_diamond.gdshader drawn from both sides, for gem armour on a model
// with backface_culling off.
// EntityRenderer::materialForMeshTexture (src/goanna_entities.cpp) picks
// the variant; everything else is entity_common.gdshaderinc.
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

// As in entity_diamond.gdshader: 0 opaque, 1 the default in play.
uniform float diamond_transparency : hint_range(0.0, 1.0) = 1.0;
#define GOANNA_DOUBLE_SIDED
#define GOANNA_DIAMOND_TRANSMISSION
#include "res://shaders/entity_common.gdshaderinc"
