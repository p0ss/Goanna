// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Switches consulted by the transplanted meshing code.
// When true, Luanti's baked vertex lighting and directional face shading are
// bypassed (vertex colour = tile colour only) so Godot lights the world.
extern bool g_goanna_no_light;
