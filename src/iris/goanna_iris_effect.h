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
// assigned. The second output textures (set_gbuffers_target) share the
// world state's lock. Main type:
// GoannaIrisEffect.
#pragma once

#include "iris/goanna_iris_shadow.h"
#include "iris/iris_pack.h"

#include <godot_cpp/classes/compositor_effect.hpp>
#include <godot_cpp/classes/render_data.hpp>
#include <godot_cpp/classes/render_scene_buffers_rd.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
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
    // The centre depth readback's state, shared with its callback (see
    // m_center below).
    struct CenterDepth {
        std::atomic<float> raw{1.0f};
        std::atomic<bool> pending{false};
    };

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
    // colours, and cloud_height, the world's cloud base for Iris's
    // cloudHeight (192, Minecraft's, until given). shadow_model_view and
    // shadow_projection, as Projections, are the pack's shadow matrices (GoannaIrisGbuffers::shadow_state);
    // without them the shadow matrices are the camera's. Missing keys keep
    // their previous value.
    void set_world_state(const godot::Dictionary &state);
    // Main thread, before the effect is attached: the pack's own shadow map
    // (rung 7), bound as shadowtex0, shadowtex1 and shadowcolor0 once it
    // has been drawn. Without one they are the lit dummies.
    void set_shadow(const godot::Ref<GoannaIrisShadow> &shadow);
    // Dump the translated GLSL for each pass into a directory, for debugging.
    void set_dump_dir(const godot::String &dir);
    // Colour bridge, on by default: native colour is encoded to sRGB;
    // translated geometry hands its pack values through raw. Final is decoded
    // back to linear. main.gd sets a linear tonemap to match while a pack
    // has a final program. Off hands the pack linear HDR and tonemaps after.
    void set_bridge_colour(bool on);
    bool get_bridge_colour() const;
    void set_gbuffers_colour_raw(bool on) { m_gbuffers_colour_raw = on; }
    bool has_final() const;
    // Whether any pass samples colortex `index`, so a geometry program's
    // output to it is worth drawing (project/game/effects/iris_targets.gd).
    bool reads_colortex(int index) const;
    // Main thread, every frame. A RenderingDevice texture holding what the
    // pack's geometry programs wrote to colortex `index` (a second output,
    // docs/design/iris-compat.md rung 6), copied into that colortex at the
    // start of the chain in place of the clear. An invalid RID goes back
    // to clearing.
    void set_gbuffers_target(int index, const godot::RID &texture);
    void set_gbuffers_low_target(int index, const godot::RID &texture);
    // That only translucent geometry writes colortex `index`
    // (GoannaIrisGbuffers::translucent_targets): the copy keeps it only
    // where depthtex0 is nearer than depthtex1, and elsewhere leaves the
    // clear, as a masked GL write would.
    void set_gbuffers_translucent(int index, bool translucent_only);

    // Gbuffers reads (docs/design/iris-compat.md, "Targets a geometry
    // program reads"). Main thread, once, after load_pack: the colortex
    // targets the pack's geometry programs sample (GoannaIrisGbuffers::
    // read_targets) and the target their colour goes to. Each gets a
    // texture of its own that the geometry programs read through a
    // Texture2DRD global:
    // Each receives the actual target after prepare/deferred, one frame
    // late. RGB outputs can carry depth or masks in alpha, so substituting
    // the native scene colour would corrupt the pack's geometry inputs.
    void set_gbuffers_reads(const godot::PackedInt32Array &targets, int colour_target);
    // Main thread, every frame: points the Texture2DRDs at the textures
    // once the render thread has made them. True once they are bound.
    bool sync_gbuffers_reads();
    // The texture for colortex `index`, null when it is not read.
    godot::Ref<godot::Texture2DRD> gbuffers_read_texture(int index) const;

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
        godot::Vector2i eye_light{-1, -1};
        // Goanna's cloud height (the server's set_clouds), for cloudHeight.
        float cloud_height = 192.0f;
        godot::Color sky{0.5f, 0.7f, 1.0f}, fog{0.7f, 0.8f, 0.9f};
        bool has_shadow = false;
        godot::Projection shadow_mv, shadow_proj;
    };

    struct CustomTexture {
        std::string key; // "noise", or "<stage>:<sampler>"
        int w = 0, h = 0;
        int depth = 0; // a 3D texture's depth; 0 for 2D
        godot::RenderingDevice::DataFormat format = godot::RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
        godot::PackedByteArray rgba; // the texels, in format
        godot::RID tex;
        // Whether it answers a sampler of this GLSL type: a 3D texture only
        // a sampler3D, a 2D one any other.
        bool fits(const std::string &type) const { return (depth > 0) == (type.find("3D") != std::string::npos); }
    };

    bool ensureGpu(godot::RenderingDevice *rd);
    bool ensureBlit(godot::RenderingDevice *rd);
    void loadCustomTextures();
    bool loadRawTexture(const std::string &value, CustomTexture &c, std::string &why) const;
    void captureDepth(godot::RenderingDevice *rd, godot::RenderSceneBuffersRD *rb);
    godot::RID depthCopy(godot::RenderingDevice *rd, godot::RenderSceneBuffersRD *rb, const char *name,
            const godot::RID &src, const godot::Vector2i &size);
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
    void blit(godot::RenderingDevice *rd, const godot::RID &src, const godot::RID &fb, int64_t fb_format, int mode,
            const godot::RID &depth0 = godot::RID(), const godot::RID &depth1 = godot::RID());
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
    bool m_gbuffers_colour_raw = false;
    // Set before the effect is attached, then only read.
    godot::Ref<GoannaIrisShadow> m_shadow;

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
    // texture and read back asynchronously, then smoothed. Godot runs the
    // readback's callback on the main thread a frame or more later, by
    // which time the effect may be freed, so the callback holds this
    // shared state rather than the effect, and the two threads meet only
    // in its atomics.
    std::shared_ptr<CenterDepth> m_center = std::make_shared<CenterDepth>();
    godot::RID m_center_tex;
    float m_center_smooth = 1.0f;
    float m_dt = 0.0f;
    godot::RID m_blit_shader;
    std::map<int64_t, godot::RID> m_blit_pipelines;
    std::vector<uint8_t> m_ubo_data;
    // colortex formats from the pack's consts, default RGBA8 except 0
    std::array<godot::RenderingDevice::DataFormat, 16> m_ct_format{};
    // ... and as the pack named them, RGBA8 where it names none
    std::array<std::string, 16> m_ct_format_name{};
    std::array<bool, 16> m_ct_used{};
    std::array<bool, 16> m_ct_clear{};
    std::array<int, 16> m_ct_side{}; // last written side, retained for history targets
    // size.buffer.colortexN from shaders.properties: a scale of the screen
    // (relative) or pixels, per axis; 0 means the screen's own size.
    struct BufferSize {
        bool relative = true;
        float x = 1.0f, y = 1.0f;
    };
    std::array<BufferSize, 16> m_ct_size{};
    godot::Vector2i colortexSize(int index, const godot::Vector2i &screen) const;
    // colortex a pass samples (not only writes)
    std::array<bool, 16> m_ct_read{};
    // The second outputs, set on the main thread by set_gbuffers_target and
    // read on the render thread, under m_world_mutex.
    std::array<godot::RID, 16> m_gb_source{}, m_gb_low{};
    std::array<bool, 16> m_gb_translucent{};
    uint64_t m_t0 = 0, m_last_us = 0;
    int m_frame = 0;
    // rainStrength ramps toward the world's precipitation and wetness
    // follows it more slowly, as Minecraft and Iris do; see fillUniforms.
    float m_rain_strength = 0.0f, m_wetness = 0.0f;
    godot::Vector2 m_eye_smooth;
    godot::Vector2i m_eye_light;
    bool m_eye_seen = false;
    float m_eye_half_seconds = 0.5f;
    godot::Transform3D m_prev_cam;
    godot::Projection m_prev_proj;

    // Gbuffers reads. `want` is written once on the main thread under
    // `mutex` and read
    // under it on the render thread. The mutex also guards published RIDs
    // and retired textures during main thread rebinding. Textures are made,
    // written and freed on the render thread (freed at NOTIFICATION_PREDELETE after
    // the Texture2DRDs let go), replaced when the viewport size changes;
    // `generation` is bumped (release) once they exist and read (acquire)
    // by sync_gbuffers_reads before it reads their RIDs.
    struct GbufferReads {
        std::mutex mutex;
        std::array<bool, 16> want{};
        std::array<godot::RID, 16> tex{};
        std::array<godot::Vector2i, 16> size{};
        std::vector<godot::RID> retired;
        std::atomic<uint32_t> generation{0};
    };
    std::shared_ptr<GbufferReads> m_reads = std::make_shared<GbufferReads>();
    std::array<godot::Ref<godot::Texture2DRD>, 16> m_read_tex;
    uint32_t m_read_seen = 0;
    bool m_read_bound = false;
    void ensureReads(godot::RenderingDevice *rd, const godot::Vector2i &screen);
    void snapshotReads(godot::RenderingDevice *rd, godot::RenderSceneBuffersRD *rb, const std::array<int, 16> &side,
            const godot::Vector2i &size);

    // m_world_mutex guards m_world: set_world_state writes it on the main
    // thread each frame and fillUniforms copies it out on the render thread.
    std::mutex m_world_mutex;
    World m_world;
};

} // namespace goanna
