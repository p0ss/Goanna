// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <functional>

namespace goanna {
// Opt-in experiment. Adds one batched volume surface to a completed terrain mesh.
// Metadata on its source materials identifies grass top layers and their colour.
// Coordinates are Luanti node X/Z and the root's upper Y boundary (node Y+1).
using GrassWaterQuery = std::function<bool(int, float, int)>;
void append_grass(const godot::Ref<godot::ArrayMesh> &mesh, bool lod, godot::Node *owner,
        const GrassWaterQuery &submerged = {}, int cell = 1);
void update_grass_interactors(godot::Node *owner, const godot::PackedVector4Array &actors);
}
