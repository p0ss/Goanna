// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "iris/goanna_iris_effect.h"

#include <godot_cpp/classes/framebuffer_cache_rd.hpp>
#include <godot_cpp/classes/rd_framebuffer_pass.hpp>
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
#include <godot_cpp/classes/render_scene_data.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/uniform_set_cache_rd.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

using namespace godot;

namespace goanna {

namespace {

RenderingDevice::DataFormat formatFromIris(const std::string &name, RenderingDevice::DataFormat dflt) {
    static const std::pair<const char *, RenderingDevice::DataFormat> table[] = {
        {"R8", RenderingDevice::DATA_FORMAT_R8_UNORM}, {"RG8", RenderingDevice::DATA_FORMAT_R8G8_UNORM},
        {"RGB8", RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM}, {"RGBA8", RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM},
        {"RGBA8_SNORM", RenderingDevice::DATA_FORMAT_R8G8B8A8_SNORM},
        {"R16", RenderingDevice::DATA_FORMAT_R16_UNORM}, {"RG16", RenderingDevice::DATA_FORMAT_R16G16_UNORM},
        {"RGB16", RenderingDevice::DATA_FORMAT_R16G16B16A16_UNORM}, {"RGBA16", RenderingDevice::DATA_FORMAT_R16G16B16A16_UNORM},
        {"R16F", RenderingDevice::DATA_FORMAT_R16_SFLOAT}, {"RG16F", RenderingDevice::DATA_FORMAT_R16G16_SFLOAT},
        {"RGB16F", RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT}, {"RGBA16F", RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT},
        {"R32F", RenderingDevice::DATA_FORMAT_R32_SFLOAT}, {"RG32F", RenderingDevice::DATA_FORMAT_R32G32_SFLOAT},
        {"RGB32F", RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT}, {"RGBA32F", RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT},
        {"R11F_G11F_B10F", RenderingDevice::DATA_FORMAT_B10G11R11_UFLOAT_PACK32},
        {"RGB10_A2", RenderingDevice::DATA_FORMAT_A2B10G10R10_UNORM_PACK32},
    };
    for (auto &e : table)
        if (name == e.first)
            return e.second;
    return dflt;
}

const char *kBlitVertex =
        "#version 450\n"
        "layout(location = 0) out vec2 uv;\n"
        "void main() {\n"
        "    vec2 q = vec2(float((gl_VertexIndex & 1) << 1), float(gl_VertexIndex & 2));\n"
        "    uv = q;\n"
        "    gl_Position = vec4(q * 2.0 - 1.0, 0.0, 1.0);\n"
        "}\n";
// mode 0 copies. mode 1 encodes Godot's linear HDR colour into the gamma
// space LDR a pack expects to find in colortex0, as Minecraft's framebuffer
// holds. mode 2 decodes a pack's finished image back to linear for Godot's
// output stage, which main.gd sets to a linear tonemap while a pack owns
// final. Packs do their own exposure and tonemapping; handing them HDR and
// then tonemapping their result again is how a pack looks washed out.
const char *kBlitFragment =
        "#version 450\n"
        "layout(set = 0, binding = 0) uniform sampler2D src;\n"
        "layout(push_constant, std430) uniform Params { int mode; int pad0; int pad1; int pad2; } params;\n"
        "layout(location = 0) in vec2 uv;\n"
        "layout(location = 0) out vec4 o;\n"
        "void main() {\n"
        "    vec4 c = texture(src, uv);\n"
        "    if (params.mode == 1) c.rgb = pow(clamp(c.rgb, vec3(0.0), vec3(1.0)), vec3(1.0 / 2.2));\n"
        "    else if (params.mode == 2) c.rgb = pow(max(c.rgb, vec3(0.0)), vec3(2.2));\n"
        "    o = c;\n"
        "}\n";

RID makeTexture(RenderingDevice *rd, int w, int h, RenderingDevice::DataFormat fmt, const PackedByteArray &data) {
    Ref<RDTextureFormat> tf;
    tf.instantiate();
    tf->set_width(w);
    tf->set_height(h);
    tf->set_format(fmt);
    tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
    tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
            RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT);
    Ref<RDTextureView> tv;
    tv.instantiate();
    TypedArray<PackedByteArray> arr;
    arr.push_back(data);
    return rd->texture_create(tf, tv, arr);
}

RID compileGlsl(RenderingDevice *rd, const std::string &vs, const std::string &fs, const String &name, std::string &err) {
    Ref<RDShaderSource> src;
    src.instantiate();
    src->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
    src->set_stage_source(RenderingDevice::SHADER_STAGE_VERTEX, String::utf8(vs.c_str()));
    src->set_stage_source(RenderingDevice::SHADER_STAGE_FRAGMENT, String::utf8(fs.c_str()));
    Ref<RDShaderSPIRV> spirv = rd->shader_compile_spirv_from_source(src, false);
    if (spirv.is_null()) {
        err = "shader_compile_spirv_from_source returned null";
        return RID();
    }
    String e1 = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_VERTEX);
    String e2 = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_FRAGMENT);
    if (!e1.is_empty() || !e2.is_empty()) {
        err = std::string("vertex: ") + e1.utf8().get_data() + "\nfragment: " + e2.utf8().get_data();
        return RID();
    }
    RID shader = rd->shader_create_from_spirv(spirv, name);
    if (!shader.is_valid())
        err = "shader_create_from_spirv failed";
    return shader;
}

} // namespace

GoannaIrisEffect::GoannaIrisEffect() {
    set_effect_callback_type(EFFECT_CALLBACK_TYPE_POST_TRANSPARENT);
    m_ubo_data.assign(iris::standardLayout().paddedSize(), 0);
    for (auto &f : m_ct_format)
        f = RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
    for (auto &c : m_ct_clear)
        c = true;
}

GoannaIrisEffect::~GoannaIrisEffect() {
    freeGpu();
}

void GoannaIrisEffect::_notification(int p_what) {
    if (p_what == NOTIFICATION_PREDELETE)
        freeGpu();
}

void GoannaIrisEffect::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_pack", "path"), &GoannaIrisEffect::load_pack);
    ClassDB::bind_method(D_METHOD("pack_name"), &GoannaIrisEffect::pack_name);
    ClassDB::bind_method(D_METHOD("report"), &GoannaIrisEffect::report);
    ClassDB::bind_method(D_METHOD("set_world_state", "state"), &GoannaIrisEffect::set_world_state);
    ClassDB::bind_method(D_METHOD("set_dump_dir", "dir"), &GoannaIrisEffect::set_dump_dir);
    ClassDB::bind_method(D_METHOD("set_bridge_colour", "on"), &GoannaIrisEffect::set_bridge_colour);
    ClassDB::bind_method(D_METHOD("get_bridge_colour"), &GoannaIrisEffect::get_bridge_colour);
    ClassDB::bind_method(D_METHOD("has_final"), &GoannaIrisEffect::has_final);
}

// ---------------------------------------------------------------------------
// Main thread

bool GoannaIrisEffect::load_pack(const String &path) {
    m_passes.clear();
    m_load_error.clear();
    std::string err;
    if (!m_pack.load(path.utf8().get_data(), err)) {
        m_load_error = err;
        UtilityFunctions::push_error(String("Goanna Iris: ") + err.c_str());
        return false;
    }
    // colortex formats and clear flags from the pack's const directives.
    // Without the colour bridge colortex0 carries Godot's HDR colour, so its
    // default widens from RGBA8 to RGBA16F unless the pack says otherwise.
    if (!m_bridge_colour)
        m_ct_format[0] = RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT;
    for (int i = 0; i < 16; ++i) {
        auto f = m_pack.consts().find("colortex" + std::to_string(i) + "Format");
        if (f != m_pack.consts().end())
            m_ct_format[i] = formatFromIris(f->second, m_ct_format[i]);
        auto c = m_pack.consts().find("colortex" + std::to_string(i) + "Clear");
        if (c != m_pack.consts().end())
            m_ct_clear[i] = c->second != "false";
    }
    iris::TranslateOptions opts;
    opts.kind = iris::ProgramKind::Composite;
    opts.labpbr = m_labpbr;
    for (auto &name : m_pack.compositeChain()) {
        iris::Program prog;
        std::string perr;
        Pass pass;
        pass.name = name;
        pass.is_final = name == "final";
        if (!m_pack.program(name, prog, perr)) {
            pass.error = perr;
            m_passes.push_back(pass);
            continue;
        }
        if (!iris::translate(prog, opts, pass.tr, perr))
            pass.error = perr;
        for (auto &s : pass.tr.samplers)
            if (s.name.rfind("colortex", 0) == 0)
                m_ct_used[std::atoi(s.name.c_str() + 8)] = true;
        for (int d : pass.tr.drawbuffers)
            if (d >= 0 && d < 16)
                m_ct_used[d] = true;
        if (!pass.is_final && pass.tr.drawbuffers.empty())
            m_ct_used[0] = true;
        if (!m_dump_dir.empty()) {
            std::ofstream(m_dump_dir + "/" + name + ".vert.glsl") << pass.tr.vertex;
            std::ofstream(m_dump_dir + "/" + name + ".frag.glsl") << pass.tr.fragment;
        }
        m_passes.push_back(pass);
    }
    m_ct_used[0] = true;
    if (m_passes.empty()) {
        m_load_error = "pack has no deferred, composite or final program";
        UtilityFunctions::push_error(String("Goanna Iris: ") + m_load_error.c_str());
        return false;
    }
    return true;
}

String GoannaIrisEffect::pack_name() const {
    return String::utf8(m_pack.name().c_str());
}

Dictionary GoannaIrisEffect::report() const {
    Dictionary d;
    d["pack"] = pack_name();
    d["load_error"] = String::utf8(m_load_error.c_str());
    Array programs;
    for (auto &p : m_pack.programNames())
        programs.push_back(String::utf8(p.c_str()));
    d["programs"] = programs;
    Array passes;
    for (auto &p : m_passes) {
        Dictionary pd;
        pd["name"] = String::utf8(p.name.c_str());
        pd["error"] = String::utf8(p.error.c_str());
        pd["compiled"] = p.shader.is_valid();
        Array w;
        for (auto &s : p.tr.warnings)
            w.push_back(String::utf8(s.c_str()));
        pd["warnings"] = w;
        Array db;
        for (int i : p.tr.drawbuffers)
            db.push_back(i);
        pd["drawbuffers"] = db;
        Array sm;
        for (auto &s : p.tr.samplers)
            sm.push_back(String::utf8(s.name.c_str()));
        pd["samplers"] = sm;
        passes.push_back(pd);
    }
    d["passes"] = passes;
    d["gpu_ready"] = m_gpu_ready;
    d["dead"] = m_dead;
    return d;
}

void GoannaIrisEffect::set_world_state(const Dictionary &s) {
    std::lock_guard<std::mutex> lk(m_world_mutex);
    if (s.has("sun_direction")) m_world.sun = s["sun_direction"];
    if (s.has("moon_direction")) m_world.moon = s["moon_direction"];
    if (s.has("time_of_day")) m_world.tod = (float)(double)s["time_of_day"];
    if (s.has("rain")) m_world.rain = (float)(double)s["rain"];
    if (s.has("in_water")) m_world.in_water = (int)s["in_water"];
    if (s.has("sky_color")) m_world.sky = s["sky_color"];
    if (s.has("fog_color")) m_world.fog = s["fog_color"];
}

void GoannaIrisEffect::set_dump_dir(const String &dir) {
    m_dump_dir = dir.utf8().get_data();
}

// ---------------------------------------------------------------------------
// Render thread

bool GoannaIrisEffect::ensureGpu(RenderingDevice *rd) {
    if (m_gpu_ready)
        return true;
    std::string err;
    m_blit_shader = compileGlsl(rd, kBlitVertex, kBlitFragment, "goanna_iris_blit", err);
    if (!m_blit_shader.is_valid()) {
        UtilityFunctions::push_error(String("Goanna Iris: blit shader failed: ") + err.c_str());
        m_dead = true;
        return false;
    }
    Ref<RDSamplerState> ss;
    ss.instantiate();
    ss->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    ss->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    ss->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    ss->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    m_sampler_linear = rd->sampler_create(ss);
    Ref<RDSamplerState> sn;
    sn.instantiate();
    sn->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    sn->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    sn->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    sn->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    m_sampler_nearest = rd->sampler_create(sn);
    Ref<RDSamplerState> sr;
    sr.instantiate();
    sr->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sr->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sr->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    sr->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    m_sampler_repeat = rd->sampler_create(sr);

    PackedByteArray black;
    black.resize(4);
    m_dummy_black = makeTexture(rd, 1, 1, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, black);
    PackedByteArray white;
    white.resize(4);
    white.fill(255);
    m_dummy_white = makeTexture(rd, 1, 1, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, white);
    PackedByteArray one;
    one.resize(4);
    float f1 = 1.0f;
    std::memcpy(one.ptrw(), &f1, 4);
    m_dummy_depth = makeTexture(rd, 1, 1, RenderingDevice::DATA_FORMAT_R32_SFLOAT, one);
    // noisetex: Iris supplies 256x256 of uniform noise unless the pack ships
    // its own. A fixed seed so frames are repeatable.
    {
        int res = 256;
        auto it = m_pack.consts().find("noiseTextureResolution");
        if (it != m_pack.consts().end())
            res = std::max(1, std::min(4096, std::atoi(it->second.c_str())));
        PackedByteArray noise;
        noise.resize(res * res * 4);
        uint32_t s = 0x9E3779B9u;
        uint8_t *w = noise.ptrw();
        for (int i = 0; i < res * res * 4; ++i) {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            w[i] = (uint8_t)(s & 0xff);
        }
        m_noise = makeTexture(rd, res, res, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, noise);
    }
    PackedByteArray zero;
    zero.resize(m_ubo_data.size());
    m_ubo = rd->uniform_buffer_create(m_ubo_data.size(), zero);

    int ok = 0;
    for (auto &p : m_passes) {
        if (!p.error.empty())
            continue;
        if (compilePass(rd, p))
            ++ok;
    }
    m_t0 = Time::get_singleton()->get_ticks_usec();
    m_last_us = m_t0;
    m_gpu_ready = true;
    if (ok == 0) {
        UtilityFunctions::push_error("Goanna Iris: no pass compiled, effect disabled");
        m_dead = true;
        return false;
    }
    UtilityFunctions::print(String("Goanna Iris: ") + pack_name() + " ready, " + String::num_int64(ok) + " of " +
            String::num_int64(m_passes.size()) + " passes compiled");
    return true;
}

bool GoannaIrisEffect::compilePass(RenderingDevice *rd, Pass &p) {
    std::string err;
    p.shader = compileGlsl(rd, p.tr.vertex, p.tr.fragment, String::utf8(("goanna_iris_" + p.name).c_str()), err);
    if (!p.shader.is_valid()) {
        p.error = err;
        UtilityFunctions::push_error(String("Goanna Iris: ") + p.name.c_str() + " failed to compile:\n" + err.c_str());
        return false;
    }
    if (!p.tr.extra.members.empty()) {
        PackedByteArray zero;
        zero.resize(p.tr.extra.paddedSize());
        p.extra_ubo = rd->uniform_buffer_create(p.tr.extra.paddedSize(), zero);
    }
    return true;
}

RID GoannaIrisEffect::pipelineFor(RenderingDevice *rd, Pass &p, int64_t fb_format, int attachments) {
    auto it = p.pipelines.find(fb_format);
    if (it != p.pipelines.end())
        return it->second;
    Ref<RDPipelineRasterizationState> rs;
    rs.instantiate();
    rs->set_cull_mode(RenderingDevice::POLYGON_CULL_DISABLED);
    Ref<RDPipelineMultisampleState> ms;
    ms.instantiate();
    Ref<RDPipelineDepthStencilState> ds;
    ds.instantiate();
    Ref<RDPipelineColorBlendState> bs;
    bs.instantiate();
    TypedArray<RDPipelineColorBlendStateAttachment> atts;
    for (int i = 0; i < attachments; ++i) {
        Ref<RDPipelineColorBlendStateAttachment> a;
        a.instantiate();
        a->set_enable_blend(false);
        atts.push_back(a);
    }
    bs->set_attachments(atts);
    RID pipe = rd->render_pipeline_create(p.shader, fb_format, RenderingDevice::INVALID_FORMAT_ID,
            RenderingDevice::RENDER_PRIMITIVE_TRIANGLES, rs, ms, ds, bs);
    p.pipelines[fb_format] = pipe;
    return pipe;
}

void GoannaIrisEffect::blit(RenderingDevice *rd, const RID &src, const RID &fb, int64_t fb_format, int mode) {
    RID pipe;
    auto it = m_blit_pipelines.find(fb_format);
    if (it != m_blit_pipelines.end()) {
        pipe = it->second;
    } else {
        Ref<RDPipelineRasterizationState> rs;
        rs.instantiate();
        rs->set_cull_mode(RenderingDevice::POLYGON_CULL_DISABLED);
        Ref<RDPipelineMultisampleState> ms;
        ms.instantiate();
        Ref<RDPipelineDepthStencilState> ds;
        ds.instantiate();
        Ref<RDPipelineColorBlendState> bs;
        bs.instantiate();
        TypedArray<RDPipelineColorBlendStateAttachment> atts;
        Ref<RDPipelineColorBlendStateAttachment> a;
        a.instantiate();
        atts.push_back(a);
        bs->set_attachments(atts);
        pipe = rd->render_pipeline_create(m_blit_shader, fb_format, RenderingDevice::INVALID_FORMAT_ID,
                RenderingDevice::RENDER_PRIMITIVE_TRIANGLES, rs, ms, ds, bs);
        m_blit_pipelines[fb_format] = pipe;
    }
    Ref<RDUniform> u;
    u.instantiate();
    u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
    u->set_binding(0);
    u->add_id(m_sampler_nearest);
    u->add_id(src);
    TypedArray<RDUniform> us;
    us.push_back(u);
    RID set = UniformSetCacheRD::get_cache(m_blit_shader, 0, us);
    PackedByteArray pc;
    pc.resize(16);
    int32_t m[4] = {mode, 0, 0, 0};
    std::memcpy(pc.ptrw(), m, 16);
    int64_t dl = rd->draw_list_begin(fb);
    rd->draw_list_bind_render_pipeline(dl, pipe);
    rd->draw_list_bind_uniform_set(dl, set, 0);
    rd->draw_list_set_push_constant(dl, pc, 16);
    rd->draw_list_draw(dl, false, 1, 3);
    rd->draw_list_end();
}

RID GoannaIrisEffect::colortex(RenderSceneBuffersRD *rb, int index, int side, const Vector2i &size) {
    StringName ctx("goanna_iris");
    StringName name(String("colortex") + String::num_int64(index) + (side ? "_b" : "_a"));
    if (rb->has_texture(ctx, name))
        return rb->get_texture(ctx, name);
    uint32_t usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
            RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
    return rb->create_texture(ctx, name, m_ct_format[index], usage, RenderingDevice::TEXTURE_SAMPLES_1, size, 1, 1, true, false);
}

RID GoannaIrisEffect::textureFor(const std::string &name, RenderSceneBuffersRD *rb, const RID &colour, const RID &depth,
        const std::array<int, 16> &side) {
    if (name.rfind("colortex", 0) == 0) {
        int i = std::atoi(name.c_str() + 8);
        if (i >= 0 && i < 16)
            return colortex(rb, i, side[i], rb->get_internal_size());
        return m_dummy_black;
    }
    if (name.rfind("depthtex", 0) == 0)
        return depth;
    if (name == "noisetex")
        return m_noise;
    if (name.rfind("shadowtex", 0) == 0)
        return m_dummy_depth;
    if (name == "gtexture" || name == "lightmap" || name == "normals")
        return m_dummy_white;
    return m_dummy_black;
}

// ---- uniform block writers

void GoannaIrisEffect::put(const char *name, const float *v, int count) {
    const iris::Layout::Member *m = iris::standardLayout().find(name);
    if (!m) return;
    std::memcpy(m_ubo_data.data() + m->offset, v, count * sizeof(float));
}

void GoannaIrisEffect::putInt(const char *name, const int *v, int count) {
    const iris::Layout::Member *m = iris::standardLayout().find(name);
    if (!m) return;
    std::memcpy(m_ubo_data.data() + m->offset, v, count * sizeof(int));
}

void GoannaIrisEffect::putMat4(const char *name, const Projection &p) {
    float f[16];
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r)
            f[c * 4 + r] = (float)p.columns[c][r];
    put(name, f, 16);
}

void GoannaIrisEffect::putVec3(const char *name, const Vector3 &v) {
    float f[3] = {(float)v.x, (float)v.y, (float)v.z};
    put(name, f, 3);
}

static Projection basisToProjection(const Basis &b) {
    Projection p;
    for (int c = 0; c < 3; ++c)
        for (int r = 0; r < 3; ++r)
            p.columns[c][r] = b.rows[r][c];
    return p;
}

void GoannaIrisEffect::fillUniforms(RenderData *rdata, const Vector2i &size) {
    World w;
    {
        std::lock_guard<std::mutex> lk(m_world_mutex);
        w = m_world;
    }
    uint64_t now = Time::get_singleton()->get_ticks_usec();
    float t = (float)((now - m_t0) / 1000000.0);
    float dt = (float)((now - m_last_us) / 1000000.0);
    m_last_us = now;
    t = std::fmod(t, 3600.0f);
    RenderSceneData *sd = rdata->get_render_scene_data();
    Transform3D cam = sd ? sd->get_cam_transform() : Transform3D();
    Projection proj = sd ? sd->get_cam_projection() : Projection();
    Basis view = cam.basis.inverse();
    Projection mv = basisToProjection(view);
    Projection mvInv = basisToProjection(cam.basis);
    if (m_frame == 0) {
        m_prev_cam = cam;
        m_prev_proj = proj;
    }
    putMat4("gbufferModelView", mv);
    putMat4("gbufferModelViewInverse", mvInv);
    putMat4("gbufferProjection", proj);
    putMat4("gbufferProjectionInverse", proj.inverse());
    putMat4("gbufferPreviousModelView", basisToProjection(m_prev_cam.basis.inverse()));
    putMat4("gbufferPreviousProjection", m_prev_proj);
    // No shadow pass yet: the shadow matrices are the camera's, so a pack
    // that projects into shadow space gets something finite.
    putMat4("shadowModelView", mv);
    putMat4("shadowModelViewInverse", mvInv);
    putMat4("shadowProjection", proj);
    putMat4("shadowProjectionInverse", proj.inverse());
    // Composite passes: Iris draws a unit quad under an ortho projection, so
    // ftransform() of [0,1] lands on the screen.
    Projection ortho;
    ortho.columns[0] = Vector4(2, 0, 0, 0);
    ortho.columns[1] = Vector4(0, 2, 0, 0);
    ortho.columns[2] = Vector4(0, 0, 1, 0);
    ortho.columns[3] = Vector4(-1, -1, 0, 1);
    Projection ident;
    putMat4("goanna_mvp", ortho);
    putMat4("goanna_mvp_inv", ortho.inverse());
    putMat4("goanna_mv", ident);
    putMat4("goanna_mv_inv", ident);
    putMat4("goanna_proj", ortho);
    putMat4("goanna_proj_inv", ortho.inverse());
    putMat4("goanna_texmat0", ident);
    putMat4("goanna_texmat1", ident);
    {
        float nm[12] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
        put("goanna_nm", nm, 12);
    }
    float ec[4] = {0, 0, 0, 0};
    put("entityColor", ec, 4);
    put("lightningBoltPosition", ec, 4);
    putVec3("cameraPosition", cam.origin);
    putVec3("previousCameraPosition", m_prev_cam.origin);
    Vector3 sunV = view.xform(w.sun.normalized()) * 100.0f;
    Vector3 moonV = view.xform(w.moon.normalized()) * 100.0f;
    putVec3("sunPosition", sunV);
    putVec3("moonPosition", moonV);
    putVec3("shadowLightPosition", w.sun.y >= 0.0f ? sunV : moonV);
    putVec3("upPosition", view.xform(Vector3(0, 1, 0)) * 100.0f);
    putVec3("skyColor", Vector3(w.sky.r, w.sky.g, w.sky.b));
    putVec3("fogColor", Vector3(w.fog.r, w.fog.g, w.fog.b));
    putVec3("eyePosition", cam.origin);
    putVec3("relativeEyePosition", Vector3());
    putVec3("playerLookVector", -cam.basis.get_column(2));
    putVec3("playerBodyVector", -cam.basis.get_column(2));
    int eb[2] = {240, 240};
    putInt("eyeBrightness", eb, 2);
    putInt("eyeBrightnessSmooth", eb, 2);
    int atlas[2] = {1024, 1024};
    putInt("atlasSize", atlas, 2);
    putFloat("viewWidth", (float)size.x);
    putFloat("viewHeight", (float)size.y);
    putFloat("aspectRatio", size.y > 0 ? (float)size.x / (float)size.y : 1.0f);
    putFloat("near", (float)proj.get_z_near());
    putFloat("far", (float)proj.get_z_far());
    putFloat("frameTimeCounter", t);
    putFloat("frameTime", dt);
    // Luanti time_of_day: 0 midnight, 0.5 noon. Minecraft worldTime: 0 at
    // 6:00, 6000 noon, 18000 midnight. sunAngle is worldTime / 24000.
    float tod = w.tod - std::floor(w.tod);
    float wt = tod - 0.25f;
    wt -= std::floor(wt);
    putFloat("sunAngle", wt);
    putFloat("shadowAngle", wt < 0.5f ? wt : wt - 0.5f);
    putInt1("worldTime", (int)(wt * 24000.0f));
    putInt1("worldDay", 0);
    putInt1("moonPhase", 0);
    // The world says whether it is raining (0 or 1, from the particle side).
    // Minecraft's rain level walks toward that at 0.01 a tick, five seconds
    // end to end, and Iris smooths wetness after it with a half life of 600
    // ticks while wetting and 200 while drying. Same numbers here, so a pack
    // sees the ramps it was written against.
    if (m_frame == 0) {
        m_rain_strength = w.rain;
        m_wetness = w.rain;
    }
    float step = std::min(dt * 0.2f, 1.0f);
    m_rain_strength += std::clamp(w.rain - m_rain_strength, -step, step);
    float half_life = m_rain_strength > m_wetness ? 30.0f : 10.0f;
    m_wetness += (m_rain_strength - m_wetness) * (1.0f - std::pow(0.5f, dt / half_life));
    putFloat("rainStrength", m_rain_strength);
    putFloat("wetness", m_wetness);
    putFloat("eyeAltitude", (float)cam.origin.y);
    putInt1("isEyeInWater", w.in_water);
    putFloat("nightVision", 0.0f);
    putFloat("blindness", 0.0f);
    putFloat("darknessFactor", 0.0f);
    putFloat("darknessLightFactor", 0.0f);
    putFloat("screenBrightness", 0.5f);
    putFloat("centerDepthSmooth", 0.5f);
    putFloat("fogStart", (float)proj.get_z_far() * 0.8f);
    putFloat("fogEnd", (float)proj.get_z_far());
    putFloat("fogDensity", 0.0f);
    putFloat("ambientLight", 0.0f);
    putFloat("maxPlayerHealth", 20.0f);
    putFloat("currentPlayerHealth", 1.0f);
    putFloat("maxPlayerHunger", 20.0f);
    putFloat("currentPlayerHunger", 1.0f);
    putFloat("maxPlayerAir", 300.0f);
    putFloat("currentPlayerAir", 1.0f);
    putFloat("temperature", 0.8f);
    putFloat("rainfall", 0.4f);
    putFloat("dhNearPlane", (float)proj.get_z_near());
    putFloat("dhFarPlane", (float)proj.get_z_far());
    putFloat("cloudTime", t);
    putInt1("frameCounter", m_frame % 720720);
    putInt1("hideGUI", 0);
    putInt1("fogMode", 0);
    putInt1("fogShape", 0);
    putInt1("isRightHanded", 1);
    putInt1("hasSkylight", 1);
    putInt1("heightLimit", 31000);
    putInt1("logicalHeightLimit", 31000);
    putInt1("bedrockLevel", -31000);
    m_prev_cam = cam;
    m_prev_proj = proj;
    ++m_frame;
}

void GoannaIrisEffect::_render_callback(int32_t p_type, RenderData *p_render_data) {
    if (p_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT || m_dead || m_passes.empty() || !p_render_data)
        return;
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    if (!rd)
        return;
    Ref<RenderSceneBuffersRD> rb = p_render_data->get_render_scene_buffers();
    if (rb.is_null())
        return;
    if (rb->get_view_count() != 1) {
        static bool warned = false;
        if (!warned) {
            UtilityFunctions::push_warning("Goanna Iris: multiview (XR) is not supported yet, effect off");
            warned = true;
        }
        return;
    }
    if (!ensureGpu(rd))
        return;
    Vector2i size = rb->get_internal_size();
    RID colour = rb->get_color_texture();
    RID depth = rb->get_depth_texture();
    if (!colour.is_valid())
        return;

    fillUniforms(p_render_data, size);
    PackedByteArray ub;
    ub.resize(m_ubo_data.size());
    std::memcpy(ub.ptrw(), m_ubo_data.data(), m_ubo_data.size());
    rd->buffer_update(m_ubo, 0, ub.size(), ub);

    // Which side of each colortex is "current". A pass reads current and
    // writes the other, then the ones it wrote flip.
    std::array<int, 16> side{};
    TypedArray<RDFramebufferPass> nopasses;

    // colortex0 starts as the scene colour; the rest start cleared.
    for (int i = 0; i < 16; ++i) {
        if (!m_ct_used[i])
            continue;
        RID a = colortex(rb.ptr(), i, 0, size);
        RID b = colortex(rb.ptr(), i, 1, size);
        if (i == 0) {
            TypedArray<RID> t;
            t.push_back(a);
            RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
            blit(rd, colour, fb, rd->framebuffer_get_format(fb), m_bridge_colour ? 1 : 0);
        } else if (m_ct_clear[i]) {
            for (RID tex : {a, b}) {
                TypedArray<RID> t;
                t.push_back(tex);
                RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
                PackedColorArray clr;
                clr.push_back(Color(0, 0, 0, 0));
                int64_t dl = rd->draw_list_begin(fb, RenderingDevice::DRAW_CLEAR_COLOR_ALL, clr);
                rd->draw_list_end();
            }
        }
    }

    for (auto &p : m_passes) {
        if (!p.shader.is_valid())
            continue;
        // targets
        TypedArray<RID> targets;
        std::vector<int> written;
        if (p.is_final) {
            // With the colour bridge, final draws into a scratch target and a
            // decode blit carries it to the scene colour; without it, straight in.
            targets.push_back(m_bridge_colour ? finalTarget(rb.ptr(), size) : colour);
        } else {
            std::vector<int> db = p.tr.drawbuffers;
            if (db.empty())
                db.push_back(0);
            for (int i : db) {
                if (i < 0 || i >= 16)
                    continue;
                targets.push_back(colortex(rb.ptr(), i, 1 - side[i], size));
                written.push_back(i);
            }
        }
        if (targets.is_empty())
            continue;
        RID fb = FramebufferCacheRD::get_cache_multipass(targets, nopasses, 1);
        int64_t fbf = rd->framebuffer_get_format(fb);
        RID pipe = pipelineFor(rd, p, fbf, (int)targets.size());
        if (!pipe.is_valid())
            continue;
        // set 0: samplers
        TypedArray<RDUniform> set0;
        for (auto &s : p.tr.samplers) {
            Ref<RDUniform> u;
            u.instantiate();
            u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
            u->set_binding(s.binding);
            bool isDepth = s.name.rfind("depthtex", 0) == 0 || s.name.rfind("shadowtex", 0) == 0;
            u->add_id(s.name == "noisetex" ? m_sampler_repeat : (isDepth ? m_sampler_nearest : m_sampler_linear));
            u->add_id(textureFor(s.name, rb.ptr(), colour, depth, side));
            set0.push_back(u);
        }
        // set 1: uniform blocks
        TypedArray<RDUniform> set1;
        {
            Ref<RDUniform> u;
            u.instantiate();
            u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_UNIFORM_BUFFER);
            u->set_binding(0);
            u->add_id(m_ubo);
            set1.push_back(u);
            if (p.extra_ubo.is_valid()) {
                Ref<RDUniform> e;
                e.instantiate();
                e->set_uniform_type(RenderingDevice::UNIFORM_TYPE_UNIFORM_BUFFER);
                e->set_binding(1);
                e->add_id(p.extra_ubo);
                set1.push_back(e);
            }
        }
        int64_t dl = rd->draw_list_begin(fb);
        rd->draw_list_bind_render_pipeline(dl, pipe);
        if (!set0.is_empty())
            rd->draw_list_bind_uniform_set(dl, UniformSetCacheRD::get_cache(p.shader, 0, set0), 0);
        rd->draw_list_bind_uniform_set(dl, UniformSetCacheRD::get_cache(p.shader, 1, set1), 1);
        rd->draw_list_draw(dl, false, 1, 3);
        rd->draw_list_end();
        for (int i : written)
            side[i] = 1 - side[i];
        if (p.is_final && m_bridge_colour) {
            TypedArray<RID> t;
            t.push_back(colour);
            RID ofb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
            blit(rd, finalTarget(rb.ptr(), size), ofb, rd->framebuffer_get_format(ofb), 2);
        }
    }
}

RID GoannaIrisEffect::finalTarget(RenderSceneBuffersRD *rb, const Vector2i &size) {
    StringName ctx("goanna_iris");
    StringName name("final_out");
    if (rb->has_texture(ctx, name))
        return rb->get_texture(ctx, name);
    uint32_t usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;
    return rb->create_texture(ctx, name, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
            RenderingDevice::TEXTURE_SAMPLES_1, size, 1, 1, true, false);
}

void GoannaIrisEffect::set_bridge_colour(bool on) {
    m_bridge_colour = on;
}

bool GoannaIrisEffect::get_bridge_colour() const {
    return m_bridge_colour;
}

bool GoannaIrisEffect::has_final() const {
    for (auto &p : m_passes)
        if (p.is_final && p.error.empty())
            return true;
    return false;
}

void GoannaIrisEffect::freeGpu() {
    RenderingServer *rs = RenderingServer::get_singleton();
    RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
    if (!rd)
        return;
    auto freeIf = [&](RID &r) {
        if (r.is_valid())
            rd->free_rid(r);
        r = RID();
    };
    for (auto &p : m_passes) {
        for (auto &kv : p.pipelines)
            freeIf(kv.second);
        p.pipelines.clear();
        freeIf(p.shader);
        freeIf(p.extra_ubo);
    }
    for (auto &kv : m_blit_pipelines)
        freeIf(kv.second);
    m_blit_pipelines.clear();
    freeIf(m_blit_shader);
    freeIf(m_ubo);
    freeIf(m_sampler_linear);
    freeIf(m_sampler_nearest);
    freeIf(m_sampler_repeat);
    freeIf(m_dummy_black);
    freeIf(m_dummy_white);
    freeIf(m_dummy_depth);
    freeIf(m_noise);
    m_gpu_ready = false;
}

} // namespace goanna
