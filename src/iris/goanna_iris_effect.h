// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Runs an Iris shader pack's screen space chain (deferred*, composite*,
// final) as a Godot CompositorEffect. Each program is translated to Vulkan
// GLSL by iris_glsl, compiled through RenderingDevice at first use on the
// render thread, and drawn as a full screen triangle into the colortex it
// declares with DRAWBUFFERS; final draws into the scene's colour buffer.
// The gbuffers programs are not run here; see docs/iris-compat.md.
#pragma once

#include "iris/iris_pack.h"

#include <godot_cpp/classes/compositor_effect.hpp>
#include <godot_cpp/classes/render_data.hpp>
#include <godot_cpp/classes/render_scene_buffers_rd.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace goanna {

class GoannaIrisEffect : public godot::CompositorEffect {
    GDCLASS(GoannaIrisEffect, godot::CompositorEffect)

public:
    GoannaIrisEffect();
    ~GoannaIrisEffect() override;

    // Main thread. Parses and translates; no GPU work until the first frame.
    bool load_pack(const godot::String &path);
    godot::String pack_name() const;
    // What happened: programs found, passes built, per pass warnings and the
    // compile error if any. For printing from main.gd and for tests.
    godot::Dictionary report() const;
    // Main thread, every frame: sun_direction, moon_direction (Vector3),
    // time_of_day (0..1, 0 midnight), rain (0..1), in_water (int), sky_color,
    // fog_color (Color). Missing keys keep their previous value.
    void set_world_state(const godot::Dictionary &state);
    // Dump the translated GLSL for each pass into a directory, for debugging.
    void set_dump_dir(const godot::String &dir);
    // Colour bridge, on by default: colortex0 receives Godot's colour encoded
    // to gamma space LDR as a pack expects, and final's output is decoded
    // back to linear. main.gd sets a linear tonemap to match while a pack
    // has a final program. Off hands the pack linear HDR and tonemaps after.
    void set_bridge_colour(bool on);
    bool get_bridge_colour() const;
    bool has_final() const;

    void _render_callback(int32_t p_effect_callback_type, godot::RenderData *p_render_data) override;

protected:
    static void _bind_methods();
    // GPU objects are released here, while the RenderingDevice still exists;
    // the destructor runs too late at shutdown.
    void _notification(int p_what);

private:
    struct Pass {
        std::string name;
        iris::Translated tr;
        godot::RID shader;
        godot::RID extra_ubo;
        std::map<int64_t, godot::RID> pipelines; // by framebuffer format
        std::string error;
        bool is_final = false;
    };
    struct World {
        godot::Vector3 sun{0, 1, 0}, moon{0, -1, 0};
        float tod = 0.5f, rain = 0.0f;
        int in_water = 0;
        godot::Color sky{0.5f, 0.7f, 1.0f}, fog{0.7f, 0.8f, 0.9f};
    };

    bool ensureGpu(godot::RenderingDevice *rd);
    bool compilePass(godot::RenderingDevice *rd, Pass &p);
    godot::RID pipelineFor(godot::RenderingDevice *rd, Pass &p, int64_t fb_format, int attachments);
    void fillUniforms(godot::RenderData *rdata, const godot::Vector2i &size);
    godot::RID textureFor(const std::string &name, godot::RenderSceneBuffersRD *rb, const godot::RID &colour,
            const godot::RID &depth, const std::array<int, 16> &side);
    godot::RID colortex(godot::RenderSceneBuffersRD *rb, int index, int side, const godot::Vector2i &size);
    void blit(godot::RenderingDevice *rd, const godot::RID &src, const godot::RID &fb, int64_t fb_format, int mode);
    godot::RID finalTarget(godot::RenderSceneBuffersRD *rb, const godot::Vector2i &size);
    void put(const char *name, const float *v, int count);
    void putInt(const char *name, const int *v, int count);
    void putMat4(const char *name, const godot::Projection &p);
    void putVec3(const char *name, const godot::Vector3 &v);
    void putFloat(const char *name, float v) { put(name, &v, 1); }
    void putInt1(const char *name, int v) { putInt(name, &v, 1); }
    void freeGpu();

    iris::Pack m_pack;
    std::vector<Pass> m_passes;
    std::string m_load_error;
    std::string m_dump_dir;
    bool m_labpbr = false;
    bool m_bridge_colour = true;

    // GPU state, render thread only
    bool m_gpu_ready = false;
    bool m_dead = false;
    godot::RID m_ubo;
    godot::RID m_sampler_linear, m_sampler_nearest, m_sampler_repeat;
    godot::RID m_dummy_black, m_dummy_white, m_dummy_depth, m_noise;
    godot::RID m_blit_shader;
    std::map<int64_t, godot::RID> m_blit_pipelines;
    std::vector<uint8_t> m_ubo_data;
    // colortex formats from the pack's consts, default RGBA8 except 0
    std::array<godot::RenderingDevice::DataFormat, 16> m_ct_format{};
    std::array<bool, 16> m_ct_used{};
    std::array<bool, 16> m_ct_clear{};
    uint64_t m_t0 = 0, m_last_us = 0;
    int m_frame = 0;
    // rainStrength ramps toward the world's precipitation and wetness
    // follows it more slowly, as Minecraft and Iris do; see fillUniforms.
    float m_rain_strength = 0.0f, m_wetness = 0.0f;
    godot::Transform3D m_prev_cam;
    godot::Projection m_prev_proj;

    std::mutex m_world_mutex;
    World m_world;
};

} // namespace goanna
