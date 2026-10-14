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

#include "iris/goanna_iris_effect.h"
#include "iris/iris_gbuffers.h"
#include "iris/goanna_iris_shadow.h"
#include "iris/iris_pack.h"
#include "iris/iris_shadow.h"

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
    enum Surface { SURFACE_TERRAIN = 0, SURFACE_CUTOUT = 1, SURFACE_WATER = 2, SURFACE_FOLIAGE = 3,
            SURFACE_SKY = 4, SURFACE_SKY_TEXTURED = 5, SURFACE_COUNT = 6 };

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
    // in_water, sky_color, fog_color, rain, cloud_height) plus fog_start and
    // fog_end, the drawn distance the pack's fog should close at.
    void update(godot::Camera3D *camera, const godot::Dictionary &state);
    godot::Dictionary report() const;
    godot::Dictionary lighting_state() const;
    // Every colortex some translated program writes as a second output
    // (iris::GbuffersResult::second), ascending: the targets
    // project/game/effects/iris_targets.gd may draw for the chain.
    godot::PackedInt32Array second_targets() const;
    bool packed_target(int index) const { return m_packed_targets.count(index) > 0; }
    // Of those, the ones only the water program writes. Opaque terrain in
    // their second output pass writes zero with Godot's opaque alpha of 1,
    // where Minecraft's masked write leaves the target clear; the chain
    // keeps such a target only where translucent geometry is in front
    // (GoannaIrisEffect::set_gbuffers_translucent).
    godot::PackedInt32Array translucent_targets() const;
    // Every colortex some translated program samples
    // (iris::GbuffersResult::reads), ascending, and the target the terrain
    // program's colour goes to.
    godot::PackedInt32Array read_targets() const;
    int colour_target() const { return m_colour_target; }
    // Main thread, once, after both halves of the pack have loaded: hands
    // the chain the targets the programs read (GoannaIrisEffect::
    // set_gbuffers_reads) and keeps it, so update() can point the
    // iris_colortex<N> globals at its copies. Until then they read black.
    void link_chain(const godot::Ref<GoannaIrisEffect> &chain);
    // Writes each translated shader to a directory, for debugging.
    void set_dump_dir(const godot::String &dir);

    // The pack's own shadow map (docs/design/iris-compat.md, rung 7). The
    // shadow program is translated once per surface it can be drawn on
    // (SURFACE_TERRAIN, SURFACE_CUTOUT, SURFACE_FOLIAGE); GoannaClient
    // draws a copy of each near terrain mesh with it on SHADOW_LAYER, and
    // main.gd's shadow camera sees that layer alone. update() works out the
    // pack's shadow matrices each frame and sets them for every program.
    // Render layer 13: clear of NODE_SURFACE_LAYER (bit 14) and of the
    // second output pass bits (iris::kGbuffersPassShift, 15 to 19), which
    // every camera must keep all set or all clear.
    static constexpr uint32_t SHADOW_LAYER = 1u << 12;
    bool has_shadow() const { return m_shadow_shaders[SURFACE_TERRAIN].is_valid(); }
    godot::Ref<godot::Shader> shadow_shader(int surface) const;
    int shadow_resolution() const { return m_shadow_settings.resolution; }
    float sun_path_rotation() const { return m_shadow_settings.sun_path_rotation; }
    int shadow_layer() const { return (int)SHADOW_LAYER; }
    // The capture GoannaIrisShadow, whose textures update() hands the
    // gbuffers programs as shadowtex0, shadowtex1 and shadowcolor0 once
    // they exist. Main thread, before the first update().
    void set_shadow(const godot::Ref<GoannaIrisShadow> &shadow);
    // This frame's shadow space, after update(): shadow_model_view and
    // shadow_projection (Projections, for GoannaIrisEffect's
    // set_world_state), and for main.gd's shadow camera camera_transform
    // (the light's eye, looking down -z), size (the box's side), near and
    // far. Empty without a shadow program.
    godot::Dictionary shadow_state() const;

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
    std::vector<int> m_reads[SURFACE_COUNT];
    int m_colour_target = 0;
    std::set<int> m_packed_targets;
    godot::Ref<GoannaIrisEffect> m_chain;
    bool m_chain_bound = false;
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
    godot::Vector2 m_eye_smooth;
    godot::Vector2i m_eye_light;
    bool m_eye_seen = false;
    float m_eye_half_seconds = 0.5f;
    godot::Projection m_prev_mv, m_prev_proj;
    // Every Iris uniform update() worked out this frame, by its Iris name,
    // for the custom uniforms to read whether or not a shader declares it.
    std::map<std::string, godot::Variant> m_builtin;
    iris::CustomUniforms m_custom;
    bool lookupBuiltin(const std::string &name, iris::Value &out) const;
    godot::Vector3 m_prev_cam;

    // Rung 7: the shadow program and its frame state.
    void loadShadow(const iris::GbuffersOptions &base);
    void updateShadow(const godot::Vector3 &camera, const godot::Vector3 &light);
    godot::Ref<godot::Shader> m_shadow_shaders[SURFACE_COUNT];
    std::string m_shadow_program, m_shadow_error;
    std::vector<std::string> m_shadow_warnings;
    iris::ShadowSettings m_shadow_settings;
    godot::Ref<GoannaIrisShadow> m_shadow;
    godot::Projection m_shadow_mv, m_shadow_proj;
    godot::Transform3D m_shadow_eye;
};

} // namespace goanna
