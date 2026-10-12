// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Copying the shadow camera's depth and colour into textures that outlive
// the frame. Thread rules are in goanna_iris_shadow.h; the design is in
// docs/design/iris-compat.md, rung 7.

#include "iris/goanna_iris_shadow.h"

#include <godot_cpp/classes/rd_pipeline_color_blend_state.hpp>
#include <godot_cpp/classes/rd_pipeline_color_blend_state_attachment.hpp>
#include <godot_cpp/classes/rd_pipeline_depth_stencil_state.hpp>
#include <godot_cpp/classes/rd_pipeline_multisample_state.hpp>
#include <godot_cpp/classes/rd_pipeline_rasterization_state.hpp>
#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/render_scene_buffers_rd.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/uniform_set_cache_rd.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_custom.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <utility>
#include <vector>

using namespace godot;

namespace goanna {

namespace {

const char *kCopyVertex =
        "#version 450\n"
        "void main() {\n"
        "    vec2 q = vec2(float((gl_VertexIndex & 1) << 1), float(gl_VertexIndex & 2));\n"
        "    gl_Position = vec4(q * 2.0 - 1.0, 0.0, 1.0);\n"
        "}\n";
// Godot's depth is reversed (1 at the near plane, 0 cleared); a pack's is
// OpenGL's window depth (0 near, 1 far and where nothing was drawn). The
// shell's goanna_shadow_position wrote depth as (w - z) / 2 of the pack's
// clip position, so one minus it is exactly the (z / w + 1) / 2 the pack
// computes for its own lookups. Rows are copied as they are: the pack's
// clip y and Vulkan's both put -1 at row 0, and a pack's lookup puts its
// v = 0 there too, so nothing is flipped.
const char *kCopyFragment =
        "#version 450\n"
        "layout(set = 0, binding = 0) uniform sampler2D depth_tex;\n"
        "layout(set = 0, binding = 1) uniform sampler2D colour_tex;\n"
        "layout(location = 0) out float out_depth;\n"
        "layout(location = 1) out vec4 out_colour;\n"
        "void main() {\n"
        "    ivec2 p = ivec2(gl_FragCoord.xy);\n"
        "    float d = clamp(1.0 - texelFetch(depth_tex, p, 0).r, 0.0, 1.0);\n"
        "    out_depth = d;\n"
        "    out_colour = texelFetch(colour_tex, p, 0);\n"
        "    gl_FragDepth = d;\n"
        "}\n";

// Frees RIDs on the render thread. It owns copies of them and nothing
// else, so it is safe to run after the effect is gone (the rule that came
// out of 19f48140: no callable bound to an object that can be freed first).
class FreeRids : public CallableCustom {
public:
    explicit FreeRids(std::vector<RID> rids) : m_rids(std::move(rids)) {}
    uint32_t hash() const override { return (uint32_t)(uintptr_t)this; }
    String get_as_text() const override { return "GoannaIrisShadow::FreeRids"; }
    static bool equal(const CallableCustom *a, const CallableCustom *b) { return a == b; }
    static bool less(const CallableCustom *a, const CallableCustom *b) { return a < b; }
    CompareEqualFunc get_compare_equal_func() const override { return &equal; }
    CompareLessFunc get_compare_less_func() const override { return &less; }
    bool is_valid() const override { return true; }
    ObjectID get_object() const override { return ObjectID(); }
    void call(const Variant **, int, Variant &, GDExtensionCallError &err) const override {
        err.error = GDEXTENSION_CALL_OK;
        RenderingServer *rs = RenderingServer::get_singleton();
        RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
        if (!rd) return;
        for (const RID &r : m_rids)
            if (r.is_valid()) rd->free_rid(r);
    }

private:
    std::vector<RID> m_rids;
};

RID makeTexture(RenderingDevice *rd, const Vector2i &size, RenderingDevice::DataFormat format, uint32_t usage) {
    Ref<RDTextureFormat> tf;
    tf.instantiate();
    tf->set_width(size.x);
    tf->set_height(size.y);
    tf->set_format(format);
    tf->set_usage_bits(usage);
    Ref<RDTextureView> tv;
    tv.instantiate();
    return rd->texture_create(tf, tv);
}

} // namespace

GoannaIrisShadow::GoannaIrisShadow() {
    set_effect_callback_type(EFFECT_CALLBACK_TYPE_POST_TRANSPARENT);
    m_tex_depth.instantiate();
    m_tex_colour.instantiate();
}

GoannaIrisShadow::~GoannaIrisShadow() { freeGpu(); }

void GoannaIrisShadow::_bind_methods() {
    ClassDB::bind_method(D_METHOD("sync"), &GoannaIrisShadow::sync);
    ClassDB::bind_method(D_METHOD("ready"), &GoannaIrisShadow::ready);
    ClassDB::bind_method(D_METHOD("shadowtex"), &GoannaIrisShadow::shadowtex);
    ClassDB::bind_method(D_METHOD("shadowcolor"), &GoannaIrisShadow::shadowcolor);
    ClassDB::bind_method(D_METHOD("report"), &GoannaIrisShadow::report);
}

void GoannaIrisShadow::_notification(int p_what) {
    if (p_what == NOTIFICATION_PREDELETE) freeGpu();
}

bool GoannaIrisShadow::sync() {
    const uint32_t g = m_generation.load(std::memory_order_acquire);
    if (g == 0 || g == m_seen_generation) return m_bound;
    m_seen_generation = g;
    // Written by the render thread before the release above; never
    // changed again while the effect lives.
    m_tex_depth->set_texture_rd_rid(m_depth_r32);
    m_tex_colour->set_texture_rd_rid(m_colour);
    m_bound = true;
    return true;
}

Dictionary GoannaIrisShadow::report() const {
    Dictionary d;
    d["captures"] = (int64_t)m_captures.load();
    d["width"] = (int)m_width.load();
    d["height"] = (int)m_height.load();
    d["bound"] = m_bound;
    return d;
}

bool GoannaIrisShadow::ensureGpu(RenderingDevice *rd, const Vector2i &size) {
    if (m_fb.is_valid()) return true;
    if (m_dead) return false;
    Ref<RDShaderSource> src;
    src.instantiate();
    src->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
    src->set_stage_source(RenderingDevice::SHADER_STAGE_VERTEX, kCopyVertex);
    src->set_stage_source(RenderingDevice::SHADER_STAGE_FRAGMENT, kCopyFragment);
    Ref<RDShaderSPIRV> spirv = rd->shader_compile_spirv_from_source(src, false);
    if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_VERTEX).is_empty() ||
            !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_FRAGMENT).is_empty()) {
        UtilityFunctions::push_error("Goanna Iris shadow: copy shader failed: ",
                spirv.is_valid() ? spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_FRAGMENT) : String());
        m_dead = true;
        return false;
    }
    m_shader = rd->shader_create_from_spirv(spirv, "goanna_iris_shadow_copy");
    if (!m_shader.is_valid()) {
        m_dead = true;
        return false;
    }
    Ref<RDSamplerState> ss;
    ss.instantiate();
    ss->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    ss->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    ss->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    ss->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    m_sampler = rd->sampler_create(ss);

    const uint32_t colour_usage =
            RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;
    m_depth_r32 = makeTexture(rd, size, RenderingDevice::DATA_FORMAT_R32_SFLOAT, colour_usage);
    m_colour = makeTexture(rd, size, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT, colour_usage);
    m_depth = makeTexture(rd, size, RenderingDevice::DATA_FORMAT_D32_SFLOAT,
            RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
    TypedArray<RID> atts;
    atts.push_back(m_depth_r32);
    atts.push_back(m_colour);
    atts.push_back(m_depth);
    m_fb = rd->framebuffer_create(atts);
    if (!m_fb.is_valid()) {
        UtilityFunctions::push_error("Goanna Iris shadow: framebuffer failed");
        m_dead = true;
        return false;
    }
    Ref<RDPipelineRasterizationState> rs;
    rs.instantiate();
    rs->set_cull_mode(RenderingDevice::POLYGON_CULL_DISABLED);
    Ref<RDPipelineMultisampleState> ms;
    ms.instantiate();
    Ref<RDPipelineDepthStencilState> ds;
    ds.instantiate();
    ds->set_enable_depth_test(true);
    ds->set_enable_depth_write(true);
    ds->set_depth_compare_operator(RenderingDevice::COMPARE_OP_ALWAYS);
    Ref<RDPipelineColorBlendState> bs;
    bs.instantiate();
    TypedArray<RDPipelineColorBlendStateAttachment> blends;
    for (int i = 0; i < 2; ++i) {
        Ref<RDPipelineColorBlendStateAttachment> a;
        a.instantiate();
        blends.push_back(a);
    }
    bs->set_attachments(blends);
    m_pipeline = rd->render_pipeline_create(m_shader, rd->framebuffer_get_format(m_fb),
            RenderingDevice::INVALID_FORMAT_ID, RenderingDevice::RENDER_PRIMITIVE_TRIANGLES, rs, ms, ds, bs);
    if (!m_pipeline.is_valid()) {
        UtilityFunctions::push_error("Goanna Iris shadow: pipeline failed");
        m_dead = true;
        return false;
    }
    m_size = size;
    m_width.store(size.x);
    m_height.store(size.y);
    m_generation.fetch_add(1, std::memory_order_release);
    return true;
}

void GoannaIrisShadow::_render_callback(int32_t p_type, RenderData *p_render_data) {
    if (p_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT || !p_render_data || m_dead) return;
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    if (!rd) return;
    Ref<RenderSceneBuffersRD> rb = p_render_data->get_render_scene_buffers();
    if (rb.is_null() || rb->get_view_count() != 1) return;
    const Vector2i size = rb->get_internal_size();
    RID depth = rb->get_depth_texture();
    RID colour = rb->get_color_texture();
    if (!depth.is_valid() || !colour.is_valid() || size.x <= 0 || size.y <= 0) return;
    if (!ensureGpu(rd, size)) return;
    if (size != m_size) {
        // Made once; see the header. The shadow viewport's size is fixed.
        static bool warned = false;
        if (!warned) {
            UtilityFunctions::push_warning("Goanna Iris shadow: the shadow viewport changed size; not copied");
            warned = true;
        }
        return;
    }
    TypedArray<RDUniform> us;
    RID srcs[2] = {depth, colour};
    for (int i = 0; i < 2; ++i) {
        Ref<RDUniform> u;
        u.instantiate();
        u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
        u->set_binding(i);
        u->add_id(m_sampler);
        u->add_id(srcs[i]);
        us.push_back(u);
    }
    RID set = UniformSetCacheRD::get_cache(m_shader, 0, us);
    int64_t dl = rd->draw_list_begin(m_fb);
    rd->draw_list_bind_render_pipeline(dl, m_pipeline);
    rd->draw_list_bind_uniform_set(dl, set, 0);
    rd->draw_list_draw(dl, false, 1, 3);
    rd->draw_list_end();
    m_captures.fetch_add(1);
}

void GoannaIrisShadow::freeGpu() {
    if (m_tex_depth.is_valid()) m_tex_depth->set_texture_rd_rid(RID());
    if (m_tex_colour.is_valid()) m_tex_colour->set_texture_rd_rid(RID());
    m_bound = false;
    std::vector<RID> rids = {m_pipeline, m_fb, m_depth_r32, m_colour, m_depth, m_sampler, m_shader};
    m_pipeline = m_fb = m_depth_r32 = m_colour = m_depth = m_sampler = m_shader = RID();
    bool any = false;
    for (auto &r : rids) any = any || r.is_valid();
    if (!any) return;
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs) return;
    // After the Texture2DRDs' own release, which they queue on the render
    // thread too.
    rs->call_on_render_thread(Callable(memnew(FreeRids(std::move(rids)))));
}

} // namespace goanna
