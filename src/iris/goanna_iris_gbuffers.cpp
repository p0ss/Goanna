// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Loading a pack's geometry programs into Godot shaders, and feeding them
// every frame. See goanna_iris_gbuffers.h for the threads and
// docs/design/iris-compat.md for the plan.

#include "iris/goanna_iris_gbuffers.h"

#include "iris/iris_preproc.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/os.hpp>
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
#include <set>
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
    ClassDB::bind_method(D_METHOD("second_targets"), &GoannaIrisGbuffers::second_targets);
    ClassDB::bind_method(D_METHOD("set_dump_dir", "dir"), &GoannaIrisGbuffers::set_dump_dir);
    ClassDB::bind_method(D_METHOD("has_shadow"), &GoannaIrisGbuffers::has_shadow);
    ClassDB::bind_method(D_METHOD("shadow_shader", "surface"), &GoannaIrisGbuffers::shadow_shader);
    ClassDB::bind_method(D_METHOD("shadow_resolution"), &GoannaIrisGbuffers::shadow_resolution);
    ClassDB::bind_method(D_METHOD("shadow_layer"), &GoannaIrisGbuffers::shadow_layer);
    ClassDB::bind_method(D_METHOD("set_shadow", "shadow"), &GoannaIrisGbuffers::set_shadow);
    ClassDB::bind_method(D_METHOD("shadow_state"), &GoannaIrisGbuffers::shadow_state);
}

void GoannaIrisGbuffers::set_dump_dir(const String &dir) { m_dump_dir = dir.utf8().get_data(); }

Ref<Shader> GoannaIrisGbuffers::shader(int surface) const {
    if (surface < 0 || surface >= SURFACE_COUNT) return Ref<Shader>();
    return m_shaders[surface];
}

void GoannaIrisGbuffers::registerGlobal(const std::string &name, const std::string &type) {
    if (m_globals.count(name)) return;
    m_globals[name] = type;
    // Another loaded pack, or an earlier load, may have made it already.
    // Kept here rather than asked of the RenderingServer, whose list of
    // globals is an editor only call that logs an error in a game.
    // Main thread only, like every caller.
    static std::map<std::string, std::string> registered;
    auto it = registered.find(name);
    if (it != registered.end()) {
        if (it->second != type)
            UtilityFunctions::push_warning(String("Goanna Iris gbuffers: global ") + name.c_str() + " was " +
                    it->second.c_str() + ", now wanted as " + type.c_str());
        return;
    }
    registered[name] = type;
    RenderingServer::get_singleton()->global_shader_parameter_add(StringName(name.c_str()), globalType(type),
            zeroOf(type));
}

void GoannaIrisGbuffers::setGlobal(const char *name, const Variant &v) {
    if (std::strncmp(name, "iris_", 5) == 0) m_builtin[name + 5] = v;
    if (!m_globals.count(name)) return;
    RenderingServer::get_singleton()->global_shader_parameter_set(StringName(name), v);
}

bool GoannaIrisGbuffers::load_pack(const String &path) {
    std::string err;
    // GOANNA_SHADERPACK_OPTIONS, read the same way GoannaIrisEffect reads
    // it, so both halves of a pack compile with the same options.
    m_pack.setOptionOverrides(iris::parseOptionOverrides(
            OS::get_singleton()->get_environment("GOANNA_SHADERPACK_OPTIONS").utf8().get_data()));
    if (!m_pack.load(path.utf8().get_data(), err)) {
        m_load_error = err;
        UtilityFunctions::push_error(String("Goanna Iris gbuffers: ") + err.c_str());
        return false;
    }
    // oldLighting: false, true, or the name of a boolean option.
    bool old_lighting = true;
    auto ol = m_pack.properties().find("oldLighting");
    if (ol != m_pack.properties().end()) {
        const std::string v = trim(ol->second);
        if (v == "false") {
            old_lighting = false;
        } else if (v != "true") {
            // the pack's options, overrides applied, as the chain sees them
            old_lighting = m_pack.options().count(v) > 0;
        }
    }
    const char *wanted[SURFACE_COUNT] = {"gbuffers_terrain", "gbuffers_terrain_cutout", "gbuffers_water",
            "gbuffers_terrain_cutout"};
    const iris::GbuffersSurface kinds[SURFACE_COUNT] = {iris::GbuffersSurface::ArrayOpaque,
            iris::GbuffersSurface::ArrayCutout, iris::GbuffersSurface::Translucent,
            iris::GbuffersSurface::SingleCutout};
    const char *files[SURFACE_COUNT] = {"terrain", "terrain_cutout", "water", "foliage"};
    for (int s = 0; s < SURFACE_COUNT; ++s) {
        std::string chosen;
        for (auto &n : iris::gbuffersFallback(wanted[s]))
            if (m_pack.hasProgram(n) && m_pack.programEnabled(n)) {
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
        std::vector<std::string> pwarn;
        if (!m_pack.program(chosen, p, perr, &pwarn)) {
            m_error[s] = perr;
            continue;
        }
        iris::GbuffersOptions o;
        o.surface = kinds[s];
        for (auto &d : m_pack.customUniforms().defs())
            if (d.is_uniform) o.custom_uniforms.insert(d.name);
        o.old_lighting = old_lighting;
        // Only a pack with a screen space chain reads the water's depth.
        o.translucent_depth = !m_pack.compositeChain().empty();
        o.label = m_pack.name() + "/" + chosen;
        iris::GbuffersResult r;
        std::string terr;
        if (!iris::translateGbuffers(p, o, r, terr)) {
            m_error[s] = terr;
            UtilityFunctions::push_warning(String("Goanna Iris gbuffers: ") + wanted[s] + " (" + chosen.c_str() +
                    "): " + terr.c_str());
            continue;
        }
        m_warnings[s] = pwarn;
        m_warnings[s].insert(m_warnings[s].end(), r.warnings.begin(), r.warnings.end());
        m_dropped[s] = r.dropped;
        m_second[s] = r.second;
        m_moves[s] = r.moves_vertices;
        // The globals must exist before Godot parses the shader.
        for (auto &g : r.globals) registerGlobal(g.first, g.second);
        if (!m_dump_dir.empty()) {
            std::error_code ec;
            std::filesystem::create_directories(m_dump_dir, ec);
            std::ofstream(m_dump_dir + "/" + files[s] + ".gdshader") << r.code;
        }
        Ref<Shader> sh;
        sh.instantiate();
        sh->set_code(String::utf8(r.code.c_str()));
        m_shaders[s] = sh;
    }
    {
        iris::GbuffersOptions so;
        for (auto &d : m_pack.customUniforms().defs())
            if (d.is_uniform) so.custom_uniforms.insert(d.name);
        so.old_lighting = old_lighting;
        loadShadow(so);
    }
    m_custom = m_pack.customUniforms();
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
    // The conditionals against the pack's options, as iris::Pack runs them
    // over shaders.properties; # comment lines come back as they were and
    // are skipped below.
    std::map<std::string, std::string> macros = iris::standardMacros();
    for (auto &kv : m_pack.options()) macros[kv.first] = kv.second;
    std::string out = iris::runConditionals(ss.str(), macros);
    std::string line;
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
    // The shadow map until a shadow pass has drawn one: depth 1.0, so
    // nothing is in shadow, and a white shadowcolor0.
    setGlobal("iris_shadowtex0", m_white);
    setGlobal("iris_shadowtex1", m_white);
    setGlobal("iris_shadowcolor0", m_white);
}

// The lightmap a pack multiplies lmcoord through, Minecraft's 16 by 16
// table of block light (x) against sky light (y). CUSTOM0 already holds
// Luanti's light decoded to brightness, so a texel's coordinate is a
// brightness here rather than a level, and the table only has to colour
// it. As in Minecraft, full sky light at noon is white, so a vanilla-like
// pack shows its textures as they are; it fades to a dim blue at night,
// takes a little of the sky's colour at dawn and dusk, and block light is
// a warm torch colour, the two combined so neither saturates the other.
void GoannaIrisGbuffers::updateLightmap(float daylight, const Color &sky) {
    if (m_lightmap.is_null()) return;
    Ref<Image> img = Image::create_empty(16, 16, false, Image::FORMAT_RGBA8);
    const Color night(0.07f, 0.08f, 0.15f);
    const float dusk = 4.0f * daylight * (1.0f - daylight); // 1 at the half way point
    Color day = Color(1, 1, 1).lerp(sky, 0.25f * dusk);
    Color skyc = night.lerp(day, daylight);
    const Color torch(1.0f, 0.86f, 0.64f);
    const float floor_ = 0.03f;
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x) {
            float b = x / 15.0f, s = y / 15.0f;
            Color c;
            for (int k = 0; k < 3; ++k) {
                float sv = skyc[k] * s, bv = torch[k] * b;
                c[k] = std::min(1.0f, floor_ + (1.0f - floor_) * (1.0f - (1.0f - sv) * (1.0f - bv)));
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
    // The shadow matrices: the pack's own shadow space when it has a shadow
    // program (rung 7, set below once the light is known), otherwise the
    // camera's, as GoannaIrisEffect gives them.
    if (!has_shadow()) {
        setGlobal("iris_shadowModelView", mv);
        setGlobal("iris_shadowModelViewInverse", mv_inv);
        setGlobal("iris_shadowProjection", proj);
        setGlobal("iris_shadowProjectionInverse", proj_inv);
    }
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
    if (has_shadow()) updateShadow(pos, sun.y >= 0.0f ? sun : moon);
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

    // The pack's custom uniforms, from the values above, as the screen
    // space chain evaluates them for its passes.
    if (!m_custom.defs().empty()) {
        m_custom.evaluate([this](const std::string &n, iris::Value &v) { return lookupBuiltin(n, v); }, dt);
        for (auto &d : m_custom.defs()) {
            std::string g = "iris_cu_" + d.name;
            auto it = m_globals.find(g);
            iris::Value v;
            if (!d.is_uniform || it == m_globals.end() || !m_custom.value(d.name, v)) continue;
            const std::string &t = it->second;
            Variant out;
            if (t == "float") out = v.v[0];
            else if (t == "int") out = (int)v.v[0];
            else if (t == "bool") out = v.v[0] != 0.0f;
            else if (t == "vec2") out = Vector2(v.v[0], v.v[1]);
            else if (t == "vec3") out = Vector3(v.v[0], v.v[1], v.v[2]);
            else if (t == "vec4") out = Vector4(v.v[0], v.v[1], v.v[2], v.v[3]);
            else if (t == "ivec2") out = Vector2i((int)v.v[0], (int)v.v[1]);
            else if (t == "ivec3") out = Vector3i((int)v.v[0], (int)v.v[1], (int)v.v[2]);
            else continue;
            RenderingServer::get_singleton()->global_shader_parameter_set(StringName(g.c_str()), out);
        }
    }
}

// What a custom uniform reads: the value update() set this frame, a
// component of a vector, or one element of a matrix as name.column.row.
bool GoannaIrisGbuffers::lookupBuiltin(const std::string &name, iris::Value &out) const {
    std::string base = name;
    int col = -1, row = -1;
    size_t d1 = name.find('.');
    if (d1 != std::string::npos) {
        base = name.substr(0, d1);
        size_t d2 = name.find('.', d1 + 1);
        if (d2 == std::string::npos) return false;
        col = std::atoi(name.c_str() + d1 + 1);
        row = std::atoi(name.c_str() + d2 + 1);
        if (col < 0 || col > 3 || row < 0 || row > 3) return false;
    }
    auto it = m_builtin.find(base);
    if (it == m_builtin.end()) return false;
    const Variant &v = it->second;
    out = iris::Value();
    switch (v.get_type()) {
    case Variant::FLOAT: out.v[0] = (float)(double)v; return true;
    case Variant::INT: out.v[0] = (float)(int64_t)v; return true;
    case Variant::BOOL: out.v[0] = (bool)v ? 1.0f : 0.0f; return true;
    case Variant::VECTOR2: {
        Vector2 x = v;
        out.n = 2; out.v[0] = x.x; out.v[1] = x.y;
        return true;
    }
    case Variant::VECTOR2I: {
        Vector2i x = v;
        out.n = 2; out.v[0] = (float)x.x; out.v[1] = (float)x.y;
        return true;
    }
    case Variant::VECTOR3: {
        Vector3 x = v;
        out.n = 3; out.v[0] = x.x; out.v[1] = x.y; out.v[2] = x.z;
        return true;
    }
    case Variant::PROJECTION: {
        if (col < 0) return true;
        Projection p = v;
        out.v[0] = p.columns[col][row];
        return true;
    }
    case Variant::BASIS: {
        if (col < 0 || col > 2 || row > 2) return true;
        Basis b = v;
        out.v[0] = b.get_column(col)[row];
        return true;
    }
    default: return false;
    }
}

PackedInt32Array GoannaIrisGbuffers::second_targets() const {
    std::set<int> all;
    for (int s = 0; s < SURFACE_COUNT; ++s)
        if (m_shaders[s].is_valid())
            all.insert(m_second[s].begin(), m_second[s].end());
    PackedInt32Array out;
    for (int ct : all) out.push_back(ct);
    return out;
}

Dictionary GoannaIrisGbuffers::report() const {
    Dictionary d;
    d["pack"] = String(m_pack.name().c_str());
    if (!m_load_error.empty()) d["error"] = String(m_load_error.c_str());
    const char *names[SURFACE_COUNT] = {"terrain", "cutout", "water", "foliage"};
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
        PackedInt32Array so;
        for (int x : m_second[s]) so.push_back(x);
        e["second_colortex"] = so;
        e["moves_vertices"] = m_moves[s];
        d[names[s]] = e;
    }
    d["block_ids"] = (int)m_block_ids.size();
    Dictionary sh;
    sh["program"] = String(m_shadow_program.c_str());
    sh["translated"] = has_shadow();
    if (!m_shadow_error.empty()) sh["error"] = String(m_shadow_error.c_str());
    PackedStringArray sw;
    for (auto &x : m_shadow_warnings) sw.push_back(String(x.c_str()));
    for (auto &x : m_shadow_settings.notes) sw.push_back(String(x.c_str()));
    sh["warnings"] = sw;
    sh["resolution"] = m_shadow_settings.resolution;
    sh["distance"] = m_shadow_settings.distance;
    if (m_shadow.is_valid()) sh["capture"] = m_shadow->report();
    d["shadow"] = sh;
    return d;
}

// ---------------------------------------------------------------------------
// Rung 7: the pack's own shadow map

namespace {

Projection fromMat4(const iris::Mat4 m) {
    Projection p;
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) p.columns[c][r] = m[c * 4 + r];
    return p;
}

} // namespace

Ref<Shader> GoannaIrisGbuffers::shadow_shader(int surface) const {
    if (surface < 0 || surface >= SURFACE_COUNT) return Ref<Shader>();
    return m_shadow_shaders[surface];
}

void GoannaIrisGbuffers::set_shadow(const Ref<GoannaIrisShadow> &shadow) { m_shadow = shadow; }

// The shadow program, translated for each surface its copy of the terrain
// is drawn on. Water is not among them: a pack's shadow program usually
// drops water (Eclipse moves it out of the clip volume) and the
// translucent shadowtex0 against shadowtex1 split is not drawn yet.
void GoannaIrisGbuffers::loadShadow(const iris::GbuffersOptions &base) {
    m_shadow_settings = iris::readShadowSettings(m_pack.consts(), m_pack.options());
    if (!m_pack.hasProgram("shadow") || !m_pack.programEnabled("shadow")) {
        m_shadow_error = m_pack.hasProgram("shadow") ? "shadow program disabled" : "no program";
        return;
    }
    m_shadow_program = "shadow";
    iris::Program p;
    std::string perr;
    if (!m_pack.program("shadow", p, perr, &m_shadow_warnings)) {
        m_shadow_error = perr;
        return;
    }
    const int surfaces[] = {SURFACE_TERRAIN, SURFACE_CUTOUT, SURFACE_FOLIAGE};
    const iris::GbuffersSurface kinds[] = {iris::GbuffersSurface::ArrayOpaque, iris::GbuffersSurface::ArrayCutout,
            iris::GbuffersSurface::SingleCutout};
    const char *files[] = {"shadow_terrain", "shadow_cutout", "shadow_foliage"};
    for (int i = 0; i < 3; ++i) {
        iris::GbuffersOptions o = base;
        o.surface = kinds[i];
        o.shadow_pass = true;
        o.label = m_pack.name() + "/shadow";
        iris::GbuffersResult r;
        std::string terr;
        if (!iris::translateGbuffers(p, o, r, terr)) {
            m_shadow_error = terr;
            UtilityFunctions::push_warning(String("Goanna Iris gbuffers: shadow: ") + terr.c_str());
            for (auto &sh : m_shadow_shaders) sh.unref();
            return;
        }
        if (i == 0) m_shadow_warnings.insert(m_shadow_warnings.end(), r.warnings.begin(), r.warnings.end());
        for (auto &g : r.globals) registerGlobal(g.first, g.second);
        if (!m_dump_dir.empty()) {
            std::error_code ec;
            std::filesystem::create_directories(m_dump_dir, ec);
            std::ofstream(m_dump_dir + "/" + files[i] + ".gdshader") << r.code;
        }
        Ref<Shader> sh;
        sh.instantiate();
        sh->set_code(String::utf8(r.code.c_str()));
        m_shadow_shaders[surfaces[i]] = sh;
    }
}

// This frame's shadow space from the camera and the light (the sun by day,
// the moon by night, as shadowLightPosition), set for the shadow program's
// fixed function matrices and for every program's shadow uniforms.
void GoannaIrisGbuffers::updateShadow(const Vector3 &camera, const Vector3 &light) {
    const iris::ShadowSettings &st = m_shadow_settings;
    const float l[3] = {light.x, light.y, light.z};
    const float c[3] = {camera.x, camera.y, camera.z};
    iris::Mat4 mv, proj, translate, gl_mv;
    iris::shadowModelView(l, c, st.interval, mv);
    iris::shadowProjection(st.distance, st.near_plane, st.far_plane, proj);
    // The fixed function modelview takes world positions, as in the
    // gbuffers programs: shadowModelView after the camera's translation.
    for (int k = 0; k < 16; ++k) translate[k] = (k % 5 == 0) ? 1.0f : 0.0f;
    translate[12] = -camera.x;
    translate[13] = -camera.y;
    translate[14] = -camera.z;
    iris::mul(mv, translate, gl_mv);
    m_shadow_mv = fromMat4(mv);
    m_shadow_proj = fromMat4(proj);
    const Projection glmv = fromMat4(gl_mv);
    setGlobal("iris_shadowModelView", m_shadow_mv);
    setGlobal("iris_shadowModelViewInverse", m_shadow_mv.inverse());
    setGlobal("iris_shadowProjection", m_shadow_proj);
    setGlobal("iris_shadowProjectionInverse", m_shadow_proj.inverse());
    setGlobal("iris_shadow_gl_ModelViewMatrix", glmv);
    setGlobal("iris_shadow_gl_ModelViewMatrixInverse", glmv.inverse());
    setGlobal("iris_shadow_gl_ModelViewProjectionMatrix", m_shadow_proj * glmv);
    Basis nb;
    for (int col = 0; col < 3; ++col)
        for (int row = 0; row < 3; ++row) nb.rows[row][col] = mv[col * 4 + row];
    setGlobal("iris_shadow_gl_NormalMatrix", nb);
    // The light's eye in the world, for main.gd's culling camera.
    iris::Mat4 eye;
    iris::affineInverse(gl_mv, eye);
    Basis eb;
    for (int col = 0; col < 3; ++col)
        for (int row = 0; row < 3; ++row) eb.rows[row][col] = eye[col * 4 + row];
    m_shadow_eye = Transform3D(eb, Vector3(eye[12], eye[13], eye[14]));
    if (m_shadow.is_valid() && m_shadow->sync()) {
        setGlobal("iris_shadowtex0", m_shadow->shadowtex());
        setGlobal("iris_shadowtex1", m_shadow->shadowtex());
        setGlobal("iris_shadowcolor0", m_shadow->shadowcolor());
    }
}

Dictionary GoannaIrisGbuffers::shadow_state() const {
    Dictionary d;
    if (!has_shadow()) return d;
    d["shadow_model_view"] = m_shadow_mv;
    d["shadow_projection"] = m_shadow_proj;
    d["camera_transform"] = m_shadow_eye;
    d["size"] = 2.0f * m_shadow_settings.distance;
    d["near"] = m_shadow_settings.near_plane;
    d["far"] = m_shadow_settings.far_plane;
    d["resolution"] = m_shadow_settings.resolution;
    return d;
}

} // namespace goanna
