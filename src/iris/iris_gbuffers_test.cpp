// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Offline checks of the gbuffers translator (iris_gbuffers.h) and the
// preprocessor under it (iris_preproc.h). No Godot and no GPU: it checks
// the text the translator writes, and leaves compiling that text to
// project/tests/iris_gbuffers.gd, which runs Godot's shader front end on
// it. Built on request:
//
//   cmake --build build --target goanna_iris_gbuffers_test
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
}

static std::string translateOne(const std::string &vsh, const std::string &fsh, GbuffersSurface s,
        GbuffersResult &r, std::string &err) {
    Program p;
    p.name = "test";
    p.vsh = vsh;
    p.fsh = fsh;
    GbuffersOptions o;
    o.surface = s;
    o.label = "test";
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

    // Extra targets are reported, not silently lost.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "/* DRAWBUFFERS:0413 */\nvoid main() { gl_FragData[0] = vec4(1.0); gl_FragData[1] = vec4(0.5);\n"
            " gl_FragData[2] = vec4(0.2); }\n",
            GbuffersSurface::Translucent, r, err);
    check(err.empty(), "mrt translates: " + err);
    check(r.dropped.size() == 2 && r.dropped[0] == 4 && r.dropped[1] == 1, "dropped targets are colortex4 and 1");
    check(contains(code, "ALPHA = clamp(goanna_out_0.a"), "translucent writes alpha");

    // A cutout tests alpha at alphaTestRef.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::ArrayCutout, r, err);
    check(contains(code, "< iris_alphaTestRef"), "cutout alpha test");

    // Globals initialised from uniforms become functions.
    code = translateOne("void main() { gl_Position = ftransform(); }\n",
            "uniform ivec2 eyeBrightnessSmooth;\nfloat inCave = 1.0 - float(eyeBrightnessSmooth.y)/240;\n"
            "void main() { gl_FragData[0] = vec4(inCave); }\n",
            GbuffersSurface::ArrayOpaque, r, err);
    check(err.empty(), "lazy global translates: " + err);
    check(contains(code, "goanna_global_inCave()"), "global variable becomes a function: " + code);
    check(contains(code, "/ 240.0"), "int literal divisor in a global initialiser");
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

int main(int argc, char **argv) {
    if (argc == 3)
        return translatePack(argv[1], argv[2]);
    testPreprocessor();
    testTranslator();
    if (g_failures) {
        std::printf("%d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("iris gbuffers: all checks passed\n");
    return 0;
}
