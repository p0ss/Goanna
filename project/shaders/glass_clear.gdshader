// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: clear glass that its game cuts out rather than blends (see
// buildFakeLiquidTextures in goanna_client.cpp). Its clear texels are
// blended at a fifth of their alpha or more, so with depth_draw_always they
// wrote depth too, and the nearer pane of a window two blocks thick hid the
// farther one's frame whenever it happened to draw first: the back edges
// came and went as surfaces were sorted or rebuilt. It writes no depth now.
// depth_prepass_alpha, which writes it only where the art is opaque, was
// tried first: it puts the glass in the shadow pass, and a glass block then
// shadowed the floor under it as if solid. Without depth, overlapping
// frames blend in draw order, which only decides which of two thin frame
// lines is on top.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/glass_common.gdshaderinc"
