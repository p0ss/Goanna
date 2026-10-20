// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The shader pack loader without a GPU: the #if evaluator and the
// conditional pass shaders.properties goes through, the custom uniform
// language, option defaults and overrides, program toggles, and the proof
// pack loading and translating. With --dump it is also the offline half of
// tools/test/shaderpack_compile.py: it loads a pack, translates its
// composite chain and writes each pass's Vulkan GLSL and a manifest, which
// the script compiles with glslang. Nothing here touches Godot.

#include "iris/iris_expr.h"
#include "iris/iris_glsl.h"
#include "iris/iris_pack.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <unistd.h>

using namespace goanna::iris;
namespace fs = std::filesystem;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

bool near(float a, float b, float eps = 1e-4f) { return std::fabs(a - b) <= eps; }

void testConditions() {
    std::map<std::string, std::string> m = standardMacros();
    m["SHADOW_QUALITY"] = "2";
    m["BLOOM"] = "";
    std::string err;
    check(conditionHolds("MC_VERSION >= 11800", m, err), "MC_VERSION compares as a number");
    check(!conditionHolds("defined MC_OS_MAC", m, err), "an undefined macro is not defined");
    check(conditionHolds("defined(BLOOM) && SHADOW_QUALITY == 2", m, err), "defined() and == combine");
    check(!conditionHolds("SHADOW_QUALITY == -1 || UNKNOWN", m, err), "an unknown identifier is 0");
    check(conditionHolds("!defined MC_OS_MAC && MC_VERSION >= 11605", m, err), "negated defined without parens");
    check(conditionHolds("(1 + 2) * 3 == 9 ? 1 : 0", m, err), "precedence and ternary");
    m["A"] = "B + 1";
    m["B"] = "A";
    conditionHolds("A > 0", m, err); // must not recurse forever
    check(true, "self referencing macros terminate");
}

void testConditionals() {
    std::map<std::string, std::string> m = standardMacros();
    m["SHADOW_QUALITY"] = "1";
    const char *text =
            "a=1\n"
            "#ifdef MC_OS_MAC\n"
            "    #define COLORED 0\n"
            "b=mac\n"
            "#elif SHADOW_QUALITY == 1\n"
            "b=one\n"
            "  #if 0\n"
            "c=never\n"
            "  #else\n"
            "c=yes\n"
            "    #define COLORED 3\n"
            "  #endif\n"
            "#else\n"
            "b=other\n"
            "#endif\n"
            "#Profiles, a comment and not a directive\n"
            "#if COLORED == 3\n"
            "d=3\n"
            "#endif\n"
            "/*\n"
            "#if 0\n"
            "#endif*/\n"
            "e=5 /* a comment\n"
            "#if 0 also commented out\n"
            "*/\n";
    std::vector<std::string> errs;
    std::string out = runConditionals(text, m, &errs);
    check(errs.empty(), "no errors in a well formed file");
    check(out.find("b=one") != std::string::npos, "#elif takes the true branch");
    check(out.find("b=mac") == std::string::npos && out.find("b=other") == std::string::npos,
            "the other branches are dropped");
    check(out.find("c=yes") != std::string::npos && out.find("c=never") == std::string::npos, "nested #if 0 / #else");
    check(out.find("d=3") != std::string::npos, "#define in a live branch is seen later");
    check(out.find("#Profiles") != std::string::npos, "a comment line is kept for the caller");
    check(errs.empty() && out.find("e=5") != std::string::npos, "directives inside a block comment are ignored");
    check(std::count(out.begin(), out.end(), '\n') == std::count(text, text + std::strlen(text), '\n'),
            "line count is kept");

    // A condition continued over lines with a backslash, as Photon writes
    // them: read whole, and the continuation not left behind as text.
    std::map<std::string, std::string> m2;
    const char *cont = "#define A\n"
                       "#if !defined B && \\\n"
                       "    defined A\n"
                       "f=yes\n"
                       "#else\n"
                       "f=no\n"
                       "#endif\n";
    std::vector<std::string> errs2;
    std::string out2 = runConditionals(cont, m2, &errs2);
    check(errs2.empty(), "a continued #if parses");
    check(out2.find("f=yes") != std::string::npos && out2.find("f=no") == std::string::npos,
            "a continued #if is evaluated whole");
    check(out2.find("defined A") == std::string::npos, "the continuation line is not left as text");
    check(std::count(out2.begin(), out2.end(), '\n') == std::count(cont, cont + std::strlen(cont), '\n'),
            "line count is kept across a continuation");
}

void testCustomUniforms() {
    CustomUniforms cu;
    std::string err;
    // BSL's time of day chain, verbatim.
    check(cu.add("float", "tAmin", false, "frac(sunAngle - 0.033333333)", err), "parse tAmin");
    check(cu.add("float", "tAlin", false,
                  "if(tAmin < 0.433333333, tAmin * 1.15384615385, tAmin * 0.882352941176 + 0.117647058824)", err),
            "parse if()");
    check(cu.add("float", "hA", false, "if(tAlin > 0.5, 1.0, 0.0)", err), "parse hA");
    check(cu.add("float", "tAfrc", false, "frac(tAlin * 2.0)", err), "parse tAfrc");
    check(cu.add("float", "tAfrs", false, "tAfrc * tAfrc * (3.0 - 2.0 * tAfrc)", err), "parse tAfrs");
    check(cu.add("float", "tAmix", false, "if(hA < 0.5, 0.3, -0.1)", err), "parse tAmix");
    check(cu.add("float", "timeAngle", true, "(tAfrc * (1.0 - tAmix) + tAfrs * tAmix + hA) * 0.5", err),
            "parse timeAngle");
    check(cu.add("float", "isCold", true,
                  "smooth(1, if(in(biome, BIOME_SNOWY_PLAINS, BIOME_FROZEN_RIVER), 1, 0), 10, 10)", err),
            "parse smooth(in())");
    check(cu.add("float", "framemod8", true, "frameCounter % 8", err), "parse %");
    check(cu.add("vec3", "lift", true, "vec3(cameraPosition.y, 2.0, -cameraPosition.x)", err), "parse vec3()");
    check(cu.add("bool", "high", true, "cameraPosition.y >= 100 && !(rainStrength > 0.5)", err), "parse bool");
    check(cu.add("int", "trunc", true, "7.9", err), "parse int");
    check(cu.add("float", "fovY", true, "1.0 / atan(1.0 / gbufferProjection.1.1) * 0.5", err),
            "parse a matrix element");
    check(!cu.add("float", "bad", true, "1 +", err), "an incomplete expression is refused");
    check(!cu.add("mat4", "m", true, "1", err), "an unsupported type is refused");

    auto builtin = [](const std::string &n, Value &v) {
        if (n == "sunAngle") { v = Value::scalar(0.25f); return true; }
        if (n == "biome") { v = Value::scalar(1); return true; }
        if (n == "frameCounter") { v = Value::scalar(13); return true; }
        if (n == "rainStrength") { v = Value::scalar(0); return true; }
        if (n == "gbufferProjection.1.1") { v = Value::scalar(2); return true; }
        if (n == "cameraPosition") {
            v.n = 3;
            v.v[0] = 4; v.v[1] = 120; v.v[2] = -5;
            return true;
        }
        return false;
    };
    cu.evaluate(builtin, 0.016f);
    Value v;
    // sunAngle 0.25 is noon: tAmin 0.216667, tAlin 0.25, timeAngle 0.25.
    check(cu.value("timeAngle", v) && near(v.v[0], 0.25f, 1e-3f), "BSL timeAngle is 0.25 at noon");
    check(cu.value("isCold", v) && v.v[0] == 0.0f, "plains is not a snowy biome");
    check(cu.value("framemod8", v) && v.v[0] == 5.0f, "13 % 8");
    check(cu.value("lift", v) && v.n == 3 && v.v[0] == 120.0f && v.v[2] == -4.0f, "vec3 with swizzles");
    check(cu.value("high", v) && v.v[0] == 1.0f, "bool from && and !");
    check(cu.value("trunc", v) && v.v[0] == 7.0f, "int truncates");
    check(cu.value("fovY", v) && near(v.v[0], 0.5f / std::atan(0.5f)), "matrix element reaches the lookup");
    check(cu.unresolved().empty(), "every name in these definitions resolves");

    // smooth() walks toward a new value rather than jumping.
    CustomUniforms s;
    s.add("float", "x", true, "smooth(level, 1.0, 1.0)", err);
    float level = 0;
    auto lb = [&](const std::string &n, Value &out) {
        if (n == "level") { out = Value::scalar(level); return true; }
        return false;
    };
    s.evaluate(lb, 0.1f);
    level = 1;
    s.evaluate(lb, 0.1f);
    s.value("x", v);
    check(v.v[0] > 0.0f && v.v[0] < 0.9f, "smooth moves part of the way in a tenth of a second");
    for (int i = 0; i < 30; ++i) s.evaluate(lb, 0.1f);
    s.value("x", v);
    check(v.v[0] > 0.99f, "smooth arrives within its fade time");

    CustomUniforms u;
    u.add("float", "q", true, "mystery + 1", err);
    u.evaluate(builtin, 0.0f);
    check(u.unresolved().size() == 1 && u.unresolved()[0] == "mystery", "an unknown name is reported");
}

void writeFile(const fs::path &p, const std::string &s) {
    fs::create_directories(p.parent_path());
    std::ofstream(p, std::ios::binary) << s;
}

void testPackOptions() {
    fs::path root = fs::temp_directory_path() / ("goanna_iris_pack_test_" + std::to_string(::getpid()));
    fs::remove_all(root);
    fs::path sh = root / "shaders";
    writeFile(sh / "lib" / "settings.glsl",
            "#define BLOOM // Bloom on or off\n"
            "//#define GODRAYS\n"
            "#define SHADOW_QUALITY 2 // [0 1 2 3]\n"
            "#define FUNC(x) (x * 2)\n"
            "#ifdef BLOOM\n"
            "  #if SHADOW_QUALITY == 2\n"
            "    const int shadowMapResolution = 840;\n"
            "  #else\n"
            "    const int shadowMapResolution = 420;\n"
            "  #endif\n"
            "  /* const bool colortex2MipmapEnabled = true; */\n"
            "#else\n"
            "  const int shadowMapResolution = 100;\n"
            "  const float inactiveOnly = 1.0;\n"
            "#endif\n");
    writeFile(sh / "composite.fsh", "#version 120\n#include \"/lib/settings.glsl\"\nvoid main() { gl_FragColor = vec4(1.0); }\n");
    writeFile(sh / "composite1.fsh", "#version 120\nvoid main() { gl_FragColor = vec4(1.0); }\n");
    writeFile(sh / "composite2.fsh", "#version 120\nvoid main() { gl_FragColor = vec4(1.0); }\n");
    writeFile(sh / "final.fsh", "#version 120\nvoid main() { gl_FragColor = vec4(1.0); }\n");
    writeFile(sh / "shaders.properties",
            "size.buffer.colortex2=0.5 0.25\n"
            "size.buffer.colortex3=192 108\n"
            "size.buffer.colortex4=nan 2\n"
            "size.buffer.colortex5=1oops 2\n"
            "size.buffer.colortex6=1e40 2\n"
            "size.buffer.colortex7=2 2 extra\n"
            "program.composite1.enabled=BLOOM\n"
            "program.composite2.enabled=GODRAYS && SHADOW_QUALITY > 1\n"
            "#if SHADOW_QUALITY == 2\n"
            "uniform.float.q=SHADOW_QUALITY_IS_NOT_A_UNIFORM + 2\n"
            "#else\n"
            "uniform.float.q=3\n"
            "#endif\n"
            "#ifdef GODRAYS\n"
            "variable.float.rays=1\n"
            "iris.features.required=COMPUTE_SHADERS, SSBO\n"
            "#endif\n");
    {
        Pack p;
        std::string err;
        check(p.load(root.string(), err), "temporary pack loads");
        check(p.consts().at("shadowMapResolution") == "840" &&
                        !p.consts().count("inactiveOnly"),
                "inactive fallback constants cannot overwrite the selected branch");
        check(p.consts().at("colortex2MipmapEnabled") == "true",
                "commented constant directives survive in active branches");
        bool relative = false;
        float x = 0, y = 0;
        check(p.bufferSize(2, relative, x, y) && relative && x == 0.5f && y == 0.25f,
                "relative buffer dimensions");
        check(p.bufferSize(3, relative, x, y) && !relative && x == 192 && y == 108,
                "absolute buffer dimensions");
        for (int i : {0, 4, 5, 6, 7})
            check(!p.bufferSize(i, relative, x, y), "absent or malformed dimensions rejected");
        check(p.options().count("BLOOM") && p.options().at("BLOOM").empty(), "boolean option on");
        check(p.optionsOff().count("GODRAYS") && !p.options().count("GODRAYS"), "commented boolean is off");
        check(p.options().count("SHADOW_QUALITY") && p.options().at("SHADOW_QUALITY") == "2", "value option default");
        check(!p.options().count("FUNC"), "a function like macro is not an option");
        auto chain = p.compositeChain();
        check(chain.size() == 3 && chain[0] == "composite" && chain[1] == "composite1" && chain[2] == "final",
                "composite2 disabled by its expression, composite1 enabled by BLOOM");
        check(p.missingFeatures().empty(), "a requirement in a dead branch does not count");
        check(p.customUniforms().defs().size() == 1 && p.customUniforms().defs()[0].source.find("+ 2") != std::string::npos,
                "the live #if branch's uniform is the one kept");
    }
    {
        Pack p;
        p.setOptionOverrides({{"BLOOM", "false"}, {"GODRAYS", "true"}, {"SHADOW_QUALITY", "1"}, {"NOPE", "1"}});
        std::string err;
        check(p.load(root.string(), err), "temporary pack loads with overrides");
        check(p.consts().at("shadowMapResolution") == "100" &&
                        p.consts().count("inactiveOnly") &&
                        !p.consts().count("colortex2MipmapEnabled"),
                "constant branches follow option overrides, including commented directives");
        check(!p.options().count("BLOOM") && p.options().count("GODRAYS"), "booleans switched by override");
        auto chain = p.compositeChain();
        check(chain.size() == 2 && chain[1] == "final", "both toggled programs now off");
        check(p.customUniforms().defs().size() == 2, "override reaches the properties conditionals");
        check(p.unknownOverrides().size() == 1 && p.unknownOverrides()[0] == "NOPE", "unknown override listed");
        check(p.missingFeatures().size() == 2 && p.missingFeatures()[1] == "SSBO", "required features listed");
        Program prog;
        p.program("composite", prog, err);
        check(prog.fsh.find("//#define BLOOM") != std::string::npos, "override rewrites the source define");
        check(prog.fsh.find("#define SHADOW_QUALITY 1") != std::string::npos, "value override rewrites the source");
    }
    {
        Pack p;
        p.setOptionOverrides({{"SHADOW_QUALITY", "1"}});
        std::string err;
        check(p.load(root.string(), err) && p.consts().at("shadowMapResolution") == "420",
                "numeric overrides select the nested constant branch");
    }
    // Prepare is a producer for geometry inputs such as MakeUp's sky.
    // Numbered programs retain numerical order, and conditional programs
    // are filtered by the same rules as deferred and composite.
    for (const char *name : {"prepare", "prepare2", "prepare10", "deferred"})
        writeFile(sh / (std::string(name) + ".fsh"),
                "#version 120\nvoid main() { gl_FragColor = vec4(1.0); }\n");
    {
        Pack p;
        std::string err;
        check(p.load(root.string(), err), "pack with prepare programs loads");
        auto chain = p.compositeChain();
        check(chain.size() == 7 && chain[0] == "prepare" && chain[1] == "prepare2" &&
                chain[2] == "prepare10" && chain[3] == "deferred",
                "prepare producers precede deferred in numerical order");
    }
    fs::remove_all(root);
}

void testProofPack() {
    Pack p;
    std::string err;
    check(p.load("project/tests/shaderpacks/proof", err), "proof pack loads");
    auto chain = p.compositeChain();
    check(chain.size() == 2, "proof pack has composite and final");
    for (auto &n : chain) {
        Program prog;
        Translated tr;
        std::string e;
        check(p.program(n, prog, e), "proof program reads");
        check(translate(prog, TranslateOptions(), tr, e), "proof program translates");
    }
}

// The chain translator on two of Photon's constructs: a varying of struct
// type, which has to be declared after its struct and takes a location per
// member, and a local named like a legacy sampler alias.
void testChainVaryings() {
    Program prog;
    prog.name = "composite";
    prog.vsh = "#version 330\n"
               "struct P { vec3 a; vec2 b[2]; float c; };\n"
               "flat out P params;\n"
               "out vec2 uv;\n"
               "void main() { params = P(vec3(1.0), vec2[2](vec2(0.0), vec2(1.0)), 2.0); uv = vec2(0.0);\n"
               "    gl_Position = vec4(0.0); }\n";
    prog.fsh = "#version 330\n"
               "struct P { vec3 a; vec2 b[2]; float c; };\n"
               "flat in P params;\n"
               "in vec2 uv;\n"
               "uniform sampler2D shadowtex0;\n"
               "float f() { float shadow = 1.0; return shadow * texelFetch(shadowtex0, ivec2(0), 0).x; }\n"
               "void main() { gl_FragData[0] = vec4(params.a * params.c * f(), 1.0); }\n";
    Translated tr;
    std::string e;
    check(translate(prog, TranslateOptions(), tr, e), "struct varying program translates");
    // Sorted by name, params comes first at 0 and takes 1 + 2 + 1 = 4
    // locations, so uv is at 4.
    check(tr.vertex.find("layout(location = 0) flat out P params;") != std::string::npos,
            "the struct varying is located where it was declared");
    check(tr.vertex.find("struct P") < tr.vertex.find("flat out P params"), "after its struct");
    check(tr.fragment.find("layout(location = 0) flat in P params;") != std::string::npos,
            "and in the fragment stage alike");
    check(tr.vertex.find("layout(location = 4) out vec2 uv;") != std::string::npos,
            "the next varying is past every member's location");
    check(tr.fragment.find("float shadow = 1.0") != std::string::npos,
            "a local named like a sampler alias the pack did not declare keeps its name");
}

// --dump PACK OUTDIR [NAME=VALUE ...]
int dump(int argc, char **argv) {
    std::string packDir = argv[2], outDir = argv[3];
    std::map<std::string, std::string> overrides;
    for (int i = 4; i < argc; ++i) {
        std::string a = argv[i];
        size_t eq = a.find('=');
        if (eq != std::string::npos) overrides[a.substr(0, eq)] = a.substr(eq + 1);
    }
    Pack p;
    p.setOptionOverrides(overrides);
    std::string err;
    fs::create_directories(outDir);
    std::ofstream man(fs::path(outDir) / "manifest.txt");
    if (!p.load(packDir, err)) {
        man << "load_error\t" << err << "\n";
        std::printf("load error: %s\n", err.c_str());
        return 2;
    }
    man << "pack\t" << p.name() << "\n";
    man << "programs\t" << p.programNames().size() << "\n";
    man << "options\t" << p.options().size() + p.optionsOff().size() << "\n";
    for (auto &n : p.unknownOverrides()) man << "unknown_override\t" << n << "\n";
    for (auto &f : p.missingFeatures()) man << "missing_feature\t" << f << "\n";
    for (auto &w : p.propertyWarnings()) man << "property_warning\t" << w << "\n";
    for (auto &n : p.disabledPrograms()) man << "disabled\t" << n << "\n";
    // Evaluate custom uniforms once with nothing but constants, to list the
    // names they read that the effect would also have to answer.
    std::set<std::string> customNames;
    for (auto &d : p.customUniforms().defs()) customNames.insert(d.name);
    man << "custom_uniforms\t" << p.customUniforms().defs().size() << "\n";
    {
        CustomUniforms cu = p.customUniforms();
        const Layout &std140 = standardLayout();
        cu.evaluate([&](const std::string &n, Value &v) {
            std::string base = n.substr(0, n.find('.'));
            const Layout::Member *mm = std140.find(base);
            if (mm && base != n && (mm->type == UType::Mat4 || mm->type == UType::Mat3)) {
                v = Value();
                return true;
            }
            if (const Layout::Member *m = std140.find(n)) {
                v = Value();
                v.n = (m->type == UType::Vec3 || m->type == UType::IVec3) ? 3
                        : (m->type == UType::Vec2 || m->type == UType::IVec2) ? 2
                        : (m->type == UType::Vec4 || m->type == UType::IVec4) ? 4 : 1;
                return true;
            }
            return false;
        }, 0.016f);
        for (auto &n : cu.unresolved()) man << "custom_unresolved\t" << n << "\n";
    }
    TranslateOptions opts;
    for (auto &n : p.compositeChain()) {
        Program prog;
        Translated tr;
        std::string e;
        man << "pass\t" << n << "\n";
        if (!p.program(n, prog, e)) {
            man << "  read_error\t" << e << "\n";
            continue;
        }
        if (!translate(prog, opts, tr, e)) {
            man << "  translate_error\t" << e << "\n";
            continue;
        }
        std::ofstream(fs::path(outDir) / (n + ".vert")) << tr.vertex;
        std::ofstream(fs::path(outDir) / (n + ".frag")) << tr.fragment;
        man << "  drawbuffers\t";
        for (int d : tr.drawbuffers) man << d << " ";
        man << "\n  samplers\t";
        for (auto &s : tr.samplers) man << s.name << " ";
        man << "\n";
        for (auto &m : tr.extra.members)
            man << "  extra_uniform\t" << m.name << "\t" << (customNames.count(m.name) ? "custom" : "zero") << "\n";
        for (auto &w : tr.warnings) man << "  warning\t" << w << "\n";
    }
    std::printf("%s: %zu passes written to %s\n", p.name().c_str(), p.compositeChain().size(), outDir.c_str());
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    if (argc >= 4 && std::strcmp(argv[1], "--dump") == 0)
        return dump(argc, argv);
    testConditions();
    testConditionals();
    testCustomUniforms();
    testPackOptions();
    testProofPack();
    testChainVaryings();
    if (g_failures) {
        std::printf("%d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_iris_pack_test: all passed\n");
    return 0;
}
