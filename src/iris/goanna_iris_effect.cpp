// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The Iris screen space runner: building the GPU objects on the render
// thread at first use, the per frame uniforms Iris packs expect, the
// colortex and depth bindings, and the colour bridge between Godot's linear
// HDR and the gamma space LDR a pack is written for. Thread rules are in
// goanna_iris_effect.h.

#include "iris/goanna_iris_effect.h"
#include "iris/iris_shadow.h"
#include "goanna_sky.h"

#include <godot_cpp/classes/framebuffer_cache_rd.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/os.hpp>
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
#include <godot_cpp/variant/callable_custom.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <utility>

using namespace godot;

namespace goanna {

namespace {

// Frees the gbuffers read textures on the render thread, after the
// Texture2DRDs' own release, which they queue there too. It owns copies of
// the RIDs and nothing else, so it is safe to run after the effect is gone.
class FreeReadTextures : public CallableCustom {
public:
    explicit FreeReadTextures(std::vector<RID> rids) : m_rids(std::move(rids)) {}
    uint32_t hash() const override { return (uint32_t)(uintptr_t)this; }
    String get_as_text() const override { return "GoannaIrisEffect::FreeReadTextures"; }
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
        if (!rd)
            return;
        for (const RID &r : m_rids)
            if (r.is_valid())
                rd->free_rid(r);
    }

private:
    std::vector<RID> m_rids;
};

// The callback for the centre depth readback. A callable_mp on the effect
// would leave Godot holding a pointer to it, and checking that callable's
// validity after the effect is freed reads the freed object (crashes seen
// on 2026-10-11; tests/iris_teardown.tscn). This one owns its share of the
// state, so it is always safe to call.
class CenterDepthCallable : public CallableCustom {
public:
    explicit CenterDepthCallable(std::shared_ptr<GoannaIrisEffect::CenterDepth> state) : m_state(std::move(state)) {}

    uint32_t hash() const override { return (uint32_t)(uintptr_t)m_state.get(); }
    String get_as_text() const override { return "GoannaIrisEffect::CenterDepth"; }
    static bool equal(const CallableCustom *a, const CallableCustom *b) { return a == b; }
    static bool less(const CallableCustom *a, const CallableCustom *b) { return a < b; }
    CompareEqualFunc get_compare_equal_func() const override { return &equal; }
    CompareLessFunc get_compare_less_func() const override { return &less; }
    bool is_valid() const override { return true; }
    ObjectID get_object() const override { return ObjectID(); }

    void call(const Variant **args, int argc, Variant &ret, GDExtensionCallError &err) const override {
        err.error = GDEXTENSION_CALL_OK;
        if (argc >= 1 && args[0]->get_type() == Variant::PACKED_BYTE_ARRAY) {
            PackedByteArray data = *args[0];
            if (data.size() >= 4) {
                float v;
                std::memcpy(&v, data.ptr(), 4);
                if (std::isfinite(v))
                    m_state->raw.store(v);
            }
        }
        m_state->pending.store(false);
    }

private:
    std::shared_ptr<GoannaIrisEffect::CenterDepth> m_state;
};

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
// mode 0 copies pack colour unchanged, including linear HDR. Mode 1
// encodes native Godot colour into sRGB for packs without geometry. Mode 2
// decodes a pack's finished image back to linear for Godot's
// output stage, which main.gd sets to a linear tonemap while a pack owns
// final. Packs do their own exposure and tonemapping; handing them HDR and
// then tonemapping their result again is how a pack looks washed out. mode 3
// turns Godot's reversed Z depth into OpenGL's convention (0 near, 1 far,
// sky 1.0), which is what every pack's depth arithmetic assumes. mode 4
// copies a second output only translucent programs write, and only where
// depth0 (with translucent geometry) is nearer than depth1 (without):
// elsewhere opaque terrain wrote zero at alpha 1 into it, where Minecraft
// would have left the clear, and Photon's water layer drew black over all
// its land. Modes 5 and 6 restore geometry over a prepare background,
// retaining sky pixels; mode 6 also encodes native scene colour.
const char *kBlitFragment =
        "#version 450\n"
        "layout(set = 0, binding = 0) uniform sampler2D src;\n"
        "layout(set = 0, binding = 1) uniform sampler2D depth0;\n"
        "layout(set = 0, binding = 2) uniform sampler2D depth1;\n"
        "layout(push_constant, std430) uniform Params { int mode; int pad0; int pad1; int pad2; } params;\n"
        "layout(location = 0) in vec2 uv;\n"
        "layout(location = 0) out vec4 o;\n"
        "vec3 encode(vec3 c) {\n"
        "    c = max(c, vec3(0.0));\n"
        "    return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));\n"
        "}\n"
        "vec3 decode(vec3 c) {\n"
        "    c = max(c, vec3(0.0));\n"
        "    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));\n"
        "}\n"
        "void main() {\n"
        "    vec4 c = texture(src, uv);\n"
        "    if (params.mode == 1) c.rgb = encode(c.rgb);\n"
        "    else if (params.mode == 2) c.rgb = decode(c.rgb);\n"
        "    else if (params.mode == 3) c = vec4(1.0 - c.r);\n"
        "    else if (params.mode == 4 && !(texture(depth0, uv).r < texture(depth1, uv).r)) c = vec4(0.0);\n"
        "    if (params.mode == 5 || params.mode == 6) {\n"
        "        if (texture(depth0, uv).r >= 1.0) discard;\n"
        "        if (params.mode == 6) c.rgb = encode(c.rgb);\n"
        "    }\n"
        "    if (params.mode == 8 || params.mode == 9) {\n"
        "        if (params.mode == 9 && texture(depth0, uv).r >= 1.0) discard;\n"
        "        uvec3 hi = uvec3(round(c.rgb * 2048.0));\n"
        "        uvec3 lo = uvec3(round(texture(depth1, uv).rgb * 2048.0));\n"
        "        uvec4 bits = uvec4(hi.x | ((hi.y & 31u) << 11u),\n"
        "            (hi.y >> 5u) | ((hi.z & 1023u) << 6u),\n"
        "            (hi.z >> 10u) | (lo.x << 1u) | ((lo.y & 15u) << 12u),\n"
        "            (lo.y >> 4u) | (lo.z << 7u));\n"
        "        c = vec4(bits) / 65535.0;\n"
        "    }\n"
        "    o = c;\n"
        "}\n";

RID makeTexture(RenderingDevice *rd, int w, int h, RenderingDevice::DataFormat fmt, const PackedByteArray &data,
        int depth = 0) {
    Ref<RDTextureFormat> tf;
    tf.instantiate();
    tf->set_width(w);
    tf->set_height(h);
    tf->set_format(fmt);
    if (depth > 0) {
        tf->set_depth(depth);
        tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_3D);
    } else {
        tf->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
    }
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
    for (auto &n : m_ct_format_name)
        n = "RGBA8";
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
    ClassDB::bind_method(D_METHOD("sun_path_rotation"), &GoannaIrisEffect::sun_path_rotation);
    ClassDB::bind_method(D_METHOD("make_depth_capture"), &GoannaIrisEffect::make_depth_capture);
    ClassDB::bind_method(D_METHOD("pack_name"), &GoannaIrisEffect::pack_name);
    ClassDB::bind_method(D_METHOD("report"), &GoannaIrisEffect::report);
    ClassDB::bind_method(D_METHOD("set_world_state", "state"), &GoannaIrisEffect::set_world_state);
    ClassDB::bind_method(D_METHOD("set_shadow", "shadow"), &GoannaIrisEffect::set_shadow);
    ClassDB::bind_method(D_METHOD("set_dump_dir", "dir"), &GoannaIrisEffect::set_dump_dir);
    ClassDB::bind_method(D_METHOD("set_bridge_colour", "on"), &GoannaIrisEffect::set_bridge_colour);
    ClassDB::bind_method(D_METHOD("get_bridge_colour"), &GoannaIrisEffect::get_bridge_colour);
    ClassDB::bind_method(D_METHOD("has_final"), &GoannaIrisEffect::has_final);
    ClassDB::bind_method(D_METHOD("reads_colortex", "index"), &GoannaIrisEffect::reads_colortex);
    ClassDB::bind_method(D_METHOD("set_gbuffers_low_target", "index", "texture"), &GoannaIrisEffect::set_gbuffers_low_target);
    ClassDB::bind_method(D_METHOD("set_gbuffers_target", "index", "texture"), &GoannaIrisEffect::set_gbuffers_target);
    ClassDB::bind_method(D_METHOD("set_gbuffers_translucent", "index", "translucent_only"),
            &GoannaIrisEffect::set_gbuffers_translucent);
    ClassDB::bind_method(D_METHOD("set_gbuffers_reads", "targets", "colour_target"),
            &GoannaIrisEffect::set_gbuffers_reads);
    ClassDB::bind_method(D_METHOD("sync_gbuffers_reads"), &GoannaIrisEffect::sync_gbuffers_reads);
    ClassDB::bind_method(D_METHOD("gbuffers_read_texture", "index"), &GoannaIrisEffect::gbuffers_read_texture);
}

// ---------------------------------------------------------------------------
// Main thread

bool GoannaIrisEffect::load_pack(const String &path) {
    m_passes.clear();
    m_load_error.clear();
    std::string err;
    {
        // NAME=value pairs; GoannaIrisGbuffers reads the same variable.
        m_pack.setOptionOverrides(iris::parseOptionOverrides(
                OS::get_singleton()->get_environment("GOANNA_SHADERPACK_OPTIONS").utf8().get_data()));
    }
    if (!m_pack.load(path.utf8().get_data(), err)) {
        m_load_error = err;
        UtilityFunctions::push_error(String("Goanna Iris: ") + err.c_str());
        return false;
    }
    m_sun_path_rotation = iris::readShadowSettings(m_pack.consts(), m_pack.options()).sun_path_rotation;
    // Goanna supplies none of Iris's optional features (compute, custom
    // images, SSBOs and the rest), so a pack that requires one is refused
    // rather than run in a state its author never wrote for.
    m_missing_features = m_pack.missingFeatures();
    if (!m_missing_features.empty()) {
        m_load_error = "pack requires Iris features Goanna does not supply:";
        for (auto &f : m_missing_features)
            m_load_error += " " + f;
        UtilityFunctions::push_error(String("Goanna Iris: ") + m_load_error.c_str());
        return false;
    }
    m_custom = m_pack.customUniforms();
    loadCustomTextures();
    std::set<std::string> customNames;
    for (auto &d : m_custom.defs())
        customNames.insert(d.name);
    // colortex formats and clear flags from the pack's const directives.
    // Without the colour bridge colortex0 carries Godot's HDR colour, so its
    // default widens from RGBA8 to RGBA16F unless the pack says otherwise.
    if (!m_bridge_colour)
        m_ct_format[0] = RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT;
    for (int i = 0; i < 16; ++i) {
        // Either name a target goes by: colortex4Format or gaux1Format.
        auto targetConst = [&](const char *suffix) -> const std::string * {
            static const char *legacy[8] = {"gcolor", "gdepth", "gnormal", "composite", "gaux1", "gaux2", "gaux3",
                    "gaux4"};
            auto f = m_pack.consts().find("colortex" + std::to_string(i) + suffix);
            if (f == m_pack.consts().end() && i < 8)
                f = m_pack.consts().find(std::string(legacy[i]) + suffix);
            return f != m_pack.consts().end() ? &f->second : nullptr;
        };
        if (const std::string *f = targetConst("Format")) {
            m_ct_format[i] = formatFromIris(*f, m_ct_format[i]);
            m_ct_format_name[i] = *f;
        }
        if (const std::string *c = targetConst("Clear"))
            m_ct_clear[i] = *c != "false";
        // size.buffer.colortexN = W H: a fraction of the screen when written
        // with a decimal point (Photon's fog and AO at 0.5 0.5), else pixels
        // (its sky map at 192 108). A pass drawing into such a buffer covers
        // it whole, as Iris sets the viewport to the target, and a pack
        // reading it by texel (texelFetch at half the screen coordinate)
        // finds what it wrote there; at screen size it read a quarter of
        // the picture, and Photon drew its fog over the scene at half scale.
        m_ct_size[i] = BufferSize();
        m_pack.bufferSize(i, m_ct_size[i].relative, m_ct_size[i].x, m_ct_size[i].y);
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
        pass.stage = name.rfind("prepare", 0) == 0 ? "prepare"
                : name.rfind("deferred", 0) == 0 ? "deferred" : "composite";
        std::vector<std::string> ppwarn;
        if (!m_pack.program(name, prog, perr, &ppwarn)) {
            pass.error = perr;
            m_passes.push_back(pass);
            continue;
        }
        if (!iris::translate(prog, opts, pass.tr, perr))
            pass.error = perr;
        for (auto &w : ppwarn)
            pass.tr.warnings.push_back(w);
        for (auto &m : pass.tr.extra.members)
            if (!customNames.count(m.name) && !knownExtra(m.name))
                pass.zero_uniforms.push_back(m.name);
        for (auto &s : pass.tr.samplers)
            if (s.name.rfind("colortex", 0) == 0) {
                int i = std::atoi(s.name.c_str() + 8);
                if (i >= 0 && i < 16)
                    m_ct_used[i] = m_ct_read[i] = true;
            }
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
    std::lock_guard<std::mutex> lock(m_report_mutex);
    Dictionary d;
    d["gbuffers_colour_raw"] = m_gbuffers_colour_raw;
    d["pack"] = pack_name();
    d["load_error"] = String::utf8(m_load_error.c_str());
    Array programs;
    for (auto &p : m_pack.programNames())
        programs.push_back(String::utf8(p.c_str()));
    d["programs"] = programs;
    auto strings = [](const std::vector<std::string> &v) {
        Array a;
        for (auto &x : v)
            a.push_back(String::utf8(x.c_str()));
        return a;
    };
    d["missing_features"] = strings(m_missing_features);
    d["disabled_programs"] = strings(m_pack.disabledPrograms());
    d["property_warnings"] = strings(m_pack.propertyWarnings());
    d["unknown_options"] = strings(m_pack.unknownOverrides());
    d["custom_uniforms"] = (int64_t)m_custom.defs().size();
    d["custom_unresolved"] = strings(m_custom_unresolved);
    d["custom_textures"] = strings(m_texture_notes);
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
        pd["zero_uniforms"] = strings(p.zero_uniforms);
        passes.push_back(pd);
    }
    d["passes"] = passes;
    d["gpu_ready"] = m_gpu_ready;
    d["dead"] = m_dead;
    {
        // What each geometry program read is served from (set_gbuffers_reads).
        Dictionary reads;
        std::lock_guard<std::mutex> lk(m_reads->mutex);
        for (int i = 0; i < 16; ++i)
            if (m_reads->want[i])
                reads[i] = "after prepare/deferred, last frame";
        d["gbuffers_reads"] = reads;
    }
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
    if (s.has("cloud_height")) m_world.cloud_height = (float)(double)s["cloud_height"];
    if (s.has("eye_brightness")) m_world.eye_light = s["eye_brightness"];
    if (s.has("shadow_model_view") && s.has("shadow_projection")) {
        m_world.shadow_mv = s["shadow_model_view"];
        m_world.shadow_proj = s["shadow_projection"];
        m_world.has_shadow = true;
    }
}

void GoannaIrisEffect::set_shadow(const Ref<GoannaIrisShadow> &shadow) {
    m_shadow = shadow;
}

void GoannaIrisEffect::set_dump_dir(const String &dir) {
    m_dump_dir = dir.utf8().get_data();
}

// ---------------------------------------------------------------------------
// Render thread

bool GoannaIrisEffect::ensureBlit(RenderingDevice *rd) {
    if (m_blit_shader.is_valid())
        return true;
    if (m_dead)
        return false;
    std::string err;
    m_blit_shader = compileGlsl(rd, kBlitVertex, kBlitFragment, "goanna_iris_blit", err);
    if (!m_blit_shader.is_valid()) {
        UtilityFunctions::push_error(String("Goanna Iris: blit shader failed: ") + err.c_str());
        m_dead = true;
        return false;
    }
    Ref<RDSamplerState> sn;
    sn.instantiate();
    sn->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    sn->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
    sn->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    sn->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    m_sampler_nearest = rd->sampler_create(sn);
    return true;
}

bool GoannaIrisEffect::ensureGpu(RenderingDevice *rd) {
    if (m_gpu_ready)
        return true;
    // Held while the passes compile, which is the only time the render
    // thread writes what report() reads.
    std::lock_guard<std::mutex> lock(m_report_mutex);
    if (!ensureBlit(rd))
        return false;
    Ref<RDSamplerState> ss;
    ss.instantiate();
    ss->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    ss->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    ss->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    ss->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    m_sampler_linear = rd->sampler_create(ss);
    Ref<RDSamplerState> sr;
    sr.instantiate();
    sr->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sr->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sr->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    sr->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    sr->set_repeat_w(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    m_sampler_repeat = rd->sampler_create(sr);
    Ref<RDSamplerState> snr;
    snr.instantiate();
    snr->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    snr->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT);
    m_sampler_nearest_repeat = rd->sampler_create(snr);
    // sampler2DShadow wants a comparison sampler and a depth format texture.
    Ref<RDSamplerState> sc;
    sc.instantiate();
    sc->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sc->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
    sc->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    sc->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
    sc->set_enable_compare(true);
    sc->set_compare_op(RenderingDevice::COMPARE_OP_LESS_OR_EQUAL);
    m_sampler_shadow = rd->sampler_create(sc);
    {
        // No shadow pass yet: a 1x1 depth of 1.0, cleared rather than
        // uploaded, so every compare says lit.
        Ref<RDTextureFormat> tf;
        tf.instantiate();
        tf->set_width(1);
        tf->set_height(1);
        tf->set_format(RenderingDevice::DATA_FORMAT_D32_SFLOAT);
        tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
                RenderingDevice::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
        Ref<RDTextureView> tv;
        tv.instantiate();
        m_dummy_shadow_depth = rd->texture_create(tf, tv);
        TypedArray<RID> t;
        t.push_back(m_dummy_shadow_depth);
        RID fb = rd->framebuffer_create(t);
        rd->draw_list_begin(fb, RenderingDevice::DRAW_CLEAR_DEPTH, PackedColorArray(), 1.0f);
        rd->draw_list_end();
        rd->free_rid(fb);
    }
    {
        Ref<RDTextureFormat> tf;
        tf.instantiate();
        tf->set_width(1);
        tf->set_height(1);
        tf->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
        tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
                RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT);
        Ref<RDTextureView> tv;
        tv.instantiate();
        m_center_tex = rd->texture_create(tf, tv);
    }
    for (auto &c : m_custom_tex)
        c.tex = makeTexture(rd, c.w, c.h, c.format, c.rgba, c.depth);

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
    auto eye_half = m_pack.consts().find("eyeBrightnessHalflife");
    if (eye_half != m_pack.consts().end()) {
        float ticks = std::strtof(eye_half->second.c_str(), nullptr);
        if (std::isfinite(ticks) && ticks >= 0) m_eye_half_seconds = ticks / 20.0f;
    }
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

void GoannaIrisEffect::blit(RenderingDevice *rd, const RID &src, const RID &fb, int64_t fb_format, int mode,
        const RID &depth0, const RID &depth1) {
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
    // The depths only mode 4 reads; any valid texture fills the bindings.
    int binding = 1;
    for (const RID *d : {&depth0, &depth1}) {
        Ref<RDUniform> du;
        du.instantiate();
        du->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
        du->set_binding(binding++);
        du->add_id(m_sampler_nearest);
        du->add_id(d->is_valid() ? *d : src);
        us.push_back(du);
    }
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

Vector2i GoannaIrisEffect::colortexSize(int index, const Vector2i &screen) const {
    const BufferSize &s = m_ct_size[index];
    if (s.relative)
        return Vector2i(std::max(1, (int)std::lround(screen.x * s.x)), std::max(1, (int)std::lround(screen.y * s.y)));
    return Vector2i(std::max(1, (int)s.x), std::max(1, (int)s.y));
}

RID GoannaIrisEffect::colortex(RenderSceneBuffersRD *rb, int index, int side, const Vector2i &size) {
    StringName ctx("goanna_iris");
    StringName name(String("colortex") + String::num_int64(index) + (side ? "_b" : "_a"));
    if (rb->has_texture(ctx, name))
        return rb->get_texture(ctx, name);
    uint32_t usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
            RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
    RID tex = rb->create_texture(ctx, name, m_ct_format[index], usage, RenderingDevice::TEXTURE_SAMPLES_1,
            colortexSize(index, size), 1, 1, true, false);
    // Clear=false preserves history after the first frame, never undefined
    // allocation contents. NaNs here poison exposure and temporal filters.
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    TypedArray<RID> targets;
    targets.push_back(tex);
    TypedArray<RDFramebufferPass> passes;
    RID fb = FramebufferCacheRD::get_cache_multipass(targets, passes, 1);
    PackedColorArray clear;
    clear.push_back(Color(0, 0, 0, 0));
    rd->draw_list_begin(fb, RenderingDevice::DRAW_CLEAR_COLOR_ALL, clear);
    rd->draw_list_end();
    return tex;
}

// Whether `name` is a uniform this effect answers outside the standard block:
// the core profile matrices Iris supplies, which in a full screen pass are
// the identity and the [0,1] quad's orthographic projection.
bool GoannaIrisEffect::knownExtra(const std::string &name) {
    return name == "modelViewMatrix" || name == "modelViewMatrixInverse" || name == "projectionMatrix" ||
            name == "projectionMatrixInverse" || name == "textureMatrix" || name == "normalMatrix" ||
            name == "chunkOffset";
}

RID GoannaIrisEffect::textureFor(const Pass &p, const iris::Translated::Sampler &s, RenderSceneBuffersRD *rb,
        const RID &depth0, const RID &depth1, const std::array<int, 16> &side) {
    const std::string &name = s.name;
    // texture.<stage>.<sampler> from the pack's properties wins over the
    // built in binding of the same name, where the sampler's type fits it:
    // Photon gives its composite stage a 3D noise as colortex0, which its
    // sampler3D colortex0 reads while the sampler2D ones read the scene.
    for (auto &c : m_custom_tex)
        if (c.tex.is_valid() && c.fits(s.type) &&
                (c.key == p.stage + ":" + name || (name == "noisetex" && c.key == "noise")))
            return c.tex;
    if (name.rfind("colortex", 0) == 0) {
        int i = std::atoi(name.c_str() + 8);
        if (i >= 0 && i < 16)
            return colortex(rb, i, side[i], rb->get_internal_size());
        return m_dummy_black;
    }
    // depthtex2 is depthtex1 without the hand; Goanna's hand is drawn in
    // the same pass as everything opaque, so the two are the same here.
    if (name == "depthtex0")
        return depth0;
    if (name == "depthtex1" || name == "depthtex2")
        return depth1;
    if (name == "noisetex")
        return m_noise;
    // The pack's own shadow map once it has been drawn (rung 7): the depth
    // format copy serves a comparison sampler and a plain one alike.
    // shadowtex1 is shadowtex0: no translucent geometry is drawn into it.
    if (m_shadow.is_valid() && m_shadow->depth_rid().is_valid()) {
        if (name == "shadowtex0" || name == "shadowtex1")
            return m_shadow->depth_rid();
        if (name == "shadowcolor0" && m_shadow->colour_rid().is_valid())
            return m_shadow->colour_rid();
    }
    if (name.rfind("shadowtex", 0) == 0)
        return s.type.find("Shadow") != std::string::npos ? m_dummy_shadow_depth : m_dummy_depth;
    if (name == "gtexture" || name == "lightmap" || name == "normals")
        return m_dummy_white;
    return m_dummy_black;
}

RID GoannaIrisEffect::samplerFor(const Pass &p, const iris::Translated::Sampler &s) const {
    if (s.type.find("Shadow") != std::string::npos)
        return m_sampler_shadow;
    for (auto &c : m_custom_tex)
        if (c.tex.is_valid() && c.fits(s.type) &&
                (c.key == p.stage + ":" + s.name || (s.name == "noisetex" && c.key == "noise")))
            return c.depth > 0 ? m_sampler_repeat : m_sampler_nearest_repeat;
    if (s.name == "noisetex")
        return m_sampler_repeat;
    if (s.name.rfind("depthtex", 0) == 0 || s.name.rfind("shadowtex", 0) == 0)
        return m_sampler_nearest;
    return m_sampler_linear;
}

// A raw texture line: "path TEXTURE_3D RGB16F 32 64 32 RGB HALF_FLOAT", the
// file's texels with no header in the layout the last two words give (the
// internal format is not needed: the data's own layout picks the GPU
// format). Three components are widened to four, alpha 1, since Vulkan
// cards seldom sample three component formats. Photon's atmosphere LUT and
// cloud and fog noises are such files; without the LUT its sun and sky
// read black and its terrain went unlit.
bool GoannaIrisEffect::loadRawTexture(const std::string &value, CustomTexture &c, std::string &why) const {
    namespace fs = std::filesystem;
    std::istringstream in(value);
    std::vector<std::string> t;
    for (std::string w; in >> w;) t.push_back(w);
    if (t.size() < 2) { why = "raw texture line not understood"; return false; }
    int dims = t[1] == "TEXTURE_3D" ? 3 : (t[1] == "TEXTURE_2D" || t[1] == "TEXTURE_RECTANGLE") ? 2
            : t[1] == "TEXTURE_1D" ? 1 : 0;
    if (dims == 0 || t.size() != (size_t)(3 + dims + 2)) { why = "raw " + t[1] + " not supported"; return false; }
    int size[3] = {1, 1, 1};
    for (int k = 0; k < dims; ++k) size[k] = std::atoi(t[3 + k].c_str());
    const std::string &pf = t[3 + dims], &pt = t[4 + dims];
    int comps = pf == "RED" || pf == "RED_INTEGER" ? 1 : pf == "RG" ? 2 : pf == "RGB" ? 3 : pf == "RGBA" ? 4 : 0;
    int bytes = pt == "UNSIGNED_BYTE" ? 1 : pt == "HALF_FLOAT" || pt == "UNSIGNED_SHORT" ? 2 : pt == "FLOAT" ? 4 : 0;
    if (comps == 0 || bytes == 0 || size[0] <= 0 || size[1] <= 0 || size[2] <= 0) {
        why = "raw texture layout " + pf + " " + pt + " not supported";
        return false;
    }
    using RD = RenderingDevice;
    static const RD::DataFormat byFormat[3][4] = {
        {RD::DATA_FORMAT_R8_UNORM, RD::DATA_FORMAT_R8G8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM},
        {RD::DATA_FORMAT_R16_SFLOAT, RD::DATA_FORMAT_R16G16_SFLOAT, RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
                RD::DATA_FORMAT_R16G16B16A16_SFLOAT},
        {RD::DATA_FORMAT_R32_SFLOAT, RD::DATA_FORMAT_R32G32_SFLOAT, RD::DATA_FORMAT_R32G32B32A32_SFLOAT,
                RD::DATA_FORMAT_R32G32B32A32_SFLOAT},
    };
    int kind = pt == "UNSIGNED_BYTE" ? 0 : pt == "FLOAT" ? 2 : 1;
    RD::DataFormat fmt = byFormat[kind][comps - 1];
    if (pt == "UNSIGNED_SHORT")
        fmt = comps == 1 ? RD::DATA_FORMAT_R16_UNORM : comps == 2 ? RD::DATA_FORMAT_R16G16_UNORM
                                                       : RD::DATA_FORMAT_R16G16B16A16_UNORM;
    std::string rel = t[0][0] == '/' ? t[0].substr(1) : t[0];
    std::ifstream f((fs::path(m_pack.shadersDir()) / rel).string(), std::ios::binary);
    std::vector<uint8_t> raw((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    size_t texels = (size_t)size[0] * size[1] * size[2];
    if (raw.size() < texels * comps * bytes) {
        why = "cannot read " + t[0] + " (" + std::to_string(raw.size()) + " bytes, " +
                std::to_string(texels * comps * bytes) + " wanted)";
        return false;
    }
    int outComps = comps == 3 ? 4 : comps;
    c.rgba.resize(texels * outComps * bytes);
    uint8_t *o = c.rgba.ptrw();
    if (comps == 3) {
        // the one, as each layout spells it
        uint8_t one[4] = {0xff, 0, 0, 0};
        if (pt == "HALF_FLOAT") { one[0] = 0x00; one[1] = 0x3c; }
        if (pt == "UNSIGNED_SHORT") { one[0] = 0xff; one[1] = 0xff; }
        if (pt == "FLOAT") { float f1 = 1.0f; std::memcpy(one, &f1, 4); }
        for (size_t i = 0; i < texels; ++i) {
            std::memcpy(o + i * 4 * bytes, raw.data() + i * 3 * bytes, 3 * bytes);
            std::memcpy(o + i * 4 * bytes + 3 * bytes, one, bytes);
        }
    } else {
        std::memcpy(o, raw.data(), texels * comps * bytes);
    }
    c.format = fmt;
    c.w = size[0];
    c.h = size[1];
    c.depth = dims == 3 ? size[2] : 0;
    return true;
}

// texture.noise and texture.<stage>.<sampler> lines naming an image file in
// the pack. Main thread: the pixels are read here and uploaded at first use.
void GoannaIrisEffect::loadCustomTextures() {
    namespace fs = std::filesystem;
    m_custom_tex.clear();
    m_texture_notes.clear();
    for (auto &kv : m_pack.properties()) {
        const std::string &key = kv.first;
        if (key.rfind("texture.", 0) != 0)
            continue;
        std::string rest = key.substr(8), id;
        if (rest == "noise") {
            id = "noise";
        } else {
            size_t dot = rest.find('.');
            if (dot == std::string::npos)
                continue;
            std::string stage = rest.substr(0, dot), name = rest.substr(dot + 1);
            // colortex6.1: a trailing number only tells two textures for
            // one sampler name apart (Photon's two cloud noises); the type
            // of the sampler picks which binds.
            size_t sfx = name.rfind('.');
            if (sfx != std::string::npos && sfx + 1 < name.size() &&
                    name.find_first_not_of("0123456789", sfx + 1) == std::string::npos)
                name = name.substr(0, sfx);
            if (stage != "prepare" && stage != "deferred" && stage != "composite") {
                m_texture_notes.push_back(key + ": stage not run here");
                continue;
            }
            std::string canon = iris::canonicalSampler(name);
            id = stage + ":" + (canon.empty() ? name : canon);
        }
        std::string value = kv.second;
        if (value.find(':') != std::string::npos) {
            m_texture_notes.push_back(key + ": resource textures are not read yet");
            continue;
        }
        if (value.find(' ') != std::string::npos) {
            CustomTexture c;
            std::string why;
            if (loadRawTexture(value, c, why)) {
                c.key = id;
                m_custom_tex.push_back(c);
                m_texture_notes.push_back(key + ": " + value + " loaded");
            } else {
                m_texture_notes.push_back(key + ": " + why);
            }
            continue;
        }
        std::string rel = !value.empty() && value[0] == '/' ? value.substr(1) : value;
        std::string path = (fs::path(m_pack.shadersDir()) / rel).string();
        Ref<Image> img = Image::load_from_file(String::utf8(path.c_str()));
        if (img.is_null() || img->is_empty()) {
            m_texture_notes.push_back(key + ": cannot read " + value);
            continue;
        }
        img->decompress();
        img->convert(Image::FORMAT_RGBA8);
        CustomTexture c;
        c.key = id;
        c.format = RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
        c.w = img->get_width();
        c.h = img->get_height();
        c.rgba = img->get_data();
        m_custom_tex.push_back(c);
        m_texture_notes.push_back(key + ": " + value + " loaded");
    }
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

// The standard block read back by name, for custom uniform expressions.
// "name.c.r" is element (column c, row r) of a matrix.
bool GoannaIrisEffect::lookupBuiltin(const std::string &name, iris::Value &out) const {
    std::string base = name;
    int col = -1, row = -1;
    size_t d1 = name.find('.');
    if (d1 != std::string::npos) {
        base = name.substr(0, d1);
        size_t d2 = name.find('.', d1 + 1);
        if (d2 == std::string::npos)
            return false;
        col = std::atoi(name.c_str() + d1 + 1);
        row = std::atoi(name.c_str() + d2 + 1);
        if (col < 0 || col > 3 || row < 0 || row > 3)
            return false;
    }
    const iris::Layout::Member *m = iris::standardLayout().find(base);
    if (!m)
        return false;
    const uint8_t *p = m_ubo_data.data() + m->offset;
    out = iris::Value();
    auto f = [&](int i) {
        float v;
        std::memcpy(&v, p + i * 4, 4);
        return v;
    };
    auto n = [&](int i) {
        int32_t v;
        std::memcpy(&v, p + i * 4, 4);
        return (float)v;
    };
    switch (m->type) {
    case iris::UType::Mat4:
    case iris::UType::Mat3:
        if (col < 0)
            return true; // a whole matrix has no scalar value
        out.v[0] = f(col * 4 + row);
        return true;
    case iris::UType::Mat2:
        return true;
    case iris::UType::Float:
        out.v[0] = f(0);
        return true;
    case iris::UType::Int:
    case iris::UType::Bool:
        out.v[0] = n(0);
        return true;
    case iris::UType::Vec2: case iris::UType::Vec3: case iris::UType::Vec4:
        out.n = m->type == iris::UType::Vec2 ? 2 : m->type == iris::UType::Vec3 ? 3 : 4;
        for (int i = 0; i < out.n; ++i) out.v[i] = f(i);
        return true;
    case iris::UType::IVec2: case iris::UType::IVec3: case iris::UType::IVec4:
        out.n = m->type == iris::UType::IVec2 ? 2 : m->type == iris::UType::IVec3 ? 3 : 4;
        for (int i = 0; i < out.n; ++i) out.v[i] = n(i);
        return true;
    }
    return false;
}

static void writeValue(uint8_t *dst, iris::UType t, const iris::Value &v) {
    using U = iris::UType;
    int count = 1;
    bool integer = false;
    switch (t) {
    case U::Float: break;
    case U::Int: case U::Bool: integer = true; break;
    case U::Vec2: count = 2; break;
    case U::Vec3: count = 3; break;
    case U::Vec4: count = 4; break;
    case U::IVec2: count = 2; integer = true; break;
    case U::IVec3: count = 3; integer = true; break;
    case U::IVec4: count = 4; integer = true; break;
    default: return;
    }
    for (int i = 0; i < count; ++i) {
        float x = i < v.n ? v.v[i] : 0.0f;
        if (integer) {
            int32_t k = (int32_t)x;
            std::memcpy(dst + i * 4, &k, 4);
        } else {
            std::memcpy(dst + i * 4, &x, 4);
        }
    }
}

// The pack's uniform.* and variable.* lines, once a frame, after the
// standard block is filled. A custom uniform named like a standard one
// replaces it, as in Iris.
void GoannaIrisEffect::evaluateCustom() {
    if (m_custom.defs().empty())
        return;
    m_custom.evaluate([this](const std::string &n, iris::Value &v) { return lookupBuiltin(n, v); }, m_dt);
    for (auto &d : m_custom.defs()) {
        if (!d.is_uniform)
            continue;
        const iris::Layout::Member *m = iris::standardLayout().find(d.name);
        iris::Value v;
        if (m && m_custom.value(d.name, v))
            writeValue(m_ubo_data.data() + m->offset, m->type, v);
    }
    if (!m_custom_reported) {
        std::lock_guard<std::mutex> lock(m_report_mutex);
        m_custom_unresolved = m_custom.unresolved();
        m_custom_reported = true;
    }
}

void GoannaIrisEffect::fillExtra(RenderingDevice *rd, Pass &p) {
    if (!p.extra_ubo.is_valid())
        return;
    p.extra_data.assign(p.tr.extra.paddedSize(), 0);
    static const float ident[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    static const float ortho[16] = {2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, -1, -1, 0, 1};
    static const float orthoInv[16] = {0.5f, 0, 0, 0, 0, 0.5f, 0, 0, 0, 0, 1, 0, 0.5f, 0.5f, 0, 1};
    static const float ident3[12] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
    for (auto &m : p.tr.extra.members) {
        uint8_t *dst = p.extra_data.data() + m.offset;
        iris::Value v;
        if (m_custom.value(m.name, v)) {
            writeValue(dst, m.type, v);
        } else if (m.type == iris::UType::Mat4) {
            if (m.name == "projectionMatrix")
                std::memcpy(dst, ortho, 64);
            else if (m.name == "projectionMatrixInverse")
                std::memcpy(dst, orthoInv, 64);
            else if (m.name == "modelViewMatrix" || m.name == "modelViewMatrixInverse" || m.name == "textureMatrix")
                std::memcpy(dst, ident, 64);
        } else if (m.type == iris::UType::Mat3 && m.name == "normalMatrix") {
            std::memcpy(dst, ident3, 48);
        }
    }
    PackedByteArray b;
    b.resize(p.extra_data.size());
    std::memcpy(b.ptrw(), p.extra_data.data(), p.extra_data.size());
    rd->buffer_update(p.extra_ubo, 0, b.size(), b);
}

static Projection basisToProjection(const Basis &b) {
    Projection p;
    for (int c = 0; c < 3; ++c)
        for (int r = 0; r < 3; ++r)
            p.columns[c][r] = b.rows[r][c];
    return p;
}

// The camera projection RenderSceneData gives a compositor effect is the
// one Godot 4.5 renders with: depth already mapped to Vulkan's [0, 1] and
// reversed, so z_ndc = (w - z_gl) / 2. A pack expects OpenGL's: its near
// and far, read off that matrix, came out as -0.05 and every position it
// rebuilt from depth was wrong (seen on the RTX 3090, 2026-10-13, as
// Mellow's border fog covering the whole frame). Undone row by row; a
// projection already in OpenGL's form (w row -1 with a negative z term)
// is left alone. Its y row is flipped as well, and stays flipped: the
// chain's texture coordinates run top down, as Vulkan's do
// (docs/design/iris-compat.md, "Things learnt on the way"), so a pack
// rebuilding a position from texcoord * 2 - 1 through this inverse gets
// the right sign only with the flip in it.
static Projection glProjection(const Projection &p) {
    bool reversed = p.columns[2][2] > -0.5f && p.columns[2][3] < 0.0f;
    if (!reversed)
        return p;
    Projection g = p;
    for (int c = 0; c < 4; ++c)
        g.columns[c][2] = p.columns[c][3] - 2.0f * p.columns[c][2];
    return g;
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
    m_dt = dt;
    t = std::fmod(t, 3600.0f);
    RenderSceneData *sd = rdata->get_render_scene_data();
    Transform3D cam = sd ? sd->get_cam_transform() : Transform3D();
    Projection proj = sd ? sd->get_cam_projection() : Projection();
    proj = glProjection(proj);
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
    // The pack's shadow matrices when main.gd supplies them (rung 7);
    // otherwise the camera's, so a pack that projects into shadow space
    // gets something finite.
    if (w.has_shadow) {
        putMat4("shadowModelView", w.shadow_mv);
        putMat4("shadowModelViewInverse", w.shadow_mv.inverse());
        putMat4("shadowProjection", w.shadow_proj);
        putMat4("shadowProjectionInverse", w.shadow_proj.inverse());
    } else {
        putMat4("shadowModelView", mv);
        putMat4("shadowModelViewInverse", mvInv);
        putMat4("shadowProjection", proj);
        putMat4("shadowProjectionInverse", proj.inverse());
    }
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
    // Iris's split of the position into whole nodes (floored) and the
    // fraction left, which a pack adds back for precision far out.
    auto splitPosition = [this](const char *int_name, const char *fract_name, const Vector3 &p) {
        const Vector3 whole = p.floor();
        int i[3] = {(int)whole.x, (int)whole.y, (int)whole.z};
        putInt(int_name, i, 3);
        putVec3(fract_name, p - whole);
    };
    splitPosition("cameraPositionInt", "cameraPositionFract", cam.origin);
    splitPosition("previousCameraPositionInt", "previousCameraPositionFract", m_prev_cam.origin);
    // Iris's velocity: how far the camera moved since the last frame.
    putFloat("velocity", (float)(cam.origin - m_prev_cam.origin).length());
    putFloat("cloudHeight", w.cloud_height);
    putInt1("firstPersonCamera", 1);
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
    if (w.eye_light.x >= 0 && w.eye_light.y >= 0) {
        m_eye_light = w.eye_light;
        const Vector2 target(w.eye_light.x, w.eye_light.y);
        if (!m_eye_seen) m_eye_smooth = target;
        else m_eye_smooth = m_eye_smooth.lerp(target, m_eye_half_seconds > 0.0f ?
            1.0f - std::pow(0.5f, dt / m_eye_half_seconds) : 1.0f);
        m_eye_seen = true;
    }
    int eb[2] = {m_eye_light.x, m_eye_light.y};
    putInt("eyeBrightness", eb, 2);
    eb[0] = (int)std::lround(m_eye_smooth.x);
    eb[1] = (int)std::lround(m_eye_smooth.y);
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
    // 6:00, 6000 noon, 18000 midnight. sunAngle follows the celestial orbit.
    float tod = w.tod - std::floor(w.tod);
    float wt = tod - 0.25f;
    wt -= std::floor(wt);
    float sun_angle = std::fmod(goanna::getWickedTimeOfDay(tod) + 0.75f, 1.0f);
    putFloat("sunAngle", sun_angle);
    putFloat("shadowAngle", sun_angle < 0.5f ? sun_angle : sun_angle - 0.5f);
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
    {
        // Iris smooths the centre depth with a half life the pack may set
        // (centerDepthHalflife, in seconds, 1 by default).
        float half = 1.0f;
        auto it = m_pack.consts().find("centerDepthHalflife");
        if (it != m_pack.consts().end())
            half = std::max(0.01f, (float)std::atof(it->second.c_str()));
        float raw = m_center->raw.load();
        if (m_frame == 0)
            m_center_smooth = raw;
        else
            m_center_smooth += (raw - m_center_smooth) * (1.0f - std::pow(0.5f, dt / half));
        putFloat("centerDepthSmooth", m_center_smooth);
    }
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

RID GoannaIrisEffect::depthCopy(RenderingDevice *rd, RenderSceneBuffersRD *rb, const char *name, const RID &src,
        const Vector2i &size) {
    StringName ctx("goanna_iris");
    StringName n(name);
    RID tex;
    if (rb->has_texture(ctx, n)) {
        tex = rb->get_texture(ctx, n);
    } else {
        uint32_t usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
                RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;
        tex = rb->create_texture(ctx, n, RenderingDevice::DATA_FORMAT_R32_SFLOAT, usage,
                RenderingDevice::TEXTURE_SAMPLES_1, size, 1, 1, true, false);
    }
    TypedArray<RID> t;
    t.push_back(tex);
    TypedArray<RDFramebufferPass> nopasses;
    RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
    blit(rd, src, fb, rd->framebuffer_get_format(fb), 3);
    return tex;
}

void GoannaIrisEffect::captureDepth(RenderingDevice *rd, RenderSceneBuffersRD *rb) {
    if (!ensureBlit(rd))
        return;
    RID depth = rb->get_depth_texture();
    if (depth.is_valid())
        depthCopy(rd, rb, "depth_before_translucent", depth, rb->get_internal_size());
}

Ref<GoannaIrisEffect> GoannaIrisEffect::make_depth_capture() const {
    Ref<GoannaIrisEffect> e;
    e.instantiate();
    e->m_capture = true;
    e->m_reads = m_reads;
    e->set_effect_callback_type(EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT);
    return e;
}

void GoannaIrisEffect::_render_callback(int32_t p_type, RenderData *p_render_data) {
    if (m_capture) {
        if (p_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT || !p_render_data)
            return;
        RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
        Ref<RenderSceneBuffersRD> rb = p_render_data->get_render_scene_buffers();
        if (rd && rb.is_valid() && rb->get_view_count() == 1) {
            captureDepth(rd, rb.ptr());
        }
        return;
    }
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
    ensureReads(rd, size);

    // Depth in OpenGL's convention: depthtex0 now, with everything drawn,
    // and depthtex1 from the capture taken before translucent geometry if
    // the companion effect is in the Compositor (else the same as 0).
    RID depth0 = depth.is_valid() ? depthCopy(rd, rb.ptr(), "depth_gl", depth, size) : m_dummy_depth;
    RID depth1 = rb->has_texture("goanna_iris", "depth_before_translucent")
            ? rb->get_texture("goanna_iris", "depth_before_translucent") : depth0;
    if (!m_center->pending.load() && depth.is_valid()) {
        TypedArray<RID> t;
        t.push_back(m_center_tex);
        TypedArray<RDFramebufferPass> np;
        RID cfb = FramebufferCacheRD::get_cache_multipass(t, np, 1);
        blit(rd, depth0, cfb, rd->framebuffer_get_format(cfb), 0);
        m_center->pending.store(true);
        if (rd->texture_get_data_async(m_center_tex, 0, Callable(memnew(CenterDepthCallable(m_center)))) != OK)
            m_center->pending.store(false);
    }

    fillUniforms(p_render_data, size);
    evaluateCustom();
    PackedByteArray ub;
    ub.resize(m_ubo_data.size());
    std::memcpy(ub.ptrw(), m_ubo_data.data(), m_ubo_data.size());
    rd->buffer_update(m_ubo, 0, ub.size(), ub);

    // Which side of each colortex is "current". A pass reads current and
    // writes the other, then the ones it wrote flip.
    std::array<int, 16> side = m_ct_side;
    TypedArray<RDFramebufferPass> nopasses;

    // colortex0 starts as the scene colour; the rest start cleared, or as
    // the pack's geometry programs left them where a second output draws
    // them (set_gbuffers_target).
    std::array<RID, 16> gb_source, gb_low;
    std::array<bool, 16> gb_translucent;
    {
        std::lock_guard<std::mutex> lk(m_world_mutex);
        gb_source = m_gb_source;
        gb_low = m_gb_low;
        gb_translucent = m_gb_translucent;
    }
    for (int i = 0; i < 16; ++i) {
        if (!m_ct_used[i])
            continue;
        RID a = colortex(rb.ptr(), i, side[i], size);
        RID b = colortex(rb.ptr(), i, 1 - side[i], size);
        if (i > 0 && gb_source[i].is_valid() && rd->texture_is_valid(gb_source[i])) {
            TypedArray<RID> t;
            t.push_back(a);
            RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
            if (gb_low[i].is_valid() && rd->texture_is_valid(gb_low[i]))
                blit(rd, gb_source[i], fb, rd->framebuffer_get_format(fb), 8, depth0, gb_low[i]);
            else if (gb_translucent[i] && depth1 != depth0)
                blit(rd, gb_source[i], fb, rd->framebuffer_get_format(fb), 4, depth0, depth1);
            else
                blit(rd, gb_source[i], fb, rd->framebuffer_get_format(fb), 0);
        } else if (i == 0) {
            TypedArray<RID> t;
            t.push_back(a);
            RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
            blit(rd, colour, fb, rd->framebuffer_get_format(fb), m_bridge_colour && !m_gbuffers_colour_raw ? 1 : 0);
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

    // What the geometry programs read next frame: the targets as the
    // deferred passes leave them, which is when Iris draws translucent
    // geometry.
    bool snapped = false;
    bool geometry_restored = false;
    std::set<int> prepared;
    for (auto &p : m_passes) {
        if (!geometry_restored && p.stage != "prepare") {
            // The translated geometry was drawn by Godot already. Lay its
            // pixels over any prepare background before deferred consumes
            // the targets, preserving sky pixels generated by prepare.
            // Geometry reads still use the preceding frame's snapshot.
            for (int i : prepared) {
                if (!m_ct_size[i].relative)
                    continue;
                RID source = i == 0 ? colour : gb_source[i];
                if (!source.is_valid() || !rd->texture_is_valid(source))
                    continue;
                TypedArray<RID> t;
                t.push_back(colortex(rb.ptr(), i, side[i], size));
                RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
                blit(rd, source, fb, rd->framebuffer_get_format(fb),
                        gb_low[i].is_valid() ? 9 :
                        i == 0 && m_bridge_colour && !m_gbuffers_colour_raw ? 6 : 5, depth0, gb_low[i]);
            }
            geometry_restored = true;
        }
        if (!snapped && p.stage == "composite") {
            snapshotReads(rd, rb.ptr(), side, size);
            snapped = true;
        }
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
            u->add_id(samplerFor(p, s));
            u->add_id(textureFor(p, s, rb.ptr(), depth0, depth1, side));
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
                fillExtra(rd, p);
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
        for (int i : written) {
            side[i] = 1 - side[i];
            if (p.stage == "prepare")
                prepared.insert(i);
        }
        if (p.is_final && m_bridge_colour) {
            TypedArray<RID> t;
            t.push_back(colour);
            RID ofb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
            blit(rd, finalTarget(rb.ptr(), size), ofb, rd->framebuffer_get_format(ofb), 2);
        }
    }
    if (!snapped)
        snapshotReads(rd, rb.ptr(), side, size);
    m_ct_side = side;
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

bool GoannaIrisEffect::reads_colortex(int index) const {
    return index >= 0 && index < 16 && m_ct_read[index];
}

void GoannaIrisEffect::set_gbuffers_target(int index, const RID &texture) {
    if (index < 1 || index >= 16)
        return;
    std::lock_guard<std::mutex> lk(m_world_mutex);
    m_gb_source[index] = texture;
}

void GoannaIrisEffect::set_gbuffers_low_target(int index, const RID &texture) {
    if (index < 1 || index >= 16) return;
    std::lock_guard<std::mutex> lk(m_world_mutex);
    m_gb_low[index] = texture;
}

void GoannaIrisEffect::set_gbuffers_translucent(int index, bool translucent_only) {
    if (index < 1 || index >= 16)
        return;
    std::lock_guard<std::mutex> lk(m_world_mutex);
    m_gb_translucent[index] = translucent_only;
}

bool GoannaIrisEffect::has_final() const {
    for (auto &p : m_passes)
        if (p.is_final && p.error.empty())
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// Gbuffers reads: the targets a geometry program samples

void GoannaIrisEffect::set_gbuffers_reads(const PackedInt32Array &targets, int colour_target) {
    // A target written beside colour is not necessarily a scene copy:
    // Complementary stores cloud depth in its alpha. Keep the actual pack
    // output, including alpha, rather than substituting native scene RGB.
    (void)colour_target;
    std::array<bool, 16> want{};
    for (int64_t k = 0; k < targets.size(); ++k) {
        const int i = targets[k];
        if (i < 0 || i >= 16)
            continue;
        want[i] = true;
        if (m_read_tex[i].is_null())
            m_read_tex[i].instantiate();
    }
    std::lock_guard<std::mutex> lk(m_reads->mutex);
    m_reads->want = want;
}

bool GoannaIrisEffect::sync_gbuffers_reads() {
    std::lock_guard<std::mutex> lk(m_reads->mutex);
    const uint32_t g = m_reads->generation.load(std::memory_order_acquire);
    if (g == 0 || g == m_read_seen)
        return m_read_bound;
    for (int i = 0; i < 16; ++i)
        if (m_read_tex[i].is_valid() && m_reads->tex[i].is_valid())
            m_read_tex[i]->set_texture_rd_rid(m_reads->tex[i]);
    // Texture2DRD queues its replacement on the render thread. Release the
    // old textures after those replacements, never while a global uses one.
    if (!m_reads->retired.empty()) {
        RenderingServer::get_singleton()->call_on_render_thread(
                Callable(memnew(FreeReadTextures(std::move(m_reads->retired)))));
        m_reads->retired.clear();
    }
    m_read_seen = g;
    m_read_bound = true;
    for (int i = 0; i < 16; ++i)
        if (m_reads->want[i] && !m_reads->tex[i].is_valid())
            m_read_bound = false;
    return m_read_bound;
}

Ref<Texture2DRD> GoannaIrisEffect::gbuffers_read_texture(int index) const {
    if (index < 0 || index >= 16)
        return Ref<Texture2DRD>();
    return m_read_tex[index];
}

// Render thread. Keep replaced textures alive until the main thread has
// queued the Texture2DRD updates, then free them after those updates.
void GoannaIrisEffect::ensureReads(RenderingDevice *rd, const Vector2i &screen) {
    std::lock_guard<std::mutex> lk(m_reads->mutex);
    const auto &want = m_reads->want;
    bool made = false;
    for (int i = 0; i < 16; ++i) {
        if (!want[i])
            continue;
        const Vector2i size = colortexSize(i, screen);
        if (m_reads->tex[i].is_valid() && m_reads->size[i] == size)
            continue;
        Ref<RDTextureFormat> tf;
        tf.instantiate();
        tf->set_width(size.x);
        tf->set_height(size.y);
        // Texture2DRD accepts Godot Image formats only. A pack's RGB16 or
        // RG16 target can be a valid RD texture but cannot be registered
        // as a spatial sampler. RGBA32F also preserves 16 bit UNORM data.
        tf->set_format(RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT);
        tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
                RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT);
        Ref<RDTextureView> tv;
        tv.instantiate();
        RID t = rd->texture_create(tf, tv);
        if (!t.is_valid())
            continue;
        TypedArray<RID> targets;
        targets.push_back(t);
        TypedArray<RDFramebufferPass> passes;
        RID fb = FramebufferCacheRD::get_cache_multipass(targets, passes, 1);
        PackedColorArray clear;
        clear.push_back(Color(0, 0, 0, 0));
        rd->draw_list_begin(fb, RenderingDevice::DRAW_CLEAR_COLOR_ALL, clear);
        rd->draw_list_end();
        if (m_reads->tex[i].is_valid())
            m_reads->retired.push_back(m_reads->tex[i]);
        m_reads->tex[i] = t;
        m_reads->size[i] = size;
        made = true;
    }
    if (made)
        m_reads->generation.fetch_add(1, std::memory_order_release);
}

// Render thread, in the chain after its deferred passes: every read that is
// not a scene image, for the geometry programs of the next frame.
void GoannaIrisEffect::snapshotReads(RenderingDevice *rd, RenderSceneBuffersRD *rb, const std::array<int, 16> &side,
        const Vector2i &size) {
    std::lock_guard<std::mutex> lk(m_reads->mutex);
    const auto &want = m_reads->want;
    TypedArray<RDFramebufferPass> nopasses;
    for (int i = 0; i < 16; ++i) {
        if (!want[i] || !m_ct_used[i] || !m_reads->tex[i].is_valid())
            continue;
        TypedArray<RID> t;
        t.push_back(m_reads->tex[i]);
        RID fb = FramebufferCacheRD::get_cache_multipass(t, nopasses, 1);
        blit(rd, colortex(rb, i, side[i], size), fb, rd->framebuffer_get_format(fb), 0);
    }
}

void GoannaIrisEffect::freeGpu() {
    if (!m_capture) {
        // The read textures belong to this effect, not the companion.
        std::lock_guard<std::mutex> lk(m_reads->mutex);
        std::vector<RID> rids = std::move(m_reads->retired);
        m_reads->retired.clear();
        for (int i = 0; i < 16; ++i) {
            if (!m_reads->tex[i].is_valid())
                continue;
            if (m_read_tex[i].is_valid())
                m_read_tex[i]->set_texture_rd_rid(RID());
            rids.push_back(m_reads->tex[i]);
            m_reads->tex[i] = RID();
        }
        m_read_bound = false;
        RenderingServer *rs = RenderingServer::get_singleton();
        if (rs && !rids.empty())
            rs->call_on_render_thread(Callable(memnew(FreeReadTextures(std::move(rids)))));
    }
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
    freeIf(m_sampler_nearest_repeat);
    freeIf(m_sampler_shadow);
    freeIf(m_dummy_shadow_depth);
    freeIf(m_center_tex);
    for (auto &c : m_custom_tex)
        freeIf(c.tex);
    freeIf(m_dummy_black);
    freeIf(m_dummy_white);
    freeIf(m_dummy_depth);
    freeIf(m_noise);
    m_gpu_ready = false;
}

} // namespace goanna
