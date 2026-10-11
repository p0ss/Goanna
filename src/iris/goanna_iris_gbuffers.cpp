// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Loading a pack's geometry programs into Godot shaders, and feeding them
// every frame. See goanna_iris_gbuffers.h for the threads and
// docs/design/iris-compat.md for the plan.

#include "iris/goanna_iris_gbuffers.h"

#include "iris/iris_preproc.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>

using namespace godot;

namespace goanna {

namespace {

RenderingServer::GlobalShaderParameterType globalType(const std::string &t) {
    if (t == "float") return RenderingServer::GLOBAL_VAR_TYPE_FLOAT;
    if (t == "int") return RenderingServer::GLOBAL_VAR_TYPE_INT;
    if (t == "bool") return RenderingServer::GLOBAL_VAR_TYPE_BOOL;
    if (t == "vec2") return RenderingServer::GLOBAL_VAR_TYPE_VEC2;
    if (t == "vec3") return RenderingServer::GLOBAL_VAR_TYPE_VEC3;
    if (t == "vec4") return RenderingServer::GLOBAL_VAR_TYPE_VEC4;
    if (t == "ivec2") return RenderingServer::GLOBAL_VAR_TYPE_IVEC2;
    if (t == "ivec3") return RenderingServer::GLOBAL_VAR_TYPE_IVEC3;
    if (t == "ivec4") return RenderingServer::GLOBAL_VAR_TYPE_IVEC4;
    if (t == "mat3") return RenderingServer::GLOBAL_VAR_TYPE_MAT3;
    if (t == "mat4") return RenderingServer::GLOBAL_VAR_TYPE_MAT4;
    if (t == "sampler2D") return RenderingServer::GLOBAL_VAR_TYPE_SAMPLER2D;
    return RenderingServer::GLOBAL_VAR_TYPE_FLOAT;
}

Variant zeroOf(const std::string &t) {
    if (t == "int") return 0;
    if (t == "bool") return false;
    if (t == "vec2") return Vector2();
    if (t == "vec3") return Vector3();
    if (t == "vec4") return Vector4();
    if (t == "ivec2") return Vector2i();
    if (t == "ivec3") return Vector3i();
    if (t == "ivec4") return Vector4i();
    if (t == "mat3") return Basis();
    if (t == "mat4") return Projection();
    if (t == "sampler2D") return Variant();
    return 0.0f;
}

std::string trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

// minecraft:oak_leaves[persistent=true] -> oak_leaves
std::string plainBlockName(std::string n) {
    size_t c = n.find(':');
    if (c != std::string::npos && n.compare(0, c, "minecraft") == 0) n = n.substr(c + 1);
    else if (c != std::string::npos) n = n.substr(0, c); // name:property=value
    size_t b = n.find('[');
    if (b != std::string::npos) n = n.substr(0, b);
    c = n.find(':');
    if (c != std::string::npos) n = n.substr(0, c);
    return n;
}

Projection toProjection(const Transform3D &t) { return Projection(t); }

} // namespace

void GoannaIrisGbuffers::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_pack", "path"), &GoannaIrisGbuffers::load_pack);
    ClassDB::bind_method(D_METHOD("shader", "surface"), &GoannaIrisGbuffers::shader);
    ClassDB::bind_method(D_METHOD("has_terrain"), &GoannaIrisGbuffers::has_terrain);
    ClassDB::bind_method(D_METHOD("block_ids", "block_names"), &GoannaIrisGbuffers::block_ids);
    ClassDB::bind_method(D_METHOD("block_id", "name"), &GoannaIrisGbuffers::block_id);
    ClassDB::bind_method(D_METHOD("update", "camera", "state"), &GoannaIrisGbuffers::update);
    ClassDB::bind_method(D_METHOD("report"), &GoannaIrisGbuffers::report);
    ClassDB::bind_method(D_METHOD("set_dump_dir", "dir"), &GoannaIrisGbuffers::set_dump_dir);
}

void GoannaIrisGbuffers::set_dump_dir(const String &dir) { m_dump_dir = dir.utf8().get_data(); }

Ref<Shader> GoannaIrisGbuffers::shader(int surface) const {
    if (surface < 0 || surface >= SURFACE_COUNT) return Ref<Shader>();
    return m_shaders[surface];
}

void GoannaIrisGbuffers::registerGlobal(const std::string &name, const std::string &type) {
    if (m_globals.count(name)) return;
    m_globals[name] = type;
    RenderingServer *rs = RenderingServer::get_singleton();
    StringName sn(name.c_str());
    // Another loaded pack, or an earlier load, may have made it already.
    if (rs->global_shader_parameter_get_list().has(sn)) return;
    rs->global_shader_parameter_add(sn, globalType(type), zeroOf(type));
}

void GoannaIrisGbuffers::setGlobal(const char *name, const Variant &v) {
    if (!m_globals.count(name)) return;
    RenderingServer::get_singleton()->global_shader_parameter_set(StringName(name), v);
}

bool GoannaIrisGbuffers::load_pack(const String &path) {
    std::string err;
    if (!m_pack.load(path.utf8().get_data(), err)) {
        m_load_error = err;
        UtilityFunctions::push_error(String("Goanna Iris gbuffers: ") + err.c_str());
        return false;
    }
    // oldLighting: false, true, or the name of a boolean option, which is
    // on when some program defines it outside a comment.
    bool old_lighting = true;
    auto ol = m_pack.properties().find("oldLighting");
    if (ol != m_pack.properties().end()) {
        const std::string v = trim(ol->second);
        if (v == "false") {
            old_lighting = false;
        } else if (v != "true") {
            old_lighting = false;
            std::regex def("^[ \\t]*#define[ \\t]+" + v + "\\b", std::regex::multiline);
            for (auto &n : m_pack.programNames()) {
                iris::Program p;
                std::string e2;
                if (m_pack.program(n, p, e2) && (std::regex_search(p.vsh, def) || std::regex_search(p.fsh, def))) {
                    old_lighting = true;
                    break;
                }
            }
        }
    }
    const char *wanted[SURFACE_COUNT] = {"gbuffers_terrain", "gbuffers_terrain_cutout", "gbuffers_water"};
    const iris::GbuffersSurface kinds[SURFACE_COUNT] = {iris::GbuffersSurface::ArrayOpaque,
            iris::GbuffersSurface::ArrayCutout, iris::GbuffersSurface::Translucent};
    for (int s = 0; s < SURFACE_COUNT; ++s) {
        std::string chosen;
        for (auto &n : iris::gbuffersFallback(wanted[s]))
            if (m_pack.hasProgram(n)) {
                chosen = n;
                break;
            }
        if (chosen.empty()) {
            m_error[s] = "no program";
            continue;
        }
        m_program[s] = chosen;
        iris::Program p;
        std::string perr;
        if (!m_pack.program(chosen, p, perr)) {
            m_error[s] = perr;
            continue;
        }
        iris::GbuffersOptions o;
        o.surface = kinds[s];
        o.old_lighting = old_lighting;
        o.label = m_pack.name() + "/" + chosen;
        iris::GbuffersResult r;
        std::string terr;
        if (!iris::translateGbuffers(p, o, r, terr)) {
            m_error[s] = terr;
            UtilityFunctions::push_warning(String("Goanna Iris gbuffers: ") + wanted[s] + " (" + chosen.c_str() +
                    "): " + terr.c_str());
            continue;
        }
        m_warnings[s] = r.warnings;
        m_dropped[s] = r.dropped;
        m_moves[s] = r.moves_vertices;
        // The globals must exist before Godot parses the shader.
        for (auto &g : r.globals) registerGlobal(g.first, g.second);
        if (!m_dump_dir.empty()) {
            std::error_code ec;
            std::filesystem::create_directories(m_dump_dir, ec);
            std::ofstream(m_dump_dir + "/" + wanted[s] + ".gdshader") << r.code;
        }
        Ref<Shader> sh;
        sh.instantiate();
        sh->set_code(String::utf8(r.code.c_str()));
        m_shaders[s] = sh;
    }
    parseBlockProperties((std::filesystem::path(m_pack.shadersDir()) / "block.properties").string());
    makeTextures();
    m_t0 = Time::get_singleton()->get_ticks_usec();
    return has_terrain();
}

// block.properties: block.<n>=<names>, with continuations and the pack's
// own #if options resolved by the same preprocessor the programs use.
void GoannaIrisGbuffers::parseBlockProperties(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return;
    std::stringstream ss;
    ss << f.rdbuf();
    // Comments in a properties file start with #, which the preprocessor
    // would read as directives; keep only real directives.
    std::string text, line;
    std::stringstream in(ss.str());
    while (std::getline(in, line)) {
        std::string t = trim(line);
        static const char *dirs[] = {"#if", "#ifdef", "#ifndef", "#elif", "#else", "#endif", "#define", "#undef"};
        bool directive = false;
        for (auto d : dirs)
            if (t.compare(0, std::strlen(d), d) == 0) directive = true;
        if (!t.empty() && t[0] == '#' && !directive) t.clear();
        text += (directive ? t : line) + "\n";
    }
    iris::MacroTable m;
    iris::defineMacro(m, "MC_VERSION", "12101");
    iris::defineMacro(m, "IS_IRIS");
    std::string out;
    std::vector<std::string> errs;
    iris::preprocess(text, m, out, errs);
    std::stringstream lines(out);
    std::string pending;
    while (std::getline(lines, line)) {
        std::string t = trim(line);
        if (!pending.empty()) {
            t = pending + " " + t;
            pending.clear();
        }
        if (!t.empty() && t.back() == '\\') {
            pending = t.substr(0, t.size() - 1);
            continue;
        }
        if (t.compare(0, 6, "block.") != 0) continue;
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        int id = std::atoi(t.c_str() + 6);
        std::stringstream names(t.substr(eq + 1));
        std::string n;
        while (names >> n) {
            if (n[0] == '%') {
                // a tag: %minecraft:leaves matches every *leaves block
                std::string tag = n.substr(1);
                size_t c = tag.rfind(':');
                if (c != std::string::npos) tag = tag.substr(c + 1);
                m_block_tags.push_back({tag, id});
                continue;
            }
            std::string plain = plainBlockName(n);
            if (!plain.empty() && !m_block_ids.count(plain)) m_block_ids[plain] = id;
        }
    }
}

int GoannaIrisGbuffers::block_id(const String &name) const {
    std::string n = name.utf8().get_data();
    if (n.empty()) return -1;
    auto it = m_block_ids.find(n);
    if (it != m_block_ids.end()) return it->second;
    // The client's names come from texture paths (grass_block_top,
    // water_still): try the block they belong to.
    static const char *suffixes[] = {"_top", "_side", "_bottom", "_still", "_flow", "_overlay", "_front", "_end",
            "_side_overlay", "_inner", "_outer", "_on", "_off"};
    for (auto s : suffixes) {
        size_t l = std::strlen(s);
        if (n.size() > l && n.compare(n.size() - l, l, s) == 0) {
            auto f = m_block_ids.find(n.substr(0, n.size() - l));
            if (f != m_block_ids.end()) return f->second;
        }
    }
    for (auto &t : m_block_tags) {
        std::string tag = t.first;
        std::string single = !tag.empty() && tag.back() == 's' ? tag.substr(0, tag.size() - 1) : tag;
        auto ends = [&](const std::string &x) {
            return n.size() >= x.size() && n.compare(n.size() - x.size(), x.size(), x) == 0;
        };
        if (ends(tag) || ends(single)) return t.second;
    }
    return -1;
}

PackedInt32Array GoannaIrisGbuffers::block_ids(const PackedStringArray &block_names) const {
    PackedInt32Array out;
    out.resize(512);
    for (int i = 0; i < 512; ++i) out[i] = -1;
    for (int i = 1; i < block_names.size() && i < 512; ++i) out[i] = block_id(block_names[i]);
    return out;
}

void GoannaIrisGbuffers::makeTextures() {
    auto solid = [](const Color &c) {
        Ref<Image> img = Image::create_empty(1, 1, false, Image::FORMAT_RGBA8);
        img->fill(c);
        return ImageTexture::create_from_image(img);
    };
    m_white = solid(Color(1, 1, 1, 1));
    m_black = solid(Color(0, 0, 0, 1));
    // noisetex: white noise per channel, 256 square, as packs expect by
    // default (noiseTextureResolution). Seeded, so a frame is reproducible.
    Ref<Image> noise = Image::create_empty(256, 256, false, Image::FORMAT_RGBA8);
    uint32_t x = 2463534242u;
    for (int y = 0; y < 256; ++y)
        for (int i = 0; i < 256; ++i) {
            float c[4];
            for (float &v : c) {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                v = (x & 0xffff) / 65535.0f;
            }
            noise->set_pixel(i, y, Color(c[0], c[1], c[2], c[3]));
        }
    m_noise = ImageTexture::create_from_image(noise);
    Ref<Image> lm = Image::create_empty(16, 16, false, Image::FORMAT_RGBA8);
    lm->fill(Color(1, 1, 1, 1));
    m_lightmap = ImageTexture::create_from_image(lm);
    setGlobal("iris_tex_white", m_white);
    setGlobal("iris_tex_black", m_black);
    setGlobal("iris_noisetex", m_noise);
    setGlobal("iris_lightmap", m_lightmap);
}

// The lightmap a pack multiplies lmcoord through, Minecraft's 16 by 16
// table of block light (x) against sky light (y). CUSTOM0 already holds
// Luanti's light decoded to brightness, so a texel's coordinate is a
// brightness here rather than a level, and the table only has to colour
// it: sky light takes the sky's colour by day and a dim blue at night,
// block light a warm torch colour, combined so neither saturates the other.
void GoannaIrisGbuffers::updateLightmap(float daylight, const Color &sky) {
    if (m_lightmap.is_null()) return;
    Ref<Image> img = Image::create_empty(16, 16, false, Image::FORMAT_RGBA8);
    const Color night(0.10f, 0.11f, 0.20f);
    // the sky's own tint, lifted toward white so noon is not blue
    Color day = sky.lerp(Color(1, 1, 1), 0.75f);
    Color skyc = night.lerp(day, daylight);
    const Color torch(1.0f, 0.86f, 0.64f);
    const float floor_ = 0.035f;
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x) {
            float b = x / 15.0f, s = y / 15.0f;
            Color c;
            for (int k = 0; k < 3; ++k) {
                float sv = skyc[k] * s, bv = torch[k] * b * b;
                c[k] = std::min(1.0f, floor_ + 1.0f - (1.0f - sv) * (1.0f - bv));
            }
            c.a = 1.0f;
            img->set_pixel(x, y, c);
        }
    m_lightmap->update(img);
}

void GoannaIrisGbuffers::update(Camera3D *camera, const Dictionary &state) {
    if (!camera || !has_terrain()) return;
    const uint64_t now = Time::get_singleton()->get_ticks_usec();
    const float dt = m_last_us ? (now - m_last_us) / 1e6f : 0.0f;
    m_last_us = now;
    ++m_frame;

    const Transform3D cam = camera->get_global_transform();
    const Vector3 pos = cam.origin;
    // Iris's gbufferModelView turns the player's space (world less the
    // camera position) into view space: the camera's rotation alone.
    Transform3D rot(cam.basis.inverse(), Vector3());
    const Projection mv = toProjection(rot);
    const Projection mv_inv = toProjection(rot.affine_inverse());
    const Projection proj = camera->get_camera_projection();
    const Projection proj_inv = proj.inverse();
    // The fixed function modelview takes world positions, so it carries the
    // translation: Godot's view matrix.
    const Transform3D view = cam.affine_inverse();
    const Projection gl_mv = toProjection(view);
    setGlobal("iris_gbufferModelView", mv);
    setGlobal("iris_gbufferModelViewInverse", mv_inv);
    setGlobal("iris_gbufferProjection", proj);
    setGlobal("iris_gbufferProjectionInverse", proj_inv);
    setGlobal("iris_gbufferPreviousModelView", m_frame > 1 ? m_prev_mv : mv);
    setGlobal("iris_gbufferPreviousProjection", m_frame > 1 ? m_prev_proj : proj);
    setGlobal("iris_gl_ModelViewMatrix", gl_mv);
    setGlobal("iris_gl_ModelViewMatrixInverse", toProjection(cam));
    setGlobal("iris_gl_ModelViewProjectionMatrix", proj * gl_mv);
    setGlobal("iris_gl_NormalMatrix", view.basis);
    // No shadow pass of the pack's own yet (rung 7): the shadow matrices
    // are the camera's, as GoannaIrisEffect gives them.
    setGlobal("iris_shadowModelView", mv);
    setGlobal("iris_shadowModelViewInverse", mv_inv);
    setGlobal("iris_shadowProjection", proj);
    setGlobal("iris_shadowProjectionInverse", proj_inv);
    setGlobal("iris_cameraPosition", pos);
    setGlobal("iris_previousCameraPosition", m_frame > 1 ? m_prev_cam : pos);
    setGlobal("iris_eyePosition", pos);
    setGlobal("iris_relativeEyePosition", Vector3());
    setGlobal("iris_playerLookVector", -cam.basis.get_column(2));
    setGlobal("iris_playerBodyVector", -cam.basis.get_column(2));
    m_prev_mv = mv;
    m_prev_proj = proj;
    m_prev_cam = pos;

    Vector2 size(1, 1);
    if (Viewport *vp = camera->get_viewport()) size = vp->get_visible_rect().size;
    setGlobal("iris_viewWidth", size.x);
    setGlobal("iris_viewHeight", size.y);
    setGlobal("iris_aspectRatio", size.x / std::max(size.y, 1.0f));
    setGlobal("iris_near", (float)camera->get_near());
    setGlobal("iris_far", (float)camera->get_far());
    const float t = (now - m_t0) / 1e6f;
    setGlobal("iris_frameTimeCounter", std::fmod(t, 3600.0f));
    setGlobal("iris_frameTime", dt);
    setGlobal("iris_frameCounter", m_frame % 720720);

    // The sun and moon, as view space positions 100 units out.
    Vector3 sun = state.get("sun_direction", Vector3(0, 1, 0));
    Vector3 moon = state.get("moon_direction", Vector3(0, -1, 0));
    const float tod = state.get("time_of_day", 0.5f);
    const Vector3 sun_v = cam.basis.inverse().xform(sun.normalized()) * 100.0f;
    const Vector3 moon_v = cam.basis.inverse().xform(moon.normalized()) * 100.0f;
    setGlobal("iris_sunPosition", sun_v);
    setGlobal("iris_moonPosition", moon_v);
    setGlobal("iris_shadowLightPosition", sun.y >= 0.0f ? sun_v : moon_v);
    setGlobal("iris_upPosition", cam.basis.inverse().xform(Vector3(0, 1, 0)) * 100.0f);
    // Luanti's day starts at midnight, Minecraft's at sunrise.
    float sun_angle = std::fmod(tod - 0.25f + 1.0f, 1.0f);
    setGlobal("iris_sunAngle", sun_angle);
    setGlobal("iris_shadowAngle", sun_angle < 0.5f ? sun_angle : sun_angle - 0.5f);
    setGlobal("iris_worldTime", (int)(sun_angle * 24000.0f) % 24000);
    setGlobal("iris_worldDay", 0);
    setGlobal("iris_moonPhase", 0);
    Color sky = state.get("sky_color", Color(0.5f, 0.7f, 1.0f));
    Color fog = state.get("fog_color", Color(0.7f, 0.8f, 0.9f));
    setGlobal("iris_skyColor", Vector3(sky.r, sky.g, sky.b));
    setGlobal("iris_fogColor", Vector3(fog.r, fog.g, fog.b));
    const float fog_end = state.get("fog_end", (float)camera->get_far());
    const float fog_start = state.get("fog_start", fog_end * 0.9f);
    setGlobal("iris_fogStart", fog_start);
    setGlobal("iris_fogEnd", fog_end);
    setGlobal("iris_fogDensity", 1.0f / std::max(fog_end, 1.0f));
    setGlobal("iris_fogMode", 9729); // GL_LINEAR
    setGlobal("iris_fogShape", 1);   // cylinder, as Minecraft fogs terrain
    // rainStrength rises at 0.2 a second and wetness follows it with half
    // lives of 30 s wetting and 10 s drying, as GoannaIrisEffect does.
    const float rain = state.get("rain", 0.0f);
    m_rain = rain > m_rain ? std::min(rain, m_rain + 0.2f * dt) : std::max(rain, m_rain - 0.2f * dt);
    const float hl = m_rain > m_wetness ? 30.0f : 10.0f;
    m_wetness += (m_rain - m_wetness) * (1.0f - std::exp2(-dt / hl));
    setGlobal("iris_rainStrength", m_rain);
    setGlobal("iris_wetness", m_wetness);
    const int in_water = state.get("in_water", 0);
    setGlobal("iris_isEyeInWater", in_water);
    setGlobal("iris_eyeAltitude", pos.y);
    setGlobal("iris_eyeBrightness", Vector2i(240, 240));
    setGlobal("iris_eyeBrightnessSmooth", Vector2i(240, 240));
    setGlobal("iris_alphaTestRef", 0.1f);
    setGlobal("iris_screenBrightness", 1.0f);
    setGlobal("iris_ambientLight", 0.0f);
    setGlobal("iris_hasSkylight", 1);
    setGlobal("iris_heightLimit", 384);
    setGlobal("iris_logicalHeightLimit", 384);
    setGlobal("iris_bedrockLevel", -64);
    setGlobal("iris_renderStage", 3);
    setGlobal("iris_atlasSize", Vector2i(16, 16));
    setGlobal("iris_maxPlayerHealth", 20.0f);
    setGlobal("iris_currentPlayerHealth", 20.0f);
    setGlobal("iris_maxPlayerHunger", 20.0f);
    setGlobal("iris_currentPlayerHunger", 20.0f);
    setGlobal("iris_maxPlayerAir", 300.0f);
    setGlobal("iris_currentPlayerAir", 300.0f);

    const float daylight = std::clamp(sun.normalized().y * 4.0f + 0.5f, 0.0f, 1.0f);
    updateLightmap(daylight, sky);
}

Dictionary GoannaIrisGbuffers::report() const {
    Dictionary d;
    d["pack"] = String(m_pack.name().c_str());
    if (!m_load_error.empty()) d["error"] = String(m_load_error.c_str());
    const char *names[SURFACE_COUNT] = {"terrain", "cutout", "water"};
    for (int s = 0; s < SURFACE_COUNT; ++s) {
        Dictionary e;
        e["program"] = String(m_program[s].c_str());
        e["translated"] = m_shaders[s].is_valid();
        if (!m_error[s].empty()) e["error"] = String(m_error[s].c_str());
        PackedStringArray w;
        for (auto &x : m_warnings[s]) w.push_back(String(x.c_str()));
        e["warnings"] = w;
        PackedInt32Array dr;
        for (int x : m_dropped[s]) dr.push_back(x);
        e["dropped_colortex"] = dr;
        e["moves_vertices"] = m_moves[s];
        d[names[s]] = e;
    }
    d["block_ids"] = (int)m_block_ids.size();
    return d;
}

} // namespace goanna
