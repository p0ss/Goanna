// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Offline checks of the gbuffers translator (iris_gbuffers.h) and the
// preprocessor under it (iris_preproc.h). No Godot and no GPU: it checks
// the text the translator writes, and leaves compiling that text to
// project/tests/iris_gbuffers.gd, which runs Godot's shader front end on
// it. Built on request:
//
//   cmake --build build --target check (or goanna_iris_gbuffers_test)
//   build/goanna_iris_gbuffers_test
//
// With a pack directory and an output directory it also translates the
// pack's terrain, cutout and water programs and writes each shader there,
// with its warnings, which is how a real pack is looked at:
//
//   build/goanna_iris_gbuffers_test /path/to/pack /tmp/out

#include "iris/iris_gbuffers.h"
#include "iris/iris_pack.h"
#include "iris/iris_preproc.h"

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace goanna::iris;

static int g_failures = 0;

static void check(bool ok, const std::string &what) {
    if (!ok) {
        ++g_failures;
        std::printf("FAIL: %s\n", what.c_str());
    }
}

static bool contains(const std::string &s, const std::string &part) { return s.find(part) != std::string::npos; }

static void testPreprocessor() {
    MacroTable m;
    std::string out;
    std::vector<std::string> errs;
    preprocess("#define A 2\n#define F(x, y) ((x) * (y))\n#if A > 1 && defined(A)\nint a = F(A, 3);\n#else\nint b;\n"
               "#endif\n#ifdef NOPE\nbad\n#elif A == 2\nint c = A;\n#endif\n",
            m, out, errs);
    check(errs.empty(), "preprocessor errors: " + (errs.empty() ? "" : errs[0]));
    check(contains(out, "int a = ((2) * (3));"), "function-like macro expands: " + out);
    check(!contains(out, "int b"), "#else branch skipped");
    check(contains(out, "int c = 2;"), "#elif taken");
    check(!contains(out, "bad"), "#ifdef of an undefined name skipped");
    // line numbers are kept
    int lines = 0;
    for (char c : out) lines += c == '\n';
    check(lines == 12, "line count kept, got " + std::to_string(lines));
    double v = 0;
    std::string err;
    check(evalCondition("(3 + 4) * 2 == 14 ? 1 : 0", m, v, err) && v == 1, "condition arithmetic");
    check(evalCondition("UNDEFINED_NAME == 0", m, v, err) && v == 1, "undefined names read 0");
    // A comment's newlines survive, and a float option compares.
    MacroTable m2;
    preprocess("#define SHADOW_DISTORT 0.10 // [0.0 0.1]\n/* a\nb */\n#if SHADOW_DISTORT > 0.05\nyes\n#endif\n", m2, out,
            errs);
    check(contains(out, "yes"), "float comparison in #if");
    // A macro call whose arguments run over several lines (Photon's).
    MacroTable m3;
    preprocess("#define clamp01(x) clamp(x, 0.0, 1.0)\nfloat a = clamp01(\n    1.0 - b\n);\nfloat c;\n", m3, out,
            errs);
    check(contains(out, "float a = clamp( 1.0 - b , 0.0, 1.0);") || contains(out, "clamp(1.0 - b, 0.0, 1.0)"),
            "macro call over lines expands: " + out);
    lines = 0;
    for (char c : out) lines += c == '\n';
    check(lines == 5 && contains(out, "\nfloat c;"), "and keeps the line count: " + out);

    // The pack loader's conditional pass is the same engine: a function-like
    // macro in a condition, which the loader's own evaluator could not do,
    // and text left unexpanded with its comments and # lines.
    std::map<std::string, std::string> pm = standardMacros();
    std::vector<std::string> perrs;
    std::string pout = runConditionals("#define F(x) ((x) * 2)\n#define N 3 // [1 2 3]\n#if F(2) == 4 && N == 3\n"
                                       "keep N // note\n#endif\n#Profiles\n",
            pm, &perrs, true);
    check(perrs.empty(), "conditional pass errors");
    check(contains(pout, "keep N // note"), "conditional pass keeps text unexpanded: " + pout);
    check(contains(pout, "#define F(x)") && contains(pout, "#Profiles"), "defines and # comments kept");
    check(pm.count("F") && pm["N"] == "3", "macros come back to the caller");
}

static std::string translateOne(const std::string &vsh, const std::string &fsh, GbuffersSurface s,
        GbuffersResult &r, std::string &err, bool translucent_depth = false) {
    Program p;
    p.name = "test";
    p.vsh = vsh;
    p.fsh = fsh;
    GbuffersOptions o;
    o.surface = s;
    o.label = "test";
    o.translucent_depth = translucent_depth;
    if (!translateGbuffers(p, o, r, err)) return "";
    return r.code;
}

static void testTranslator() {
    GbuffersResult r;
    std::string err;
    // Base-Shader's terrain program, in its shape.
    std::string code = translateOne(
            "#version 120\nuniform sampler2D lightmap;\nvarying vec2 texcoord;\nvarying vec4 color;\n"
            "void main() {\n texcoord = gl_MultiTexCoord0.xy;\n"
            " color = gl_Color * texture2D(lightmap, clamp(gl_MultiTexCoord1.xy / 255.0f, 0.5f / 16.0f, 15.5f / 16.0f));\n"
            " gl_Position = ftransform();\n}\n",
            "#version 120\nuniform sampler2D texture;\nuniform float viewWidth;\nvarying vec2 texcoord;\n"
            "varying vec4 color;\nvoid main() {\n vec4 albedo = texture2D(texture, texcoord) * color;\n"
            " gl_FragData[0] = albedo;\n}\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "base-like translates: " + err);
    check(contains(code, "texture(albedo_array, vec3((texcoord).xy, float(goanna_layer)))"), "atlas read goes to the array");
    check(contains(code, "texture(iris_lightmap,"), "lightmap read goes to the generated lightmap");
    check(contains(code, "global uniform sampler2D iris_lightmap"), "lightmap global declared");
    check(contains(code, "ALBEDO = goanna_to_linear(goanna_out_0.rgb);"), "colortex0 is the albedo");
    check(!r.moves_vertices, "ftransform leaves the vertex alone");
    check(contains(code, "render_mode unshaded"), "unshaded");

    // Implicit int to float conversions are written out.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "const int N = 3;\nfloat f(float x) { return x; }\n"
            "void main() {\n float a = 1;\n vec2 b = vec2(N, 2);\n float c = f(2) / N;\n"
            " a += 2 * a;\n vec3 d = vec3(0);\n gl_FragColor = vec4(a, b, c) + d.xyzz;\n}\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "conversions translate: " + err);
    check(contains(code, "float a = 1.0;"), "int literal assigned to float: " + code);
    check(contains(code, "vec2(float(N), 2.0)"), "int const in a vec constructor");
    check(contains(code, "f(2.0)"), "int argument to a float parameter");
    check(contains(code, "/ float(N)"), "int divisor promoted");
    check(contains(code, "vec3(0.0)"), "vec3(0) gets a float literal");

    // A local named like a varying, and a Godot built in name, are renamed.
    code = translateOne("varying vec3 normal;\nvoid main() { normal = gl_Normal; gl_Position = ftransform(); }\n",
            "varying vec3 normal;\nfloat g(vec3 normal) { float PI = 3.14; return normal.x * PI; }\n"
            "void main() { gl_FragData[0] = vec4(g(normal)); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "renames translate: " + err);
    check(contains(code, "vec3 normal_l2"), "parameter shadowing a varying renamed: " + code);
    check(contains(code, "float p_PI"), "PI renamed");

    // A displaced vertex is taken back through the camera matrices.
    code = translateOne("uniform mat4 gbufferModelViewInverse;\nvoid main() {\n vec4 p = gl_ModelViewMatrix * gl_Vertex;\n"
                        " p.y += 0.1;\n gl_Position = gl_ProjectionMatrix * p;\n}\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "displacement translates: " + err);
    check(r.moves_vertices, "displacement detected");
    check(contains(code, "VERTEX = goanna_unproject("), "displacement written back to VERTEX");

    // An unlocated output takes the lowest location a located one left.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "layout(location = 0) out vec4 a;\nout vec4 b;\nvoid main() { a = vec4(1.0); b = vec4(0.5); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty() && contains(code, "goanna_out_1 = vec4(0.5)"), "unlocated output after a located one: " + code);

    // Extra targets are second outputs: the camera's cull mask picks one
    // in place of the colour (Eclipse's water, in its shape).
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "/* DRAWBUFFERS:0413 */\nvoid main() { gl_FragData[0] = vec4(1.0); gl_FragData[1] = vec4(0.5);\n"
            " gl_FragData[2] = vec4(0.2); }\n",
            GbuffersSurface::Translucent, r, err);
    check(err.empty(), "mrt translates: " + err);
    check(r.dropped.empty(), "nothing dropped");
    check(r.second == std::vector<int>({1, 4}), "second outputs are colortex1 and 4");
    check(contains(code, "uint goanna_pass = (CAMERA_VISIBLE_LAYERS >> 15u) & 31u;"),
            "pass read from the cull mask: " + code);
    check(contains(code, "if (goanna_pass == 5u)\n\t\t\tgoanna_second = goanna_out_1;"), "colortex4 is output 1");
    check(contains(code, "if (goanna_pass == 2u)\n\t\t\tgoanna_second = goanna_out_2;"), "colortex1 is output 2");
    check(contains(code, "\t\tALBEDO = goanna_second.rgb;"), "a second output is written raw");
    check(contains(code, "ALPHA = clamp(goanna_second.a"), "a blended second output keeps its alpha");
    check(contains(code, "\t\tALBEDO = goanna_to_linear(goanna_out_0.rgb);"), "the colour is drawn otherwise");
    check(contains(code, "ALPHA = clamp(goanna_out_0.a"), "translucent writes alpha");
    check(contains(code, "depth_draw_opaque"), "translucent writes no depth without a chain to read it");
    code = translateOne("void main() { gl_Position = ftransform(); }\n", "void main() { gl_FragData[0] = vec4(1.0); }\n",
            GbuffersSurface::Translucent, r, err, true);
    check(contains(code, "depth_draw_always"), "translucent writes depth for a chain, as in Minecraft");

    // A struct varying (Photon's water) is carried field by field, written
    // from a local at the end of vertex() and built again at the start of
    // fragment().
    code = translateOne("struct P { vec3 a; float b; };\nflat out P params;\n"
                        "void main() { params = P(vec3(1.0), 2.0); gl_Position = ftransform(); }\n",
            "struct P { vec3 a; float b; };\nflat in P params;\n"
            "void main() { gl_FragData[0] = vec4(params.a * params.b, 1.0); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "struct varying translates: " + err);
    check(contains(code, "varying flat vec4 goanna_pk0;"), "its fields share one flat slot: " + code);
    check(!contains(code, "varying flat P"), "no struct varying left");
    check(contains(code, "\tP goanna_vx_params;") &&
                    contains(code, "goanna_pk0 = vec4(goanna_vx_params.a, goanna_vx_params.b);"),
            "vertex() writes a local and packs its fields");
    check(contains(code, "P params = P(goanna_pk0.xyz, goanna_pk0.w);"), "the fragment stage builds it again");

    // Varyings packed into as few slots as fit (MakeUp's terrain used 33
    // against Godot's 32): scalars beside vectors, flat apart from smooth,
    // ints apart from floats, a bool as a flat int, a matrix by columns, and
    // a varying the fragment stage never reads left out.
    code = translateOne("out vec3 a; out vec3 b; out float c; out float d; out vec2 e; out float unread;\n"
                        "flat out int id; flat out bool lit; out mat3 tbn;\n"
                        "void main() { a = vec3(1.0); b = vec3(2.0); c = 3.0; d = 4.0; e = vec2(5.0);\n"
                        " unread = 6.0; id = 7; lit = true; tbn = mat3(1.0); gl_FogFragCoord = 8.0;\n"
                        " gl_Position = ftransform(); }\n",
            "in vec3 a; in vec3 b; in float c; in float d; in vec2 e; in float unread;\n"
            "flat in int id; flat in bool lit; in mat3 tbn;\n"
            "float f() { return c + gl_FogFragCoord; }\n"
            "void main() { gl_FragData[0] = vec4(a + b + tbn[0] * d + vec3(e, f()) + float(id), lit ? 1.0 : 0.0); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "packed varyings translate: " + err);
    auto count = [&](const std::string &s, const std::string &w) {
        size_t n = 0;
        for (size_t k = s.find(w); k != std::string::npos; k = s.find(w, k + 1)) ++n;
        return n;
    };
    // smooth floats: a, b, three tbn columns (3 each), c, d, e, fog: 17
    // components in five slots; then one flat int slot for id and lit.
    check(count(code, "\nvarying vec") + count(code, "\nvarying float") == 5, "smooth floats in five slots: " + code);
    check(contains(code, "varying flat ivec2 goanna_pk"), "id and lit share a flat int slot");
    check(count(code, "unread") == 2, "an unread varying is a vertex local only, with no slot");
    check(contains(code, "mat3 tbn = mat3(goanna_pk"), "a matrix is rebuilt from its columns");
    check(contains(code, "(goanna_vx_lit ? 1 : 0)") && contains(code, "bool lit = (goanna_pk"),
            "a bool goes as an int");
    check(contains(code, "inout float c") || contains(code, "inout float goanna_v_FogFragCoord"),
            "a helper reading a varying takes the unpacked local");

    // Non-square matrices are square in Godot: mat2x3 is a padded mat3.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "void main() { mat2x3 m = mat2x3(vec3(1.0), vec3(0.5)); vec3 v = m * vec2(1.0, 2.0);\n"
            " vec2 w = vec3(1.0) * m; gl_FragData[0] = vec4(v + m[1], w.x); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "mat2x3 translates: " + err);
    check(contains(code, "mat3 m = mat3(vec3(1.0), vec3(0.5), vec3(0.0));"), "mat2x3 built padded: " + code);
    check(contains(code, "(m * vec3(vec2(1.0, 2.0), 0.0))"), "the vector padded to the product");
    check(contains(code, "(vec3(1.0) * m).xy"), "a row product cut back to two");

    // An integer vector meets a scalar in a bitwise operator, and an
    // attribute is declared narrower than GL supplies it (both Photon's).
    code = translateOne("attribute vec2 mc_midTexCoord;\nvarying vec2 mid;\n"
                        "void main() { mid = mc_midTexCoord; gl_Position = ftransform(); }\n",
            "varying vec2 mid;\nvoid main() { ivec2 p = ivec2(mid * 16.0) & 15; gl_FragData[0] = vec4(p, 0.0, 1.0); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty() && contains(code, "& ivec2(15)"), "scalar widened for &: " + code);
    check(contains(code, "= vec2(0.5, 0.5);"), "mc_midTexCoord as a vec2");

    // A colour-only program still masks cameras drawing other targets.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::ArrayOpaque, r, err);
    check(r.second.empty() && contains(code, "vec4 goanna_second = vec4(0.0)"),
            "colour-only programs leave secondary targets cleared");

    // A pack that keeps its colour in colortex1 draws it as the colour and
    // as colortex1's second output, where its chain looks for it.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "/* DRAWBUFFERS:1 */\nvoid main() { gl_FragData[0] = vec4(0.25); }\n", GbuffersSurface::ArrayOpaque,
            r, err);
    check(err.empty() && r.second == std::vector<int>({1}), "colortex1 colour is a second output");
    check(contains(code, "if (goanna_pass == 2u)\n\t\t\tgoanna_second = goanna_out_0;") &&
                    contains(code, "ALBEDO = goanna_to_linear(goanna_out_0.rgb);"),
            "and the colour too");

    // A cutout tests alpha at alphaTestRef.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::ArrayCutout, r, err);
    check(contains(code, "< iris_alphaTestRef"), "cutout alpha test");
    check(contains(code, "uniform float iris_alphaTestRef = 0.1;") &&
                    !contains(code, "global uniform float iris_alphaTestRef"),
            "the alpha threshold belongs to each material, not the view");
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "out vec4 art;\nvoid main() { art = vec4(0.0); }\n",
            GbuffersSurface::ArrayCutout, r, err);
    check(err.empty() && !contains(code, "iris_alphaTestRef"),
            "modern outputs own their discard; packed output alpha is not opacity");

    for (auto surface : {GbuffersSurface::SingleCutout, GbuffersSurface::Translucent}) {
        code = translateOne("void main() { gl_Position = ftransform(); }\n",
                "void main() { gl_FragData[0] = vec4(1.0); }\n", surface, r, err);
        check(err.empty() && contains(code, "uniform bool single_sided = false;") &&
                        contains(code, "single_sided && !FRONT_FACING"),
                "shared single-texture programs preserve per-material face culling");
    }

    // Globals initialised from uniforms become functions.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "uniform ivec2 eyeBrightnessSmooth;\nfloat inCave = 1.0 - float(eyeBrightnessSmooth.y)/240;\n"
            "void main() { gl_FragData[0] = vec4(inCave); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "lazy global translates: " + err);
    check(contains(code, "goanna_global_inCave()"), "global variable becomes a function: " + code);
    check(contains(code, "/ 240.0"), "int literal divisor in a global initialiser");
}

static void testGeometryReads() {
    Program p;
    p.name = "reads";
    p.vsh = "void main() { gl_Position = ftransform(); }";
    p.fsh = "uniform sampler2D gaux1, colortex7, depthtex1;\n"
            "void main() { vec2 uv = vec2(0.2);\n"
            "gl_FragData[0] = texture2D(gaux1, uv) + texture2D(colortex7, uv)\n"
            "+ texture2D(depthtex1, uv) + texelFetch(gaux1, ivec2(3), 2)\n"
            "+ textureGrad(gaux1, uv, vec2(0.1), vec2(0.2)); }";
    GbuffersOptions o;
    o.surface = GbuffersSurface::Translucent;
    o.data_targets.insert(7);
    GbuffersResult r;
    std::string err;
    check(translateGbuffers(p, o, r, err), "geometry reads translate: " + err);
    check(r.reads == std::vector<int>({4, 7}), "legacy and modern target reads are collected");
    check(contains(r.code, "texture(iris_colortex4, goanna_screen_uv"), "screen reads flip rows");
    check(contains(r.code, "texture(iris_colortex7, uv)"), "data map coordinates stay unchanged");
    check(contains(r.code, "hint_depth_texture") && contains(r.code, "goanna_gl_depth(texture("),
            "water reads the opaque scene depth in OpenGL convention");
    check(contains(r.code, "textureSize(iris_colortex4, 2)"), "integer reads flip at their mip size");
    check(contains(r.code, "* vec2(1.0, -1.0)"), "screen gradients follow the flipped coordinates");
    o.shadow_pass = true;
    check(translateGbuffers(p, o, r, err) && r.reads.empty(), "shadow programs never sample scene targets");
    check(!contains(r.code, "hint_depth_texture"), "shadow programs never request scene depth");
    check(!contains(r.code, "single_sided && !FRONT_FACING"),
            "visible material culling does not override the shadow pass policy");
}

static int translatePack(const std::string &dir, const std::string &outdir) {
    Pack pack;
    std::string err;
    if (!pack.load(dir, err)) {
        std::printf("pack: %s\n", err.c_str());
        return 1;
    }
    struct Want {
        const char *program;
        GbuffersSurface surface;
    };
    const Want wants[] = {{"gbuffers_terrain", GbuffersSurface::ArrayOpaque},
            {"gbuffers_terrain_cutout", GbuffersSurface::ArrayCutout},
            {"gbuffers_water", GbuffersSurface::Translucent}};
    int failed = 0;
    for (auto &w : wants) {
        std::string chosen;
        for (auto &n : gbuffersFallback(w.program))
            if (pack.hasProgram(n)) {
                chosen = n;
                break;
            }
        if (chosen.empty()) {
            std::printf("%s: no program\n", w.program);
            continue;
        }
        Program p;
        if (!pack.program(chosen, p, err)) {
            std::printf("%s: %s\n", chosen.c_str(), err.c_str());
            ++failed;
            continue;
        }
        GbuffersOptions o;
        o.surface = w.surface;
        o.label = pack.name() + "/" + chosen;
        GbuffersResult r;
        std::string terr;
        if (!translateGbuffers(p, o, r, terr)) {
            std::printf("%s (as %s): FAILED %s\n", w.program, chosen.c_str(), terr.c_str());
            ++failed;
            continue;
        }
        std::string path = outdir + "/" + w.program + ".gdshader";
        std::ofstream(path) << r.code;
        std::printf("%s (as %s): %zu bytes -> %s\n", w.program, chosen.c_str(), r.code.size(), path.c_str());
        for (auto &wn : r.warnings) std::printf("  warning: %s\n", wn.c_str());
    }
    return failed ? 1 : 0;
}

static void testVertexLighting() {
    Program p;
    p.vsh = "varying vec4 colour; void main() { colour = gl_Color; gl_Position = ftransform(); }";
    p.fsh = "#define USE_AO\n#if defined(USE_AO)\nconst float ambientOcclusionLevel = 0.7;\n"
            "#else\nconst float ambientOcclusionLevel = 0.0;\n#endif\n"
            "varying vec4 colour; void main() { gl_FragData[0] = colour; }";
    GbuffersOptions o;
    o.separate_ao = true;
    GbuffersResult r;
    std::string err;
    check(translateGbuffers(p, o, r, err), "separate AO translation: " + err);
    check(r.ao_level > 0.699f && r.ao_level < 0.701f, "AO comes from the active conditional branch");
    check(contains(r.code, "#define GOANNA_IRIS_SEPARATE_AO"), "separate AO selects the alpha contract");
    check(!contains(r.code, "#define GOANNA_IRIS_OLD_LIGHTING"), "legacy face shading defaults off");
    check(contains(r.code, "goanna_vertex_colour(COLOR, CUSTOM2"), "pack AO uses the corner channel");
    p.vsh = "varying vec4 colour; void main() { colour = gl_MultiTexCoord1; gl_Position = ftransform(); }";
    check(translateGbuffers(p, o, r, err), "linear pack light coordinates translate");
    check(contains(r.code, "vec4(CUSTOM2.gb * 240.0"), "light coordinates do not use native brightness");
    o.old_lighting = true;
    check(translateGbuffers(p, o, r, err), "explicit old lighting translates");
    check(contains(r.code, "#define GOANNA_IRIS_OLD_LIGHTING"), "explicit old lighting is retained");
    p.fsh = "const float ambientOcclusionLevel = 0.0; varying vec4 colour;"
            "void main() { gl_FragData[0] = colour; }";
    check(translateGbuffers(p, o, r, err) && r.ao_level == 0.0f, "a pack can disable vertex AO");
}

static void testColourHandoff() {
    Program p;
    p.vsh = "void main() { gl_Position = ftransform(); }";
    p.fsh = "void main() { gl_FragData[0] = vec4(2.0, 0.5, 8.0, 1.0); }";
    GbuffersOptions o;
    o.raw_colour = true;
    GbuffersResult r;
    std::string err;
    check(translateGbuffers(p, o, r, err), "HDR hand-off translation: " + err);
    check(contains(r.code, "ALBEDO = goanna_out_0.rgb;"), "a chain gets unclamped pack colour");
    check(!contains(r.code, "ALBEDO = goanna_to_linear"), "a chain does not get a second colour conversion");
    o.raw_colour = false;
    check(translateGbuffers(p, o, r, err) && contains(r.code, "ALBEDO = goanna_to_linear"),
            "standalone geometry retains display colour conversion");
}

static void testSky() {
    Program p;
    p.vsh = "varying vec4 colour; void main() { colour = gl_Color; gl_Position = ftransform(); }";
    p.fsh = "uniform int renderStage; varying vec4 colour; void main() { "
            "gl_FragData[0] = renderStage == MC_RENDER_STAGE_STARS ? colour : vec4(0.2); }";
    GbuffersOptions o;
    o.surface = GbuffersSurface::SkyBasic;
    o.render_stage = 1;
    GbuffersResult r;
    std::string err;
    check(translateGbuffers(p, o, r, err), "sky translation: " + err);
    check(contains(r.code, "uniform int goanna_render_stage = 1;"), "sky identifies its own render stage");
    check(contains(r.code, "POSITION = vec4(goanna_gl_Position.xy, 0.0"), "sky remains behind terrain");
    check(contains(r.code, "depth_draw_never"), "sky does not occlude other geometry");
    check(!contains(r.code, "goanna_vertex_colour(COLOR"), "sky colour is independent of terrain AO");
    check(gbuffersFallback("gbuffers_skybasic") == std::vector<std::string>({"gbuffers_skybasic", "gbuffers_basic"}),
            "sky fallback does not pick lit terrain");
    p.fsh = "uniform sampler2D cloudTex, colortex7; "
            "vec4 readCloud(sampler2D map) { return texture2D(map, vec2(0.5)); } "
            "void main() { gl_FragData[0] = texture2D(cloudTex, vec2(0.5)) + "
            "readCloud(cloudTex) + texture2D(colortex7, vec2(0.5)); }";
    check(translateGbuffers(p, o, r, err), "unbound sky sampler translation: " + err);
    check(contains(r.code, "texture(iris_tex_white,"), "unbound sky sampler reads white unit zero");
    check(!contains(r.code, "iris_tex_black"), "sky sampler helpers also read white");
    check(r.reads == std::vector<int>({7}), "assigned sky colortex retains its binding");
    o.surface = GbuffersSurface::ArrayOpaque;
    check(translateGbuffers(p, o, r, err) && contains(r.code, "iris_tex_black"),
            "unsupported terrain samplers retain their existing fallback");
}

int main(int argc, char **argv) {
    if (argc == 3)
        return translatePack(argv[1], argv[2]);
    testPreprocessor();
    testTranslator();
    testGeometryReads();
    testVertexLighting();
    testSky();
    testColourHandoff();
    if (g_failures) {
        std::printf("%d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("iris gbuffers: all checks passed\n");
    return 0;
}
