// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: clear glass drawn from both sides, such as glass doors, whose
// tiles Luanti leaves unculled. Godot flips NORMAL on back faces when
// culling is off, so the shared material needs nothing else. Depth as in
// glass_clear.gdshader, and for the same reason.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/glass_common.gdshaderinc"
