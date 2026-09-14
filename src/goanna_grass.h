// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>

namespace goanna {
// Opt-in experiment. Adds one batched volume surface to a completed terrain mesh.
// Metadata on its source materials identifies grass top layers and their colour.
void append_grass(const godot::Ref<godot::ArrayMesh> &mesh, bool lod, godot::Node *owner);
void update_grass_interactors(godot::Node *owner, const godot::PackedVector4Array &actors);
}
