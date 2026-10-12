// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A shader pack's geometry programs, translated (iris_gbuffers.h) and
// ready for GoannaClient to draw terrain and water with in place of the
// node array and water shaders, plus everything those translated shaders
// read that changes per frame: the Iris uniforms and fixed function
// matrices from the player's camera, the lightmap, the fog and the noise
// texture, all as Godot global shader parameters. docs/design/iris-compat.md,
// rungs 5 to 7, is the plan; GoannaIrisEffect runs the same pack's screen
// space chain beside it.
//
// Threads: one. main.gd makes it, loads the pack and hands it to the
// client before connecting, and calls update() every frame, all on the
// main thread; GoannaClient::materialFor reads its shaders and block
// numbers on the main thread too. Nothing here is touched from the session
// thread or the workers. While no pack is loaded none of this exists, and
// the client's own shaders are untouched.
//
// Main type: GoannaIrisGbuffers.
#pragma once

#include "iris/iris_gbuffers.h"
#include "iris/iris_pack.h"

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace goanna {

class GoannaIrisGbuffers : public godot::RefCounted {
    GDCLASS(GoannaIrisGbuffers, godot::RefCounted)

public:
    // Which surface a shader is for, as materialFor asks.
    // SURFACE_FOLIAGE is the single texture leaves and plants
    // (waving_leaves.gdshader, waving_plants.gdshader), drawn with the
    // cutout program.
    enum Surface { SURFACE_TERRAIN = 0, SURFACE_CUTOUT = 1, SURFACE_WATER = 2, SURFACE_FOLIAGE = 3, SURFACE_COUNT = 4 };

    // Translates the pack's terrain, cutout and water programs (each with
    // Iris's fallbacks) and registers the globals they read. True when at
    // least the terrain program translated. A program that fails leaves its
    // surface on Goanna's own shader; report() says why.
    bool load_pack(const godot::String &path);
    // The translated shader for a surface, or null when the pack has none.
    godot::Ref<godot::Shader> shader(int surface) const;
    bool has_terrain() const { return m_shaders[SURFACE_TERRAIN].is_valid(); }
    // The pack's block.properties number for each of the client's block
    // names (MaterialTable::block_names, UV2.y's table), -1 where it lists
    // none. Sized to the shell's goanna_iris_block_ids array.
    godot::PackedInt32Array block_ids(const godot::PackedStringArray &block_names) const;
    // The pack's number for one block name, or -1.
    int block_id(const godot::String &name) const;
    // Every frame, main thread. `state` carries what GoannaIrisEffect's
    // set_world_state takes (sun_direction, moon_direction, time_of_day,
    // in_water, sky_color, fog_color, rain) plus fog_start and fog_end, the
    // drawn distance the pack's fog should close at.
    void update(godot::Camera3D *camera, const godot::Dictionary &state);
    godot::Dictionary report() const;
    // Every colortex some translated program writes as a second output
    // (iris::GbuffersResult::second), ascending: the targets
    // project/game/effects/iris_targets.gd may draw for the chain.
    godot::PackedInt32Array second_targets() const;
    // Writes each translated shader to a directory, for debugging.
    void set_dump_dir(const godot::String &dir);

protected:
    static void _bind_methods();

private:
    void registerGlobal(const std::string &name, const std::string &type);
    void setGlobal(const char *name, const godot::Variant &v);
    void parseBlockProperties(const std::string &path);
    void makeTextures();
    void updateLightmap(float daylight, const godot::Color &sky);

    iris::Pack m_pack;
    godot::Ref<godot::Shader> m_shaders[SURFACE_COUNT];
    std::string m_program[SURFACE_COUNT];
    std::vector<std::string> m_warnings[SURFACE_COUNT];
    std::vector<int> m_dropped[SURFACE_COUNT];
    std::vector<int> m_second[SURFACE_COUNT];
    std::string m_error[SURFACE_COUNT];
    bool m_moves[SURFACE_COUNT] = {false, false, false, false};
    std::string m_load_error, m_dump_dir;
    // Godot global name -> type, for every global some program reads.
    std::map<std::string, std::string> m_globals;
    // block.properties: exact name and tag -> number
    std::map<std::string, int> m_block_ids;
    std::vector<std::pair<std::string, int>> m_block_tags;
    godot::Ref<godot::ImageTexture> m_lightmap, m_noise, m_white, m_black;
    uint64_t m_t0 = 0, m_last_us = 0;
    int m_frame = 0;
    float m_rain = 0.0f, m_wetness = 0.0f;
    godot::Projection m_prev_mv, m_prev_proj;
    // Every Iris uniform update() worked out this frame, by its Iris name,
    // for the custom uniforms to read whether or not a shader declares it.
    std::map<std::string, godot::Variant> m_builtin;
    iris::CustomUniforms m_custom;
    bool lookupBuiltin(const std::string &name, iris::Value &out) const;
    godot::Vector3 m_prev_cam;
};

} // namespace goanna
