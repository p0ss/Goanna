// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Translation of a shader pack's geometry programs (gbuffers_terrain,
// gbuffers_water and their fallbacks) into Godot spatial shaders, which
// then replace the node array and water shaders while a pack is loaded.
// docs/design/iris-compat.md, "Two translations, not one", is the plan;
// this is the language half of it, run against a fixed shell.
//
// The shape: preprocess both stages (iris_preproc.h), parse them
// (iris_glsl_ast.h), and emit one Godot shader. The pack's vertex main
// body becomes vertex(), its fragment main body fragment(), with every
// expression typed as it is emitted so that GLSL's implicit int to float
// conversions can be written out, which Godot requires. Fixed function
// built ins and Iris uniforms become Godot globals set each frame from the
// player's camera (GoannaIrisGbuffers), and the vertex inputs come from
// the node mesh contract in docs/systems/mesh-attributes.md: gl_Color is
// the tile tint times occlusion and face shading, gl_MultiTexCoord1 is
// CUSTOM0's block and sky light, mc_Entity.x is the pack's own number for
// the block in UV2.y. The program is unshaded and its colortex0 output is
// ALBEDO. Its other outputs are second outputs: the same shader draws one
// of them as its colour instead when the camera's cull mask says so
// (kGbuffersPassShift below), and a camera of that kind renders into a
// target the screen space chain reads as that colortex.
//
// Written from the shader pack format and the GLSL specification as
// documented, not from any loader's source. Pure string work with no Godot
// and no shared state; GoannaIrisGbuffers calls it on the main thread.
// Main function: iris::translateGbuffers.
#pragma once

#include "iris_glsl.h"
#include "iris_preproc.h"

#include <map>
#include <set>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

// What a translated program is drawn on, which decides its shell.
enum class GbuffersSurface {
    ArrayOpaque, // nodes_array.gdshader's tiles: an array texture, no alpha test
    ArrayCutout, // nodes_array_scissor.gdshader's tiles: alpha tested at alphaTestRef
    Translucent, // water.gdshader's surfaces: one texture, blended
    SingleCutout, // waving_leaves and waving_plants: one texture, alpha tested, both sides
};

// The second outputs. A camera drawing a translated program's colortex N
// output for the screen space chain carries N + 1 in the five cull mask
// bits from this one (Godot has 20 render layers; no instance is on these
// five, so they change nothing it culls). The generated fragment() reads
// CAMERA_VISIBLE_LAYERS: 2 to 16 there picks that output, raw, in place of
// the colour; 0 or 31 (every ordinary camera's full mask) draws the colour
// as before, and so does the shadow pass. project/game/effects/
// iris_targets.gd makes those cameras.
constexpr int kGbuffersPassShift = 15;
constexpr int kGbuffersPassBits = 31;

struct GbuffersOptions {
    GbuffersSurface surface = GbuffersSurface::ArrayOpaque;
    // Macros defined before each stage, after the translator's own
    // (MC_VERSION and the rest). Pack option overrides go here.
    MacroTable defines;
    // Minecraft's directional face shading in gl_Color (shaders.properties
    // oldLighting). On unless the pack turns it off.
    bool old_lighting = true;
    // Whether the translucent program writes depth, as Minecraft's water
    // does, so a screen space chain finds the water surface in depthtex0
    // and not in depthtex1. GoannaIrisGbuffers turns it on only for a pack
    // with such a chain, which is the one reader: written depth also hides
    // whatever translucent surface Godot sorts after the water, so without
    // a reader Goanna's own order is kept.
    bool translucent_depth = false;
    // A label for the header comment, usually pack/program.
    std::string label;
    // The pack's custom uniforms (uniform.* in shaders.properties), by name.
    // A program uniform named here is read through the global
    // iris_cu_<name>, which GoannaIrisGbuffers sets each frame.
    std::set<std::string> custom_uniforms;
    // The pack's shadow program rather than a gbuffers one (rung 7). Its
    // fixed function matrices are the light's (iris_shadow_gl_*), its
    // gl_Position goes straight to POSITION, converted to Vulkan's depth
    // convention and only in Goanna's shadow camera (every other camera
    // sees nothing), and its colour reaches ALBEDO as written, for
    // shadowcolor0. `surface` still says which shell it is drawn on.
    bool shadow_pass = false;
};

struct GbuffersResult {
    std::string code;           // the complete Godot shader
    std::vector<int> drawbuffers; // colortex per fragment output, as declared
    // colortex targets written that a second output camera can draw (1 to
    // 15, and whichever the colour is when it is not colortex0), ascending
    std::vector<int> second;
    std::vector<int> dropped;   // colortex targets written that cannot be expressed
    // Godot global shader parameters the code reads, each with its Godot
    // type name (float, vec3, mat4, sampler2D ...). They must exist before
    // the shader is compiled.
    std::vector<std::pair<std::string, std::string>> globals;
    std::vector<std::string> warnings;
    bool moves_vertices = false; // gl_Position is not plain ftransform()
};

bool translateGbuffers(const Program &p, const GbuffersOptions &o, GbuffersResult &out, std::string &err);

// Iris's fallback order for a geometry program, the program itself first:
// gbuffers_terrain_cutout falls to gbuffers_terrain, then textured_lit,
// textured and basic; gbuffers_water to gbuffers_terrain and on.
std::vector<std::string> gbuffersFallback(const std::string &program);

// The Godot name and type of the global a known Iris uniform or fixed
// function value is read through, or false if it is not one.
bool gbuffersGlobal(const std::string &pack_name, std::string &godot_name, std::string &godot_type);

} // namespace iris
} // namespace goanna
