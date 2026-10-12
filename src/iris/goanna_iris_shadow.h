// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// The capture half of a shader pack's own shadow map (docs/design/
// iris-compat.md, rung 7). main.gd draws the map with a SubViewport of the
// pack's shadowMapResolution and an orthographic Camera3D whose cull mask
// is GoannaIrisGbuffers::SHADOW_LAYER alone; the only surfaces on that
// layer are the shadow copies of the near terrain GoannaClient makes,
// drawn with the pack's translated shadow program. This CompositorEffect
// sits in that camera's Compositor and, after the scene is drawn, copies
// the viewport's depth and colour into textures of its own that outlive
// the frame: shadowtex0 as a depth texture (for a comparison sampler in the
// screen space chain) and as R32F (for Godot shaders, through a
// Texture2DRD), both in OpenGL's depth convention, and shadowcolor0 as
// RGBA16F. GoannaIrisEffect binds the first and the last on the render
// thread; GoannaIrisGbuffers hands the Texture2DRDs to the translated
// gbuffers programs as globals.
//
// Threads: two. The main thread makes it, puts it in the shadow camera's
// Compositor, calls sync() each frame and reads the Texture2DRDs. The
// render thread runs _render_callback, which builds every RID here, and
// GoannaIrisEffect reads those RIDs on the same thread. The two meet only
// in m_generation, which the render thread bumps (release) after the
// textures exist and sync() reads (acquire) before it reads their RIDs.
// The textures are made once, at the size of the first frame, and never
// remade, so a Texture2DRD never points at a freed one while the effect
// lives. They are freed at NOTIFICATION_PREDELETE, on the render thread,
// after the Texture2DRDs have let go of them.
//
// Main type: GoannaIrisShadow.
#pragma once

#include <godot_cpp/classes/compositor_effect.hpp>
#include <godot_cpp/classes/render_data.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <atomic>
#include <cstdint>

namespace goanna {

class GoannaIrisShadow : public godot::CompositorEffect {
    GDCLASS(GoannaIrisShadow, godot::CompositorEffect)

public:
    GoannaIrisShadow();
    ~GoannaIrisShadow() override;

    // Main thread, every frame: points the Texture2DRDs at the textures
    // once the render thread has made them. True once they are bound.
    bool sync();
    bool ready() const { return m_bound; }
    // shadowtex0 (R32F, OpenGL depth: 0 at the light's near plane, 1 where
    // nothing was drawn) and shadowcolor0, for Godot shaders. Valid from
    // construction; they show a placeholder until sync() returns true.
    godot::Ref<godot::Texture2DRD> shadowtex() const { return m_tex_depth; }
    godot::Ref<godot::Texture2DRD> shadowcolor() const { return m_tex_colour; }
    // How many frames the effect has copied, and its size, for tests and
    // report() in main.gd.
    godot::Dictionary report() const;

    // Render thread only: the depth format copy, for a comparison sampler
    // (and a plain one), and the colour, or invalid RIDs before the first
    // capture.
    godot::RID depth_rid() const { return m_depth; }
    godot::RID colour_rid() const { return m_colour; }

    void _render_callback(int32_t p_effect_callback_type, godot::RenderData *p_render_data) override;

protected:
    static void _bind_methods();
    void _notification(int p_what);

private:
    bool ensureGpu(godot::RenderingDevice *rd, const godot::Vector2i &size);
    void freeGpu();

    godot::Ref<godot::Texture2DRD> m_tex_depth, m_tex_colour;
    bool m_bound = false;
    uint32_t m_seen_generation = 0;

    // Render thread.
    godot::RID m_shader, m_pipeline, m_sampler, m_fb;
    godot::RID m_depth, m_depth_r32, m_colour;
    godot::Vector2i m_size;
    bool m_dead = false;
    std::atomic<uint32_t> m_generation{0};
    std::atomic<int64_t> m_captures{0};
    std::atomic<int32_t> m_width{0}, m_height{0};
};

} // namespace goanna
