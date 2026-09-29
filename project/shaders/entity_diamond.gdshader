// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// True transmission is isolated from ordinary opaque/cut-out entities.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float diamond_transparency : hint_range(0.0, 1.0) = 1.0;
#define GOANNA_DIAMOND_TRANSMISSION
#include "res://shaders/entity_common.gdshaderinc"
