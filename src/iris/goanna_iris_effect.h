// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Runs an Iris shader pack's screen space chain (deferred*, composite*,
// final) as a Godot CompositorEffect. Each program is translated to Vulkan
// GLSL by iris_glsl, compiled through RenderingDevice at first use on the
// render thread, and drawn as a full screen triangle into the colortex it
// declares with DRAWBUFFERS; final draws into the scene's colour buffer.
// The gbuffers programs are not run here; see docs/design/iris-compat.md.
//
// Depth reaches a pack in OpenGL's convention: Godot 4.5 stores reversed Z,
// so each frame the depth buffer is copied, inverted, into the texture a
// pack reads as depthtex0. depthtex1 (before translucent geometry) comes
// from a second instance of this class, made by make_depth_capture and put
// ahead of this one in the Compositor, which copies the depth buffer at
// PRE_TRANSPARENT into a named scene buffer texture this one then reads.
//
// Threads: two. main.gd, on the main thread, makes the effect, loads the
// pack and only then puts it in the Compositor, and feeds it world state
// every frame. Godot calls _render_callback on its rendering thread, which
// builds and uses every RID here. They are freed at NOTIFICATION_PREDELETE,
// when the last reference goes, by which time no Compositor holds the
// effect. Two things are touched by both threads while the effect is live,
// and each has a lock: the world state, and what report() prints of the
// compile (each pass's error and shader, m_gpu_ready, m_dead), which the
// render thread writes in ensureGpu. Whether the rendering thread is the
// main thread depends on Godot's thread model; when it is not, the lock is
// what keeps report() from reading a pass's error string while it is
// assigned. Main type:
// GoannaIrisEffect.
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

// One loaded pack and the GPU objects that run it. The pack and its
// translated passes are written by load_pack before the effect is attached
// and are read only after that, so they need no lock; load a new pack into
// a new effect rather than reloading a live one.
class GoannaIrisEffect : public godot::CompositorEffect {
    GDCLASS(GoannaIrisEffect, godot::CompositorEffect)

public:
    GoannaIrisEffect();
    ~GoannaIrisEffect() override;

    // Main thread. Parses and translates; no GPU work until the first frame.
    // GOANNA_SHADERPACK_OPTIONS (NAME=value, comma separated) overrides the
    // pack's option defaults. A pack that requires an Iris feature Goanna
    // does not supply is refused, with the reason in report().
    bool load_pack(const godot::String &path);
    // Main thread. The depth capture companion described above. It shares
    // nothing with this effect but the scene buffers, so it can be made at
    // any time; add it to the Compositor before this effect.
    godot::Ref<GoannaIrisEffect> make_depth_capture() const;
    godot::String pack_name() const;
    // What happened: programs found, passes built, per pass warnings and the
    // compile error if any. For printing from main.gd and for tests.
    godot::Dictionary report() const;
    // Main thread, every frame. The keys are sun_direction and
    // moon_direction as a Vector3, time_of_day (0..1, 0 midnight), rain
    // (0..1), in_water as an int, and sky_color and fog_color, which are
    // colours. Missing keys keep their previous value.
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
        std::string stage; // "deferred" or "composite" (final included), for texture.*
        iris::Translated tr;
        std::vector<std::string> zero_uniforms; // declared, but nothing supplies them
        godot::RID shader;
        godot::RID extra_ubo;
        std::vector<uint8_t> extra_data;
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

    struct CustomTexture {
        std::string key; // "noise", or "<stage>:<sampler>"
        int w = 0, h = 0;
        godot::PackedByteArray rgba;
        godot::RID tex;
    };

    bool ensureGpu(godot::RenderingDevice *rd);
    bool ensureBlit(godot::RenderingDevice *rd);
    void loadCustomTextures();
    void captureDepth(godot::RenderingDevice *rd, godot::RenderSceneBuffersRD *rb);
    godot::RID depthCopy(godot::RenderingDevice *rd, godot::RenderSceneBuffersRD *rb, const char *name,
            const godot::RID &src, const godot::Vector2i &size);
    void onCenterDepth(const godot::PackedByteArray &data);
    bool lookupBuiltin(const std::string &name, iris::Value &out) const;
    void evaluateCustom();
    void fillExtra(godot::RenderingDevice *rd, Pass &p);
    bool compilePass(godot::RenderingDevice *rd, Pass &p);
    godot::RID pipelineFor(godot::RenderingDevice *rd, Pass &p, int64_t fb_format, int attachments);
    void fillUniforms(godot::RenderData *rdata, const godot::Vector2i &size);
    godot::RID textureFor(const Pass &p, const iris::Translated::Sampler &s, godot::RenderSceneBuffersRD *rb,
            const godot::RID &depth0, const godot::RID &depth1, const std::array<int, 16> &side);
    godot::RID samplerFor(const Pass &p, const iris::Translated::Sampler &s) const;
    static bool knownExtra(const std::string &name);
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
    // True for the depth capture companion, which does nothing else.
    bool m_capture = false;
    std::vector<std::string> m_missing_features;
    std::vector<std::string> m_texture_notes;
    std::vector<CustomTexture> m_custom_tex;
    // Written on the main thread by load_pack, then evaluated only on the
    // render thread.
    iris::CustomUniforms m_custom;
    std::string m_dump_dir;
    bool m_labpbr = false;
    bool m_bridge_colour = true;

    // GPU state, render thread only, except that report() reads m_gpu_ready,
    // m_dead and each pass's error and shader from the main thread. Those
    // are written only in ensureGpu, under m_report_mutex, and report()
    // takes it too. freeGpu clears them at NOTIFICATION_PREDELETE, when
    // nothing can call report().
    mutable std::mutex m_report_mutex;
    bool m_gpu_ready = false;
    bool m_dead = false;
    // Names the custom uniforms read that nothing answered, copied once
    // from the first evaluation.
    std::vector<std::string> m_custom_unresolved;
    bool m_custom_reported = false;
    godot::RID m_ubo;
    godot::RID m_sampler_linear, m_sampler_nearest, m_sampler_repeat, m_sampler_nearest_repeat, m_sampler_shadow;
    godot::RID m_dummy_black, m_dummy_white, m_dummy_depth, m_dummy_shadow_depth, m_noise;
    // centerDepthSmooth: the centre pixel of depthtex0, copied to a 1x1
    // texture and read back asynchronously, then smoothed. The callback
    // runs on the render thread.
    godot::RID m_center_tex;
    bool m_center_pending = false;
    float m_center_raw = 1.0f, m_center_smooth = 1.0f;
    float m_dt = 0.0f;
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

    // m_world_mutex guards m_world: set_world_state writes it on the main
    // thread each frame and fillUniforms copies it out on the render thread.
    std::mutex m_world_mutex;
    World m_world;
};

} // namespace goanna
