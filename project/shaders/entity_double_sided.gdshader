// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Entity surfaces share their material response; alpha and culling are
// separate shader variants so opaque surfaces keep the opaque pipeline.
// This one is opaque and drawn from both sides (GOANNA_DOUBLE_SIDED flips
// the normal on a back face), for models the server marks
// backface_culling off, Mineclonia's players among them.
// EntityRenderer::materialForMeshTexture (src/goanna_entities.cpp) picks
// the variant; everything else is entity_common.gdshaderinc.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#define GOANNA_DOUBLE_SIDED
#include "res://shaders/entity_common.gdshaderinc"
