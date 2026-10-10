// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Shared by goanna_client.cpp and the per area files split from it (the list
// is at the top of goanna_client.cpp), and included by nothing else: the
// headers they use, the timing helpers behind render_stats' numbers
// (ms_since, ema), the node surface format flags and the render layers, and
// the declarations of node_tangents (defined in goanna_client_near.cpp) and
// toColor (defined in goanna_client_light.cpp). Do not include it from
// another header; it is not part of GoannaClient's surface.
//
// Threads: the helpers hold no state, so any thread may call them.

#include "goanna_client.h"
#include "util/hashing.h"
#include "goanna_grass.h"
#include "goanna_lava.h"
#include "goanna_flame.h"
#include <sstream>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/array_occluder3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/occluder_instance3d.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "goanna_mesher.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "goanna_sky.h"
#include "itemdef.h"
#include "inventory.h"
#include "util/string.h"
#include "translation.h"
#include "transplant/localplayer.h"
#include "client/mapblock_mesh.h"
#include "client/tile.h"
#include "client/node_visuals.h"
#include "goanna_light.h"
#include "goanna_store.h"
#include "util/base64.h"
#include "light.h"
#include "client/texturepaths.h"
#include "nodedef.h"
#include "settings.h"
#include <SMesh.h>
#include <CMeshBuffer.h>
#include <SMaterial.h>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <functional>
#include <set>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "mapblock.h"
#include "version.h"
#include <chrono>
#include <godot_cpp/classes/rendering_server.hpp>
#include "goanna_mesh_flags.h"
#include "goanna_radial_form.h"
#include "itemgroup.h"
#include <godot_cpp/classes/quad_mesh.hpp>

namespace {
using clock_t_ = std::chrono::steady_clock;
inline double ms_since(const clock_t_::time_point &t0) {
    return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}
// Exponential moving average: one bad frame should show, but the number
// should still be readable.
inline void ema(double &acc, double sample) { acc = acc * 0.9 + sample * 0.1; }
// Every node surface declares CUSTOM0 as four unsigned bytes: block light,
// sky light, ambient occlusion, spare. RGBA8_UNORM happens to be format 0,
// so this constant is zero today; it is named rather than assumed.
const uint64_t kNodeSurfaceFlags =
        (uint64_t)godot::Mesh::ARRAY_CUSTOM_RGBA8_UNORM << godot::Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT;
// Light-emitting faces sit outside node lights' shadow caster mask. The sun
// still sees this layer.
const uint32_t GLOW_LAYER = 1u << 1;
const uint32_t ICE_LAYER = 1u << 2;
} // namespace

namespace goanna {

// Defined in goanna_client_near.cpp.
godot::PackedFloat32Array node_tangents(const godot::PackedVector3Array &verts,
        const godot::PackedVector3Array &norms, const godot::PackedVector2Array &uvs,
        const godot::PackedInt32Array &indices);
// Defined in goanna_client_light.cpp.
godot::Color toColor(const video::SColor &c);

} // namespace goanna
