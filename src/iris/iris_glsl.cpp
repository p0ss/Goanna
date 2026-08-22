// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// See iris_glsl.h. The shape of the work: strip what Vulkan GLSL cannot take
// (#version, #extension, bare uniforms, varying/attribute), rewrite the fixed
// function built ins and legacy sampler calls, then put back a prelude that
// declares the same names the way the driver wants them: one std140 block for
// the uniforms, explicitly bound samplers, explicitly located varyings, and
// outputs that follow the program's DRAWBUFFERS declaration.

#include "iris_glsl.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <regex>
#include <sstream>

namespace goanna {
namespace iris {

// ---------------------------------------------------------------------------
// Types and std140 layout

const char *utypeName(UType t) {
    switch (t) {
    case UType::Mat4: return "mat4";
    case UType::Mat3: return "mat3";
    case UType::Mat2: return "mat2";
    case UType::Vec4: return "vec4";
    case UType::Vec3: return "vec3";
    case UType::Vec2: return "vec2";
    case UType::IVec4: return "ivec4";
    case UType::IVec3: return "ivec3";
    case UType::IVec2: return "ivec2";
    case UType::Float: return "float";
    case UType::Int: return "int";
    case UType::Bool: return "bool";
    }
    return "float";
}

bool utypeFromName(const std::string &n, UType &out) {
    static const std::pair<const char *, UType> table[] = {
        {"mat4", UType::Mat4}, {"mat3", UType::Mat3}, {"mat2", UType::Mat2},
        {"vec4", UType::Vec4}, {"vec3", UType::Vec3}, {"vec2", UType::Vec2},
        {"ivec4", UType::IVec4}, {"ivec3", UType::IVec3}, {"ivec2", UType::IVec2},
        {"float", UType::Float}, {"int", UType::Int}, {"bool", UType::Bool},
    };
    for (auto &e : table)
        if (n == e.first) { out = e.second; return true; }
    return false;
}

uint32_t utypeSize(UType t) {
    switch (t) {
    case UType::Mat4: return 64;
    case UType::Mat3: return 48;
    case UType::Mat2: return 32;
    case UType::Vec4: case UType::IVec4: return 16;
    case UType::Vec3: case UType::IVec3: return 12;
    case UType::Vec2: case UType::IVec2: return 8;
    case UType::Float: case UType::Int: case UType::Bool: return 4;
    }
    return 4;
}

uint32_t utypeAlign(UType t) {
    switch (t) {
    case UType::Mat4: case UType::Mat3: case UType::Mat2:
    case UType::Vec4: case UType::IVec4: case UType::Vec3: case UType::IVec3: return 16;
    case UType::Vec2: case UType::IVec2: return 8;
    case UType::Float: case UType::Int: case UType::Bool: return 4;
    }
    return 4;
}

void Layout::add(const std::string &name, UType t) {
    uint32_t a = utypeAlign(t);
    uint32_t off = (size + a - 1) / a * a;
    members.push_back({name, t, off});
    size = off + utypeSize(t);
}

uint32_t Layout::paddedSize() const {
    // A block's size is rounded up to its base alignment, which is 16 once it
    // holds any vector or matrix; the driver's reflection reports that size.
    return (size + 15) / 16 * 16;
}

const Layout::Member *Layout::find(const std::string &name) const {
    for (auto &m : members)
        if (m.name == name)
            return &m;
    return nullptr;
}

std::string Layout::declaration(const char *block, int set, int binding) const {
    std::ostringstream o;
    o << "layout(set = " << set << ", binding = " << binding << ", std140) uniform " << block << " {\n";
    for (auto &m : members)
        o << "    " << utypeName(m.type) << " " << m.name << ";\n";
    o << "};\n";
    return o.str();
}

const Layout &standardLayout() {
    static Layout l;
    if (!l.members.empty())
        return l;
    // Matrices first, then vectors, then scalars, so std140 padding is minimal
    // and the offsets are easy to read in a debugger.
    for (const char *n : {"gbufferModelView", "gbufferModelViewInverse", "gbufferProjection",
                 "gbufferProjectionInverse", "gbufferPreviousModelView", "gbufferPreviousProjection",
                 "shadowModelView", "shadowModelViewInverse", "shadowProjection",
                 "shadowProjectionInverse", "goanna_mvp", "goanna_mvp_inv", "goanna_mv",
                 "goanna_mv_inv", "goanna_proj", "goanna_proj_inv", "goanna_texmat0",
                 "goanna_texmat1"})
        l.add(n, UType::Mat4);
    l.add("goanna_nm", UType::Mat3);
    for (const char *n : {"entityColor", "lightningBoltPosition"})
        l.add(n, UType::Vec4);
    for (const char *n : {"cameraPosition", "previousCameraPosition", "sunPosition", "moonPosition",
                 "shadowLightPosition", "upPosition", "skyColor", "fogColor", "eyePosition",
                 "relativeEyePosition", "playerLookVector", "playerBodyVector"})
        l.add(n, UType::Vec3);
    for (const char *n : {"eyeBrightness", "eyeBrightnessSmooth", "atlasSize"})
        l.add(n, UType::IVec2);
    for (const char *n : {"viewWidth", "viewHeight", "aspectRatio", "near", "far", "frameTimeCounter",
                 "frameTime", "sunAngle", "shadowAngle", "rainStrength", "wetness", "eyeAltitude",
                 "nightVision", "blindness", "darknessFactor", "darknessLightFactor",
                 "screenBrightness", "centerDepthSmooth", "fogStart", "fogEnd", "fogDensity",
                 "playerMood", "constantMood", "thunderStrength", "ambientLight",
                 "currentPlayerHealth", "maxPlayerHealth", "currentPlayerHunger", "maxPlayerHunger",
                 "currentPlayerAir", "maxPlayerAir", "currentPlayerArmor", "maxPlayerArmor",
                 "cloudTime", "dhNearPlane", "dhFarPlane", "temperature", "rainfall"})
        l.add(n, UType::Float);
    for (const char *n : {"frameCounter", "worldTime", "worldDay", "moonPhase", "isEyeInWater", "hideGUI",
                 "heldItemId", "heldBlockLightValue", "heldItemId2", "heldBlockLightValue2", "fogMode",
                 "fogShape", "renderStage", "blockEntityId", "entityId", "currentRenderedItemId",
                 "isSpectator", "isRightHanded", "biome", "biome_category", "bedrockLevel",
                 "heightLimit", "logicalHeightLimit", "hasCeiling", "hasSkylight"})
        l.add(n, UType::Int);
    return l;
}

// ---------------------------------------------------------------------------
// Samplers

namespace {
struct SamplerSlot {
    const char *name;
    int binding;
};
const SamplerSlot kSamplers[] = {
    {"colortex0", 0}, {"colortex1", 1}, {"colortex2", 2}, {"colortex3", 3},
    {"colortex4", 4}, {"colortex5", 5}, {"colortex6", 6}, {"colortex7", 7},
    {"colortex8", 8}, {"colortex9", 9}, {"colortex10", 10}, {"colortex11", 11},
    {"colortex12", 12}, {"colortex13", 13}, {"colortex14", 14}, {"colortex15", 15},
    {"depthtex0", 16}, {"depthtex1", 17}, {"depthtex2", 18},
    {"shadowtex0", 19}, {"shadowtex1", 20}, {"shadowcolor0", 21}, {"shadowcolor1", 22},
    {"noisetex", 23}, {"gtexture", 24}, {"lightmap", 25}, {"normals", 26}, {"specular", 27},
};
const std::pair<const char *, const char *> kSamplerAliases[] = {
    {"gcolor", "colortex0"}, {"gdepth", "colortex1"}, {"gnormal", "colortex2"},
    {"composite", "colortex3"}, {"gaux1", "colortex4"}, {"gaux2", "colortex5"},
    {"gaux3", "colortex6"}, {"gaux4", "colortex7"}, {"gdepthtex", "depthtex0"},
    {"shadow", "shadowtex0"}, {"watershadow", "shadowtex1"}, {"shadowcolor", "shadowcolor0"},
};
// Names a gbuffers program may give the block atlas sampler. They are not in
// the alias table above because "texture" is also the GLSL function every
// legacy call is rewritten to, so they are only renamed when the pack has
// declared a sampler by that name, and before that rewrite happens.
const char *kAtlasSamplerNames[] = {"texture", "tex"};
} // namespace

int samplerBinding(const std::string &canonical) {
    for (auto &s : kSamplers)
        if (canonical == s.name)
            return s.binding;
    return -1;
}

std::string canonicalSampler(const std::string &name) {
    for (auto &a : kSamplerAliases)
        if (name == a.first)
            return a.second;
    for (auto n : kAtlasSamplerNames)
        if (name == n)
            return "gtexture";
    if (samplerBinding(name) >= 0)
        return name;
    return "";
}

// ---------------------------------------------------------------------------
// Text helpers

static bool isIdent(char c) { return std::isalnum((unsigned char)c) || c == '_'; }
static bool isIdentStart(char c) { return std::isalpha((unsigned char)c) || c == '_'; }

std::string stripComments(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    size_t i = 0, n = s.size();
    while (i < n) {
        if (s[i] == '/' && i + 1 < n && s[i + 1] == '/') {
            while (i < n && s[i] != '\n')
                ++i;
        } else if (s[i] == '/' && i + 1 < n && s[i + 1] == '*') {
            i += 2;
            while (i + 1 < n && !(s[i] == '*' && s[i + 1] == '/')) {
                if (s[i] == '\n')
                    out += '\n'; // keep line numbers stable
                ++i;
            }
            i += 2;
        } else {
            out += s[i++];
        }
    }
    return out;
}

// Replace whole identifier occurrences of `word` with `repl`.
static std::string replaceWord(const std::string &s, const std::string &word, const std::string &repl) {
    std::string out;
    size_t i = 0, n = s.size(), w = word.size();
    while (i < n) {
        if (s.compare(i, w, word) == 0 && (i == 0 || !isIdent(s[i - 1])) && (i + w >= n || !isIdent(s[i + w]))) {
            out += repl;
            i += w;
        } else {
            out += s[i++];
        }
    }
    return out;
}

static bool containsWord(const std::string &s, const std::string &word) {
    size_t i = 0, n = s.size(), w = word.size();
    while ((i = s.find(word, i)) != std::string::npos) {
        if ((i == 0 || !isIdent(s[i - 1])) && (i + w >= n || !isIdent(s[i + w])))
            return true;
        i += w;
    }
    return false;
}

void scanConsts(const std::string &raw, std::map<std::string, std::string> &out) {
    static const std::regex re(R"(\bconst\s+(?:int|float|bool|vec4|ivec2)\s+([A-Za-z_]\w*)\s*=\s*([^;]+);)");
    for (auto it = std::sregex_iterator(raw.begin(), raw.end(), re); it != std::sregex_iterator(); ++it) {
        std::string v = (*it)[2].str();
        while (!v.empty() && std::isspace((unsigned char)v.back()))
            v.pop_back();
        out[(*it)[1].str()] = v;
    }
}

std::vector<int> scanDrawBuffers(const std::string &raw) {
    std::vector<int> out;
    static const std::regex rt(R"(/\*\s*RENDERTARGETS\s*:\s*([0-9,\s]*)\*/)");
    static const std::regex db(R"(/\*\s*DRAWBUFFERS\s*:\s*([0-9A-Za-z]*)\s*\*/)");
    std::smatch m;
    if (std::regex_search(raw, m, rt)) {
        std::string list = m[1].str();
        std::stringstream ss(list);
        std::string tok;
        while (std::getline(ss, tok, ',')) {
            tok.erase(std::remove_if(tok.begin(), tok.end(), [](unsigned char c) { return std::isspace(c); }), tok.end());
            if (!tok.empty())
                out.push_back(std::atoi(tok.c_str()));
        }
        return out;
    }
    if (std::regex_search(raw, m, db)) {
        for (char c : m[1].str()) {
            if (c >= '0' && c <= '9')
                out.push_back(c - '0');
            else if (c >= 'A' && c <= 'F')
                out.push_back(10 + c - 'A');
            else if (c >= 'a' && c <= 'f')
                out.push_back(10 + c - 'a');
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Declaration extraction

namespace {

struct Decl {
    std::string keyword; // uniform, varying, attribute, in, out
    std::string quals;   // flat, centroid ... joined with spaces
    std::string type;
    std::string name;
    int array = 0; // 0 = not an array
};

const char *kQualifiers[] = {"flat", "smooth", "noperspective", "centroid", "invariant", "highp",
        "mediump", "lowp", "sample", "patch"};

bool isQualifier(const std::string &w) {
    for (auto q : kQualifiers)
        if (w == q)
            return true;
    return false;
}

bool isDeclKeyword(const std::string &w) {
    return w == "uniform" || w == "varying" || w == "attribute" || w == "in" || w == "out";
}

std::string readWord(const std::string &s, size_t &i) {
    while (i < s.size() && std::isspace((unsigned char)s[i]))
        ++i;
    size_t b = i;
    while (i < s.size() && isIdent(s[i]))
        ++i;
    return s.substr(b, i - b);
}

// Walks the comment free source at global scope. Each uniform, varying,
// attribute, and unlocated in/out declaration is recorded and blanked out
// (newlines kept, so glslang's line numbers still point at the pack's file).
// Anything else is left alone, including declarations that already carry a
// layout(...) qualifier, which are valid Vulkan GLSL as written.
void extractDecls(std::string &text, std::vector<Decl> &decls) {
    size_t i = 0, n = text.size();
    int brace = 0, paren = 0;
    bool stmtStart = true;
    while (i < n) {
        char c = text[i];
        if (c == '#' && stmtStart) {
            // preprocessor line, with continuations
            while (i < n) {
                if (text[i] == '\\' && i + 1 < n && text[i + 1] == '\n') { i += 2; continue; }
                if (text[i] == '\n') break;
                ++i;
            }
            stmtStart = true;
            continue;
        }
        if (std::isspace((unsigned char)c)) { ++i; continue; }
        if (c == '{') { ++brace; stmtStart = true; ++i; continue; }
        if (c == '}') { --brace; stmtStart = true; ++i; continue; }
        if (c == '(') { ++paren; ++i; continue; }
        if (c == ')') { --paren; ++i; continue; }
        if (c == ';') { stmtStart = true; ++i; continue; }
        if (brace == 0 && paren == 0 && stmtStart && isIdentStart(c)) {
            size_t j = i;
            std::string quals;
            std::string w = readWord(text, j);
            while (isQualifier(w)) {
                if (!quals.empty()) quals += ' ';
                quals += w;
                w = readWord(text, j);
            }
            if (isDeclKeyword(w)) {
                std::string keyword = w;
                // precision qualifier may follow the storage one
                std::string type = readWord(text, j);
                while (type == "highp" || type == "mediump" || type == "lowp" || isQualifier(type)) {
                    if (isQualifier(type) && type != "highp" && type != "mediump" && type != "lowp") {
                        if (!quals.empty()) quals += ' ';
                        quals += type;
                    }
                    type = readWord(text, j);
                }
                size_t end = text.find(';', j);
                if (end == std::string::npos || type.empty()) { stmtStart = false; ++i; continue; }
                // A "{" before the ";" means a block (layout-less interface
                // block); leave it alone.
                size_t lb = text.find('{', j);
                if (lb != std::string::npos && lb < end) { stmtStart = false; ++i; continue; }
                std::string rest = text.substr(j, end - j);
                // split names on commas, each "name", "name[N]", "name = init"
                std::stringstream ss(rest);
                std::string item;
                while (std::getline(ss, item, ',')) {
                    size_t k = 0;
                    std::string name = readWord(item, k);
                    if (name.empty()) continue;
                    Decl d;
                    d.keyword = keyword; d.quals = quals; d.type = type; d.name = name;
                    while (k < item.size() && std::isspace((unsigned char)item[k])) ++k;
                    if (k < item.size() && item[k] == '[') {
                        size_t rb = item.find(']', k);
                        std::string num = item.substr(k + 1, rb == std::string::npos ? std::string::npos : rb - k - 1);
                        d.array = std::max(1, std::atoi(num.c_str()));
                    }
                    decls.push_back(d);
                }
                for (size_t k = i; k <= end && k < n; ++k)
                    if (text[k] != '\n') text[k] = ' ';
                i = end + 1;
                stmtStart = true;
                continue;
            }
            stmtStart = false;
            i = std::max(j, i + 1);
            continue;
        }
        stmtStart = false;
        ++i;
    }
}

int varyingSlots(const std::string &type, int array) {
    int s = 1;
    if (type == "mat4") s = 4;
    else if (type == "mat3") s = 3;
    else if (type == "mat2") s = 2;
    return s * std::max(1, array);
}

struct Varying {
    std::string type, quals;
    int array = 0;
    bool inVertex = false, inFragment = false;
    int location = -1;
};

void stripDirectives(std::string &text) {
    // #version and #extension lines go; glslang is told what we are.
    std::string out;
    std::stringstream ss(text);
    std::string line;
    while (std::getline(ss, line)) {
        size_t k = 0;
        while (k < line.size() && std::isspace((unsigned char)line[k])) ++k;
        if (line.compare(k, 8, "#version") == 0 || line.compare(k, 10, "#extension") == 0)
            out += "\n";
        else
            out += line + "\n";
    }
    text = out;
}

const char *kFormatNames[] = {"R8", "RG8", "RGB8", "RGBA8", "R8_SNORM", "RG8_SNORM", "RGB8_SNORM",
        "RGBA8_SNORM", "R16", "RG16", "RGB16", "RGBA16", "R16_SNORM", "RG16_SNORM", "RGB16_SNORM",
        "RGBA16_SNORM", "R16F", "RG16F", "RGB16F", "RGBA16F", "R32F", "RG32F", "RGB32F", "RGBA32F",
        "R11F_G11F_B10F", "RGB10_A2", "RGB9_E5", "R8I", "R8UI", "R16I", "R16UI", "R32I", "R32UI", "RG8I",
        "RG8UI", "RG16I", "RG16UI", "RG32I", "RG32UI", "RGB8I", "RGB8UI", "RGB16I", "RGB16UI", "RGB32I",
        "RGB32UI", "RGBA8I", "RGBA8UI", "RGBA16I", "RGBA16UI", "RGBA32I", "RGBA32UI", "R3_G3_B2",
        "RGB5_A1", "RGBA4", "RGB565", "RGBA2", "SRGB8", "SRGB8_ALPHA8", "RGBA12", "RGB12", "RGB10",
        "RGB4", "RGB5", "RGBA16_SNORM"};

} // namespace

// ---------------------------------------------------------------------------
// The translation

bool translate(const Program &p, const TranslateOptions &o, Translated &out, std::string &err) {
    out = Translated();
    if (p.fsh.empty()) {
        err = "no fragment stage";
        return false;
    }
    out.drawbuffers = scanDrawBuffers(p.fsh);

    std::string vs = stripComments(p.vsh);
    std::string fs = stripComments(p.fsh);
    stripDirectives(vs);
    stripDirectives(fs);

    std::vector<Decl> vdecl, fdecl;
    extractDecls(vs, vdecl);
    extractDecls(fs, fdecl);
    // A sampler the pack called "texture" or "tex" becomes gtexture now,
    // before texture2D() calls turn into texture() and the name is ambiguous.
    for (auto *decls : {&vdecl, &fdecl})
        for (auto &d : *decls)
            if (d.keyword == "uniform" && d.type.find("sampler") != std::string::npos)
                for (auto n : kAtlasSamplerNames)
                    if (d.name == n) {
                        vs = replaceWord(vs, n, "gtexture");
                        fs = replaceWord(fs, n, "gtexture");
                        d.name = "gtexture";
                    }

    // ---- identifier rewrites, stage aware
    auto rewriteCommon = [](std::string s) {
        static const std::pair<const char *, const char *> table[] = {
            {"texture2DLod", "textureLod"}, {"texture2DProjLod", "textureProjLod"},
            {"texture2DGrad", "textureGrad"}, {"texture2DProj", "textureProj"},
            {"texture2DRect", "texture"}, {"texture2D", "texture"}, {"textureCubeLod", "textureLod"},
            {"textureCube", "texture"}, {"texture3DLod", "textureLod"}, {"texture3D", "texture"},
            {"shadow2DLod", "textureLod"}, {"shadow2D", "texture"},
            {"gl_ModelViewProjectionMatrixInverse", "goanna_mvp_inv"},
            {"gl_ModelViewProjectionMatrix", "goanna_mvp"},
            {"gl_ModelViewMatrixInverse", "goanna_mv_inv"}, {"gl_ModelViewMatrix", "goanna_mv"},
            {"gl_ProjectionMatrixInverse", "goanna_proj_inv"}, {"gl_ProjectionMatrix", "goanna_proj"},
            {"gl_NormalMatrix", "goanna_nm"},
        };
        for (auto &e : table)
            s = replaceWord(s, e.first, e.second);
        for (auto &a : kSamplerAliases)
            s = replaceWord(s, a.first, a.second);
        static const std::regex texmat(R"(gl_TextureMatrix\s*\[\s*(\d+)\s*\])");
        s = std::regex_replace(s, texmat, "goanna_texmat$1");
        static const std::regex texcoord(R"(gl_TexCoord\s*\[\s*(\d+)\s*\])");
        s = std::regex_replace(s, texcoord, "goanna_v_texcoord_$1");
        s = replaceWord(s, "gl_FogFragCoord", "goanna_v_fog");
        return s;
    };
    vs = rewriteCommon(vs);
    fs = rewriteCommon(fs);
    // vertex only
    vs = replaceWord(vs, "ftransform()", "(goanna_mvp * goanna_gl_Vertex)");
    vs = std::regex_replace(vs, std::regex(R"(\bftransform\s*\(\s*\))"), "(goanna_mvp * goanna_gl_Vertex)");
    vs = replaceWord(vs, "gl_Vertex", "goanna_gl_Vertex");
    vs = replaceWord(vs, "gl_MultiTexCoord0", "goanna_gl_MultiTexCoord0");
    vs = replaceWord(vs, "gl_MultiTexCoord1", "goanna_gl_MultiTexCoord1");
    vs = replaceWord(vs, "gl_MultiTexCoord2", "goanna_gl_MultiTexCoord1");
    vs = replaceWord(vs, "gl_Normal", "goanna_gl_Normal");
    vs = replaceWord(vs, "gl_FrontColor", "goanna_v_color");
    vs = replaceWord(vs, "gl_BackColor", "goanna_v_color");
    vs = replaceWord(vs, "gl_Color", "goanna_gl_Color");
    // fragment only
    fs = replaceWord(fs, "gl_Color", "goanna_v_color");
    fs = replaceWord(fs, "gl_FragColor", "goanna_out_0");
    fs = std::regex_replace(fs, std::regex(R"(gl_FragData\s*\[\s*(\d+)\s*\])"), "goanna_out_$1");
    // the pack's main becomes a function our main calls
    static const std::regex mainre(R"(\bvoid\s+main\s*\(\s*(void)?\s*\))");
    vs = std::regex_replace(vs, mainre, "void goanna_pack_main()");
    fs = std::regex_replace(fs, mainre, "void goanna_pack_main()");

    // ---- varyings: union over both stages, located by sorted name
    std::map<std::string, Varying> varyings;
    auto addVarying = [&](const Decl &d, bool vertex) {
        Varying &v = varyings[d.name];
        v.type = d.type;
        v.array = d.array;
        if (!d.quals.empty() && v.quals.find(d.quals) == std::string::npos) {
            if (!v.quals.empty()) v.quals += ' ';
            v.quals += d.quals;
        }
        if (vertex) v.inVertex = true; else v.inFragment = true;
    };
    // Built in varyings the rewrite produced
    for (int k = 0; k < 8; ++k) {
        std::string nm = "goanna_v_texcoord_" + std::to_string(k);
        bool inV = containsWord(vs, nm), inF = containsWord(fs, nm);
        if (inV || inF) {
            Varying &v = varyings[nm];
            v.type = "vec4"; v.inVertex = inV; v.inFragment = inF;
        }
    }
    if (containsWord(vs, "goanna_v_color") || containsWord(fs, "goanna_v_color")) {
        Varying &v = varyings["goanna_v_color"];
        v.type = "vec4"; v.inVertex = containsWord(vs, "goanna_v_color"); v.inFragment = containsWord(fs, "goanna_v_color");
    }
    if (containsWord(vs, "goanna_v_fog") || containsWord(fs, "goanna_v_fog")) {
        Varying &v = varyings["goanna_v_fog"];
        v.type = "float"; v.inVertex = containsWord(vs, "goanna_v_fog"); v.inFragment = containsWord(fs, "goanna_v_fog");
    }

    // ---- uniforms and samplers
    std::map<std::string, std::string> samplerType; // canonical -> type
    std::vector<std::string> samplerOrder;
    std::map<std::string, std::string> unknownSamplers; // name -> type
    std::vector<std::string> unknownOrder;
    std::vector<Decl> attributes;
    auto handleUniform = [&](const Decl &d) {
        bool isSampler = d.type.find("sampler") != std::string::npos || d.type.find("image") != std::string::npos;
        if (isSampler) {
            std::string canon = canonicalSampler(d.name);
            if (!canon.empty()) {
                if (!samplerType.count(canon)) samplerOrder.push_back(canon);
                samplerType[canon] = d.type;
            } else {
                if (!unknownSamplers.count(d.name)) unknownOrder.push_back(d.name);
                unknownSamplers[d.name] = d.type;
                out.warnings.push_back("unknown sampler '" + d.name + "' bound to a dummy texture");
            }
            return;
        }
        const Layout &std140 = standardLayout();
        if (const Layout::Member *m = std140.find(d.name)) {
            if (d.type != utypeName(m->type))
                out.warnings.push_back("uniform '" + d.name + "' declared " + d.type + ", supplied as " + utypeName(m->type));
            return;
        }
        UType t;
        if (d.array > 0 || !utypeFromName(d.type, t)) {
            out.warnings.push_back("uniform '" + d.name + "' of type " + d.type + (d.array ? "[]" : "") + " dropped, not representable");
            return;
        }
        if (!out.extra.find(d.name)) {
            out.extra.add(d.name, t);
            out.warnings.push_back("uniform '" + d.name + "' is not an Iris uniform, reads zero");
        }
    };
    for (auto &d : vdecl) {
        if (d.keyword == "uniform") handleUniform(d);
        else if (d.keyword == "varying" || d.keyword == "out") addVarying(d, true);
        else if (d.keyword == "attribute" || d.keyword == "in") attributes.push_back(d);
    }
    for (auto &d : fdecl) {
        if (d.keyword == "uniform") handleUniform(d);
        else if (d.keyword == "varying" || d.keyword == "in") addVarying(d, false);
        else if (d.keyword == "out") {
            // an unlocated fragment output: treat name as gl_FragData[0]
            fs = replaceWord(fs, d.name, "goanna_out_0");
        }
    }
    // samplers referenced through an alias or declared nowhere (some packs
    // rely on Iris declaring colortex for them): pick them up from use
    for (auto &s : kSamplers) {
        if ((containsWord(vs, s.name) || containsWord(fs, s.name)) && !samplerType.count(s.name)) {
            samplerOrder.push_back(s.name);
            samplerType[s.name] = "sampler2D";
        }
    }
    // Only declare samplers a stage actually references; Vulkan does not
    // mind unused declarations but the uniform set would have to bind them.
    std::vector<std::string> usedSamplers;
    for (auto &n : samplerOrder)
        if (containsWord(vs, n) || containsWord(fs, n))
            usedSamplers.push_back(n);
    std::sort(usedSamplers.begin(), usedSamplers.end(), [](const std::string &a, const std::string &b) {
        return samplerBinding(a) < samplerBinding(b);
    });
    for (auto &n : usedSamplers)
        out.samplers.push_back({n, samplerType[n], samplerBinding(n)});
    int nextUnknown = kFirstUnknownSamplerBinding;
    for (auto &n : unknownOrder)
        if (containsWord(vs, n) || containsWord(fs, n))
            out.samplers.push_back({n, unknownSamplers[n], nextUnknown++});

    // ---- locations for varyings
    int loc = 0;
    for (auto &kv : varyings) {
        kv.second.location = loc;
        loc += varyingSlots(kv.second.type, kv.second.array);
    }

    // ---- prelude
    std::ostringstream pre;
    pre << "#version 450\n";
    pre << "#define MC_VERSION 12101\n#define MC_GL_VERSION 460\n#define MC_GLSL_VERSION 460\n"
           "#define MC_OS_LINUX\n#define MC_GL_VENDOR_OTHER\n#define MC_GL_RENDERER_OTHER\n"
           "#define MC_RENDER_QUALITY 1.0\n#define MC_SHADOW_QUALITY 1.0\n#define MC_HAND_DEPTH 0.125\n"
           "#define IS_IRIS\n#define IRIS_VERSION 10800\n#define GOANNA 1\n";
    if (o.labpbr)
        pre << "#define MC_NORMAL_MAP\n#define MC_SPECULAR_MAP\n#define MC_TEXTURE_FORMAT_LAB_PBR\n";
    for (auto f : kFormatNames)
        pre << "#define " << f << " 0\n";
    pre << o.extraDefines;
    pre << standardLayout().declaration("GoannaIris", 1, 0);
    if (!out.extra.members.empty())
        pre << out.extra.declaration("GoannaIrisExtra", 1, 1);
    std::string samplerDecl;
    for (auto &s : out.samplers)
        samplerDecl += "layout(set = 0, binding = " + std::to_string(s.binding) + ") uniform " + s.type + " " + s.name + ";\n";
    std::string common = pre.str();

    // vertex stage
    std::ostringstream v;
    v << common;
    for (auto &s : out.samplers)
        if (containsWord(vs, s.name))
            v << "layout(set = 0, binding = " << s.binding << ") uniform " << s.type << " " << s.name << ";\n";
    for (auto &kv : varyings)
        if (kv.second.inVertex)
            v << "layout(location = " << kv.second.location << ") " << kv.second.quals << (kv.second.quals.empty() ? "" : " ")
              << "out " << kv.second.type << " " << kv.first << (kv.second.array ? "[" + std::to_string(kv.second.array) + "]" : "") << ";\n";
    v << "vec4 goanna_gl_Vertex = vec4(0.0);\nvec4 goanna_gl_MultiTexCoord0 = vec4(0.0);\n"
         "vec4 goanna_gl_MultiTexCoord1 = vec4(0.0, 0.0, 0.0, 1.0);\nvec4 goanna_gl_Color = vec4(1.0);\n"
         "vec3 goanna_gl_Normal = vec3(0.0, 0.0, 1.0);\n";
    for (auto &a : attributes) {
        UType t;
        if (a.array == 0 && utypeFromName(a.type, t))
            v << a.type << " " << a.name << " = " << a.type << "(0);\n";
        else
            v << a.type << " " << a.name << (a.array ? "[" + std::to_string(a.array) + "]" : "") << ";\n";
    }
    v << "#line 1\n" << vs << "\n";
    if (o.kind == ProgramKind::Composite) {
        // A full screen triangle in the [0,1] quad space Iris draws composite
        // passes in: vertices (0,0) (2,0) (0,2), clipped to the screen.
        v << "void main() {\n"
             "    vec2 q = vec2(float((gl_VertexIndex & 1) << 1), float(gl_VertexIndex & 2));\n"
             "    goanna_gl_Vertex = vec4(q, 0.0, 1.0);\n"
             "    goanna_gl_MultiTexCoord0 = vec4(q, 0.0, 1.0);\n"
             "    goanna_pack_main();\n"
             "}\n";
    } else {
        v << "void main() { goanna_pack_main(); }\n";
    }
    out.vertex = v.str();

    // fragment stage
    std::ostringstream f;
    f << common;
    for (auto &s : out.samplers)
        if (containsWord(fs, s.name))
            f << "layout(set = 0, binding = " << s.binding << ") uniform " << s.type << " " << s.name << ";\n";
    for (auto &kv : varyings)
        if (kv.second.inFragment)
            f << "layout(location = " << kv.second.location << ") " << kv.second.quals << (kv.second.quals.empty() ? "" : " ")
              << "in " << kv.second.type << " " << kv.first << (kv.second.array ? "[" + std::to_string(kv.second.array) + "]" : "") << ";\n";
    // outputs: gl_FragData[n] is the n-th entry of the DRAWBUFFERS list, so
    // goanna_out_n is output location n and the framebuffer puts colortex
    // drawbuffers[n] there. A write past the end of the list becomes a plain
    // global so it compiles and is discarded, as Iris discards it.
    std::vector<int> db = out.drawbuffers;
    if (db.empty())
        db.push_back(0);
    std::set<int> written;
    {
        static const std::regex outre(R"(\bgoanna_out_(\d+)\b)");
        for (auto it = std::sregex_iterator(fs.begin(), fs.end(), outre); it != std::sregex_iterator(); ++it)
            written.insert(std::atoi((*it)[1].str().c_str()));
    }
    for (int n : written) {
        if (n >= 0 && n < (int)db.size())
            f << "layout(location = " << n << ") out vec4 goanna_out_" << n << ";\n";
        else {
            f << "vec4 goanna_out_" << n << ";\n";
            out.warnings.push_back("gl_FragData[" + std::to_string(n) + "] written but DRAWBUFFERS lists only " + std::to_string(db.size()) + " targets, discarded");
        }
    }
    f << "#line 1\n" << fs << "\n";
    f << "void main() { goanna_pack_main(); }\n";
    out.fragment = f.str();
    return true;
}

} // namespace iris
} // namespace goanna
