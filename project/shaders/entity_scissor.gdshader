// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Entity surfaces share their material response; alpha and culling are
// separate shader variants so opaque surfaces keep the opaque pipeline.
// This one cuts out transparent texels (GOANNA_ALPHA_SCISSOR), the common
// case for mob skins, and is back culled.
// EntityRenderer::materialForMeshTexture (src/goanna_entities.cpp) picks
// the variant; everything else is entity_common.gdshaderinc.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#define GOANNA_ALPHA_SCISSOR
#include "res://shaders/entity_common.gdshaderinc"
