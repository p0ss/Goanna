// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

// Prepare a continuous lava surface from Luanti's independently mapped faces.
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/classes/shader_material.hpp>

namespace video { class IImage; }

namespace goanna {
class GoannaSession;
// Caller holds the map lock. Near lava uses UV for the projected flow vector;
// its texture coordinates come from world position in lava.gdshader.
void prepareLavaSurface(godot::Array &arrays, GoannaSession &session);
// Calibrate the shared crust/glow mask from the selected source artwork.
void configureLavaMaterial(const godot::Ref<godot::ShaderMaterial> &material, video::IImage *image);
}
