// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The gbuffers translator. See iris_gbuffers.h for what it does and
// docs/design/iris-compat.md for why. Laid out in the order the work runs:
// a type model, the tables of built ins and Iris names, the emitter that
// types and writes expressions and statements, and the assembly of the
// Godot shader round the pack's two main bodies.

#include "iris_gbuffers.h"

#include "iris_glsl_ast.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <sstream>

namespace goanna {
namespace iris {

using namespace ast;

namespace {

// ---------------------------------------------------------------------------
// Types. Enough of GLSL's to decide where Godot needs a conversion written
// out: the scalar kind, the vector width or matrix shape, arrays, and
// samplers and structs by name.

struct Ty {
    enum B { Unknown, Void, Bool, Int, Uint, Float, Sampler, Struct };
    B b = Unknown;
    int n = 1;    // vector width; 1 for a scalar
    int cols = 0; // matrix columns, 0 when not a matrix
    int rows = 0;
    bool array = false;
    std::string name; // sampler type or struct name

    bool known() const { return b != Unknown; }
    bool isMatrix() const { return cols > 0; }
    bool isScalar() const { return !isMatrix() && n == 1 && !array && (b == Bool || b == Int || b == Uint || b == Float); }
    bool numericInt() const { return (b == Int || b == Uint) && !isMatrix() && !array; }
    bool isFloat() const { return b == Float && !array; }
    Ty elem() const {
        Ty t = *this;
        t.array = false;
        return t;
    }
    static Ty scalar(B b) {
        Ty t;
        t.b = b;
        return t;
    }
    static Ty vec(B b, int n) {
        Ty t;
        t.b = b;
        t.n = n;
        return t;
    }
    static Ty mat(int c, int r) {
        Ty t;
        t.b = Float;
        t.n = r;
        t.cols = c;
        t.rows = r;
        return t;
    }
    // Godot's spelling. Non-square matrices do not exist there.
    std::string godot() const {
        switch (b) {
        case Void: return "void";
        case Sampler:
            // Godot has no shadow samplers or 1D ones.
            if (name == "sampler2DShadow" || name == "sampler1D" || name == "sampler2DRect" || name == "sampler1DShadow")
                return "sampler2D";
            if (name == "sampler2DArrayShadow") return "sampler2DArray";
            if (name == "samplerCubeShadow") return "samplerCube";
            return name;
        case Struct: return name;
        case Unknown: return "float";
        default: break;
        }
        if (isMatrix())
            return "mat" + std::to_string(std::max(cols, rows));
        const char *p = b == Bool ? "b" : b == Int ? "i" : b == Uint ? "u" : "";
        if (n == 1)
            return b == Bool ? "bool" : b == Int ? "int" : b == Uint ? "uint" : "float";
        return std::string(p) + "vec" + std::to_string(n);
    }
    bool operator==(const Ty &o) const {
        return b == o.b && n == o.n && cols == o.cols && rows == o.rows && array == o.array && name == o.name;
    }
    bool operator!=(const Ty &o) const { return !(*this == o); }
};

Ty tyFromName(const std::string &s, const std::set<std::string> &structs) {
    Ty t;
    if (s == "void") return Ty::scalar(Ty::Void);
    if (s == "float" || s == "double") return Ty::scalar(Ty::Float);
    if (s == "int") return Ty::scalar(Ty::Int);
    if (s == "uint") return Ty::scalar(Ty::Uint);
    if (s == "bool") return Ty::scalar(Ty::Bool);
    auto vecOf = [&](const char *prefix, Ty::B b) -> bool {
        size_t l = std::strlen(prefix);
        if (s.size() == l + 4 && s.compare(0, l, prefix) == 0 && s.compare(l, 3, "vec") == 0 &&
                s[l + 3] >= '2' && s[l + 3] <= '4') {
            t = Ty::vec(b, s[l + 3] - '0');
            return true;
        }
        return false;
    };
    if (vecOf("", Ty::Float) || vecOf("d", Ty::Float) || vecOf("i", Ty::Int) || vecOf("u", Ty::Uint) ||
            vecOf("b", Ty::Bool))
        return t;
    if (s.size() >= 4 && (s.compare(0, 3, "mat") == 0 || s.compare(0, 4, "dmat") == 0)) {
        std::string d = s.substr(s[0] == 'd' ? 4 : 3);
        if (d.size() == 1 && d[0] >= '2' && d[0] <= '4')
            return Ty::mat(d[0] - '0', d[0] - '0');
        if (d.size() == 3 && d[1] == 'x')
            return Ty::mat(d[0] - '0', d[2] - '0');
    }
    if (s.find("sampler") != std::string::npos || s.find("image") != std::string::npos) {
        t.b = Ty::Sampler;
        t.name = s;
        return t;
    }
    if (structs.count(s)) {
        t.b = Ty::Struct;
        t.name = s;
        return t;
    }
    return t;
}

// ---------------------------------------------------------------------------
// Names

// Words Godot's shading language reserves that GLSL does not, and its
// built in constants and stage variables a pack may use as its own names.
// A pack identifier in this set is renamed.
const std::set<std::string> &godotReserved() {
    static const std::set<std::string> r = {"instance", "global", "varying", "render_mode", "shader_type",
            "stencil_mode", "group_uniforms", "source_color", "hint_range", "hint_normal", "hint_default_white",
            "hint_default_black", "hint_default_transparent", "hint_anisotropy", "hint_roughness_r",
            "hint_roughness_g", "hint_roughness_b", "hint_roughness_a", "hint_roughness_normal",
            "hint_roughness_gray", "hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture",
            "hint_enum", "filter_nearest", "filter_linear", "filter_nearest_mipmap", "filter_linear_mipmap",
            "filter_nearest_mipmap_anisotropic", "filter_linear_mipmap_anisotropic", "repeat_enable",
            "repeat_disable", "instance_index", "PI", "TAU", "E", "VERTEX", "NORMAL", "TANGENT", "BINORMAL",
            "UV", "UV2", "COLOR", "ALBEDO", "ALPHA", "EMISSION", "ROUGHNESS", "METALLIC", "SPECULAR", "TIME",
            "CAMERA_VISIBLE_LAYERS", "VIEW", "FRAGCOORD", "POSITION", "CUSTOM0", "CUSTOM1", "CUSTOM2", "CUSTOM3", "MODEL_MATRIX",
            "VIEW_MATRIX", "PROJECTION_MATRIX", "INV_VIEW_MATRIX", "INV_PROJECTION_MATRIX", "MODELVIEW_MATRIX",
            "NODE_POSITION_WORLD", "CAMERA_POSITION_WORLD", "SCREEN_UV", "DEPTH", "AO", "LIGHT", "ATTENUATION",
            "OUTPUT_IS_SRGB", "FRONT_FACING", "POINT_SIZE", "POINT_COORD", "INSTANCE_ID", "VERTEX_ID",
            "VIEWPORT_SIZE", "EYE_OFFSET", "VIEW_INDEX", "VIEW_MONO_LEFT", "VIEW_RIGHT", "RIM", "CLEARCOAT",
            "BACKLIGHT", "NORMAL_MAP", "SSS_STRENGTH", "fragment", "vertex", "light", "start", "process"};
    return r;
}

// The Iris uniforms read through a Godot global, by pack name, with the
// Godot type. Matrices and the fixed function stand ins are computed from
// the player's camera each frame by GoannaIrisGbuffers.
struct GlobalDef {
    const char *pack, *godot, *type;
};

const std::vector<GlobalDef> &globalDefs() {
    static std::vector<GlobalDef> defs;
    if (!defs.empty())
        return defs;
    static std::vector<std::string> keep; // owns the generated names
    for (auto &m : standardLayout().members) {
        if (m.name.compare(0, 7, "goanna_") == 0)
            continue;
        keep.push_back(m.name);
    }
    keep.push_back("alphaTestRef");
    // Gives each its iris_ name, in a second pass so the strings are stable.
    static std::vector<std::string> names;
    names.reserve(keep.size());
    for (auto &k : keep)
        names.push_back("iris_" + k);
    for (size_t i = 0; i < keep.size(); ++i) {
        const char *type = "float";
        if (const Layout::Member *m = standardLayout().find(keep[i]))
            type = utypeName(m->type);
        defs.push_back({keep[i].c_str(), names[i].c_str(), type});
    }
    // Fixed function matrices and their core profile names.
    static const GlobalDef fixed[] = {
        {"gl_ModelViewMatrix", "iris_gl_ModelViewMatrix", "mat4"},
        {"modelViewMatrix", "iris_gl_ModelViewMatrix", "mat4"},
        {"gl_ModelViewMatrixInverse", "iris_gl_ModelViewMatrixInverse", "mat4"},
        {"modelViewMatrixInverse", "iris_gl_ModelViewMatrixInverse", "mat4"},
        {"gl_ProjectionMatrix", "iris_gbufferProjection", "mat4"},
        {"projectionMatrix", "iris_gbufferProjection", "mat4"},
        {"gl_ProjectionMatrixInverse", "iris_gbufferProjectionInverse", "mat4"},
        {"projectionMatrixInverse", "iris_gbufferProjectionInverse", "mat4"},
        {"gl_ModelViewProjectionMatrix", "iris_gl_ModelViewProjectionMatrix", "mat4"},
        {"gl_NormalMatrix", "iris_gl_NormalMatrix", "mat3"},
        {"normalMatrix", "iris_gl_NormalMatrix", "mat3"},
    };
    for (auto &f : fixed)
        defs.push_back(f);
    return defs;
}

const GlobalDef *findGlobal(const std::string &pack) {
    for (auto &d : globalDefs())
        if (pack == d.pack)
            return &d;
    return nullptr;
}

// In the shadow program the fixed function matrices are the light's, as
// Iris gives them there: the modelview is shadowModelView after the
// camera's translation, the projection shadowProjection.
const GlobalDef *findShadowFixed(const std::string &pack) {
    static const GlobalDef fixed[] = {
        {"gl_ModelViewMatrix", "iris_shadow_gl_ModelViewMatrix", "mat4"},
        {"modelViewMatrix", "iris_shadow_gl_ModelViewMatrix", "mat4"},
        {"gl_ModelViewMatrixInverse", "iris_shadow_gl_ModelViewMatrixInverse", "mat4"},
        {"modelViewMatrixInverse", "iris_shadow_gl_ModelViewMatrixInverse", "mat4"},
        {"gl_ProjectionMatrix", "iris_shadowProjection", "mat4"},
        {"projectionMatrix", "iris_shadowProjection", "mat4"},
        {"gl_ProjectionMatrixInverse", "iris_shadowProjectionInverse", "mat4"},
        {"projectionMatrixInverse", "iris_shadowProjectionInverse", "mat4"},
        {"gl_ModelViewProjectionMatrix", "iris_shadow_gl_ModelViewProjectionMatrix", "mat4"},
        {"gl_NormalMatrix", "iris_shadow_gl_NormalMatrix", "mat3"},
        {"normalMatrix", "iris_shadow_gl_NormalMatrix", "mat3"},
    };
    for (auto &f : fixed)
        if (pack == f.pack)
            return &f;
    return nullptr;
}

// What a pack sampler is bound to.
enum class SamplerRole {
    Atlas, Normals, Specular, Lightmap, Noise, White, Black, ShadowDepth0, ShadowDepth1, ShadowColour0,
    SceneDepth, // the opaque depth under translucent geometry (Godot's hint_depth_texture)
    ChainTarget, // a colortex the screen space chain wrote (iris_colortex<N>)
};

bool samplerRole(const std::string &name, SamplerRole &role) {
    if (name == "texture" || name == "tex" || name == "gtexture") role = SamplerRole::Atlas;
    else if (name == "normals") role = SamplerRole::Normals;
    else if (name == "specular") role = SamplerRole::Specular;
    else if (name == "lightmap") role = SamplerRole::Lightmap;
    else if (name == "noisetex") role = SamplerRole::Noise;
    // The pack's shadow map (rung 7), with the legacy names Iris also
    // takes: shadow is shadowtex0, watershadow shadowtex1, shadowcolor
    // shadowcolor0. Until a shadow pass has drawn they read white: depth
    // 1.0, nothing in shadow.
    else if (name == "shadowtex0" || name == "shadow") role = SamplerRole::ShadowDepth0;
    else if (name == "shadowtex1" || name == "watershadow") role = SamplerRole::ShadowDepth1;
    else if (name == "shadowcolor0" || name == "shadowcolor") role = SamplerRole::ShadowColour0;
    else if (name.compare(0, 9, "shadowtex") == 0 || name.compare(0, 8, "depthtex") == 0 || name == "shadow" ||
            name == "watershadow" || name == "gdepthtex" || name.compare(0, 11, "shadowcolor") == 0)
        role = SamplerRole::White;
    else
        role = SamplerRole::Black;
    return true;
}

// The colortex a sampler name means (colortex4, gaux1 ...), or -1.
int chainTargetIndex(const std::string &sampler) {
    const std::string c = canonicalSampler(sampler);
    if (c.compare(0, 8, "colortex") != 0)
        return -1;
    const int i = std::atoi(c.c_str() + 8);
    return i >= 0 && i < 16 ? i : -1;
}

const std::set<std::string> &genericFloatFunctions() {
    static const std::set<std::string> f = {"abs", "sign", "floor", "ceil", "fract", "round", "roundEven", "trunc",
            "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "exp",
            "exp2", "log", "log2", "sqrt", "inversesqrt", "radians", "degrees", "normalize", "dFdx", "dFdy",
            "fwidth", "dFdxFine", "dFdyFine", "dFdxCoarse", "dFdyCoarse", "fwidthFine", "fwidthCoarse", "mod",
            "min", "max", "clamp", "mix", "step", "smoothstep", "pow", "faceforward", "reflect", "refract", "fma",
            "transpose", "inverse"};
    return f;
}

std::string floatLiteral(const std::string &t) {
    std::string s = t;
    while (!s.empty() && (s.back() == 'f' || s.back() == 'F' || s.back() == 'l' || s.back() == 'L')) s.pop_back();
    if (s.find('.') == std::string::npos && s.find('e') == std::string::npos && s.find('E') == std::string::npos)
        s += ".0";
    return s;
}

// ---------------------------------------------------------------------------
// The translator

enum class Stage { Vertex, Fragment };

struct Val {
    std::string code;
    Ty t;
    bool int_lit = false; // a bare int literal, which converts by spelling
};

struct FuncSym {
    const Function *f = nullptr;
    Stage stage;
    std::string key;     // name(paramtypes)
    std::string emitted; // name in the Godot source
    std::vector<Ty> params;
    Ty ret;
    std::string code;
    bool done = false, busy = false;
    // Stage globals this function or anything it calls reads or writes,
    // passed in as inout parameters (see VarSym::kind), by pack name.
    std::vector<std::string> routed;
    // Built in inputs (goanna_gl_Vertex and the rest) it or its callees
    // read, passed in as parameters: Godot lets only vertex() and fragment()
    // read the stage built ins they are made from, and carrying them as
    // varyings ran Mellow out of Godot's 32.
    std::set<std::string> inputs;
};

struct VarSym {
    std::string emitted;
    Ty t;
    // What a stage may need to pass to its helper functions by reference,
    // because Godot lets no function but vertex() and fragment() write it:
    // 1 a varying the vertex stage writes, 2 a fragment output, 3 a plain
    // global turned into a local of main.
    int kind = 0;
};

class Translator {
public:
    Translator(const GbuffersOptions &o, GbuffersResult &r) : m_o(o), m_r(r) {}

    bool run(const Program &p, std::string &err);

private:
    const GbuffersOptions &m_o;
    GbuffersResult &m_r;
    Unit m_unit[2];
    std::set<std::string> m_structs;
    std::map<std::string, const StructDef *> m_struct_defs;
    std::vector<std::string> m_struct_code;

    // Globals of one stage: pack name -> symbol. Varyings, outputs,
    // uniforms, consts and lazy globals all live here.
    std::map<std::string, VarSym> m_globals[2];
    std::map<std::string, std::vector<FuncSym>> m_funcs[2];
    std::set<std::string> m_used_names; // every global name in the output
    std::vector<std::string> m_decl_lines; // global uniform, uniform, varying, const lines
    std::set<std::string> m_decl_seen;
    std::vector<std::string> m_func_order; // emitted function code in dependency order
    std::set<std::string> m_globals_needed; // Godot globals: name -> type in m_global_types
    std::map<std::string, std::string> m_global_types;
    std::set<std::string> m_warned;
    // Built in inputs a stage's prologue must set up, by local name.
    std::set<std::string> m_vin, m_fin;
    // Fragment outputs by location: the local that holds it.
    std::map<int, std::string> m_outs;
    std::map<std::string, int> m_out_names; // pack name -> location
    std::map<int, Ty> m_out_types;          // location -> declared type; vec4 when undeclared
    Ty outType(int k) const {
        auto it = m_out_types.find(k);
        return it == m_out_types.end() ? Ty::vec(Ty::Float, 4) : it->second;
    }
    // An output as the vec4 its target receives: missing components filled
    // as GL fills them (0, 0, 1), integers converted.
    std::string outVec4(int k) const {
        Ty t = outType(k);
        std::string n = "goanna_out_" + std::to_string(k);
        if (t.b != Ty::Float)
            n = (t.n == 1 ? std::string("float") : "vec" + std::to_string(t.n)) + "(" + n + ")";
        static const char *pad[] = {"", ", 0.0, 0.0, 1.0", ", 0.0, 1.0", ", 1.0", ""};
        return t.n == 4 ? n : "vec4(" + n + pad[t.n] + ")";
    }
    std::set<int> m_out_written;
    bool m_legacy_fragment_output = false;
    std::set<int> m_reads; // colortex targets sampled (GbuffersResult::reads)
    // Varyings carried in packed slots (packVaryings), per stage, by pack
    // name. A struct varying lists its fields.
    struct Carried {
        std::string emitted;
        Ty t;
        bool flat = false;
        std::vector<std::pair<std::string, Ty>> fields;
    };
    std::map<std::string, Carried> m_carried[2];
    // A type a packed slot can carry: a float, int, uint or bool scalar or
    // vector, or a float matrix (by its columns).
    static bool carriable(const Ty &t) {
        if (t.array) return false;
        if (t.isMatrix()) return t.b == Ty::Float;
        if (t.b == Ty::Bool) return t.n == 1;
        return (t.b == Ty::Float || t.b == Ty::Int || t.b == Ty::Uint) && t.n >= 1 && t.n <= 4;
    }
    void packVaryings(const std::string &fragment_code, std::string &vertex_out, std::string &fragment_in);
    bool m_layer_needed = false;
    bool m_texmat1 = false;
    std::string m_mc_entity_type = "vec4";
    std::string m_mc_midtex_type = "vec4";

    // Emission state
    Stage m_stage = Stage::Vertex;
    bool m_in_main = false;
    int m_loop_depth = 0, m_switch_depth = 0;
    bool m_main_return = false;
    std::vector<std::map<std::string, VarSym>> m_scopes;
    FuncSym *m_cur_func = nullptr;
    std::set<std::string> m_local_names;

    void warn(const std::string &w) {
        if (m_warned.insert(w).second)
            m_r.warnings.push_back(w);
    }
    int si(Stage s) const { return s == Stage::Vertex ? 0 : 1; }

    std::string uniqueGlobal(const std::string &want) {
        std::string n = want;
        if (godotReserved().count(n) || n.compare(0, 3, "gl_") == 0)
            n = "p_" + n;
        int k = 2;
        std::string base = n;
        while (m_used_names.count(n))
            n = base + "_" + std::to_string(k++);
        m_used_names.insert(n);
        return n;
    }
    // A vector of width n widened to m with zeros, and a vector of width m
    // cut back to its first n, for the padded non-square matrices.
    static std::string padVec(const std::string &code, int n, int m) {
        if (n >= m) return code;
        std::string s = "vec" + std::to_string(m) + "(" + code;
        for (int k = n; k < m; ++k) s += ", 0.0";
        return s + ")";
    }
    static std::string cutVec(const std::string &code, int m, int n) {
        if (n >= m) return code;
        return code + "." + std::string("xyzw").substr(0, n);
    }
    void addDecl(const std::string &line) {
        if (m_decl_seen.insert(line).second)
            m_decl_lines.push_back(line);
    }
    std::string needGlobal(const std::string &name, const std::string &type) {
        if (name == "iris_alphaTestRef") {
            // Iris changes this per draw: opaque terrain, mipmapped leaves
            // and ordinary plants do not share one discard threshold.
            addDecl("uniform float iris_alphaTestRef = 0.1;");
            return name;
        }
        if (!m_global_types.count(name)) {
            m_global_types[name] = type;
            std::string hint;
            if (type == "sampler2D")
                hint = name == "iris_lightmap" || name.compare(0, 13, "iris_colortex") == 0
                        ? " : filter_linear, repeat_disable"
                        : name.compare(0, 11, "iris_shadow") == 0 ? " : filter_nearest, repeat_disable"
                                                                  : " : filter_linear_mipmap, repeat_enable";
            addDecl("global uniform " + type + " " + name + hint + ";");
            m_r.globals.push_back({name, type});
        }
        return name;
    }

    Ty specTy(const TypeSpec &ts) {
        Ty t = tyFromName(ts.name, m_structs);
        if (ts.array) t.array = true;
        if (!t.known())
            warn("unknown type '" + ts.name + "'");
        return t;
    }

    // ---- conversions

    Val conv(const Val &v, const Ty &to) {
        if (!v.t.known() || !to.known() || v.t == to || v.t.array || to.array || v.t.isMatrix() || to.isMatrix())
            return v;
        if (v.t.n != to.n && v.t.n != 1)
            return v;
        Val r = v;
        r.t = to;
        r.int_lit = false;
        if (to.b == Ty::Float && (v.t.b == Ty::Int || v.t.b == Ty::Uint || v.t.b == Ty::Bool)) {
            if (v.int_lit) {
                std::string s = v.code;
                while (!s.empty() && (s.back() == 'u' || s.back() == 'U')) s.pop_back();
                bool hex = s.size() > 1 && (s[1] == 'x' || s[1] == 'X');
                if (!hex) {
                    r.code = (to.n == 1) ? s + ".0" : to.godot() + "(" + s + ".0)";
                    return r;
                }
            }
            r.code = to.godot() + "(" + v.code + ")";
            return r;
        }
        if (to.b == Ty::Uint && v.t.b == Ty::Int) {
            r.code = v.int_lit && to.n == 1 ? v.code + "u" : to.godot() + "(" + v.code + ")";
            return r;
        }
        if (to.b == Ty::Int && v.t.b == Ty::Uint) {
            r.code = to.godot() + "(" + v.code + ")";
            return r;
        }
        if (v.t.n == 1 && to.n > 1 && v.t.b == to.b) {
            // scalar to vector where GLSL would broadcast, e.g. an assignment
            // of a float to a vec3 is not GLSL either, so leave it
            return v;
        }
        return v;
    }
    // Promote two operands of an arithmetic or comparison operator.
    void promote(Val &a, Val &b) {
        if (!a.t.known() || !b.t.known()) return;
        if (a.t.b == Ty::Float && b.t.numericInt()) {
            Ty to = b.t;
            to.b = Ty::Float;
            b = conv(b, to);
        } else if (b.t.b == Ty::Float && a.t.numericInt()) {
            Ty to = a.t;
            to.b = Ty::Float;
            a = conv(a, to);
        } else if (a.t.b == Ty::Uint && b.t.b == Ty::Int) {
            Ty to = b.t;
            to.b = Ty::Uint;
            b = conv(b, to);
        } else if (b.t.b == Ty::Uint && a.t.b == Ty::Int) {
            Ty to = a.t;
            to.b = Ty::Uint;
            a = conv(a, to);
        }
    }

    // ---- lookup

    const VarSym *findLocal(const std::string &n) const {
        for (auto it = m_scopes.rbegin(); it != m_scopes.rend(); ++it) {
            auto f = it->find(n);
            if (f != it->end()) return &f->second;
        }
        return nullptr;
    }
    std::string declareLocal(const std::string &n, const Ty &t) {
        std::string e = n;
        if (godotReserved().count(e)) e = "p_" + e;
        // Godot refuses a local that shadows a global or an outer local.
        int k = 2;
        std::string base = e;
        while (m_used_names.count(e) || findLocal(e) || m_local_names.count(e) ||
                m_globals[si(m_stage)].count(e) || m_funcs[0].count(e) || m_funcs[1].count(e))
            e = base + "_l" + std::to_string(k++);
        m_local_names.insert(e);
        m_scopes.back()[n] = {e, t};
        return e;
    }

    Val ident(const Expr &e);
    Val builtinIdent(const std::string &n, bool &found);
    Val expr(const ExprP &e);
    Val call(const Expr &e);
    Val textureCall(const std::string &fn, const std::string &sampler, std::vector<Val> &args, const Expr &e);
    Val member(const Expr &e);
    std::string stmt(const StmtP &s, int indent);
    std::string declStmt(const Stmt &s, const std::string &pad);
    FuncSym *resolve(const std::string &name, std::vector<Val> &args);
    void emitFunction(FuncSym &f);
    std::string emitMain(Stage st, std::string &err);
    bool collectGlobals(Stage st, std::string &err);
    std::string stageBuiltin(const std::string &local, Stage st);
    void route(Stage st);
    std::string routedName(const std::string &pack, Stage st);
    std::set<std::string> m_routed_all[2];
    std::set<std::string> m_consts[2];
    std::vector<bool> m_switch_uint;
    // Built in inputs each global-turned-function reads, by function name.
    std::map<std::string, std::vector<std::string>> m_lazy_inputs;
    // Plain globals of a stage, declared at the top of its main.
    std::vector<std::string> m_main_locals[2];
    // Whether a global is assigned anywhere in either stage.
    bool assigned(const std::string &name) {
        bool found = false;
        std::function<void(const ExprP &)> we = [&](const ExprP &e) {
            if (!e || found) return;
            if (e->kind == Expr::Assign || ((e->kind == Expr::Unary || e->kind == Expr::Postfix) &&
                                                   (e->text == "++" || e->text == "--"))) {
                const Expr *l = e->a[0].get();
                while (l->kind == Expr::Member || l->kind == Expr::Index) l = l->a[0].get();
                if (l->kind == Expr::Ident && l->text == name) found = true;
            }
            for (auto &x : e->a) we(x);
            we(e->method_of);
        };
        std::function<void(const StmtP &)> ws = [&](const StmtP &s) {
            if (!s || found) return;
            we(s->e);
            we(s->e2);
            for (auto &d : s->decls) we(d.init);
            ws(s->s1);
            ws(s->s2);
            ws(s->s3);
            for (auto &b : s->body) ws(b);
        };
        for (auto &u : m_unit)
            for (auto &it : u.items)
                if (it.kind == Item::FunctionItem) ws(it.function.body);
        return found;
    }
    // Whether an initialiser is a constant expression Godot will take.
    bool constExpr(const ExprP &e, Stage st) {
        if (!e) return true;
        switch (e->kind) {
        case Expr::Lit: return true;
        case Expr::Ident: return m_consts[si(st)].count(e->text) > 0;
        case Expr::Call:
            if (e->method_of) return false;
            if (m_funcs[si(st)].count(e->text) || e->text.rfind("texture", 0) == 0) return false;
            break;
        case Expr::Assign: return false;
        default: break;
        }
        for (auto &x : e->a)
            if (!constExpr(x, st)) return false;
        return true;
    }
};

// ---- identifiers

Val Translator::builtinIdent(const std::string &n, bool &found) {
    found = true;
    Val v;
    bool frag = m_stage == Stage::Fragment;
    // Inputs a stage computes in its prologue. In the main body they are
    // locals; in a helper function they would be stage built ins Godot does
    // not let a function read, so they are carried as varyings instead
    // (stageBuiltin knows which).
    auto input = [&](const std::string &local, const Ty &t) {
        (frag ? m_fin : m_vin).insert(local);
        if (!m_in_main && m_cur_func)
            m_cur_func->inputs.insert(local);
        v.code = local;
        v.t = t;
        return v;
    };
    if (!frag) {
        if (n == "gl_Vertex") return input("goanna_gl_Vertex", Ty::vec(Ty::Float, 4));
        if (n == "vaPosition") {
            input("goanna_gl_Vertex", Ty::vec(Ty::Float, 4));
            v.code += ".xyz";
            v.t = Ty::vec(Ty::Float, 3);
            return v;
        }
        if (n == "gl_Normal" || n == "vaNormal") return input("goanna_gl_Normal", Ty::vec(Ty::Float, 3));
        if (n == "gl_Color" || n == "vaColor") return input("goanna_gl_Color", Ty::vec(Ty::Float, 4));
        if (n == "gl_MultiTexCoord0") return input("goanna_gl_MultiTexCoord0", Ty::vec(Ty::Float, 4));
        if (n == "vaUV0") {
            input("goanna_gl_MultiTexCoord0", Ty::vec(Ty::Float, 4));
            v.code += ".xy";
            v.t = Ty::vec(Ty::Float, 2);
            return v;
        }
        if (n == "gl_MultiTexCoord1" || n == "gl_MultiTexCoord2")
            return input("goanna_gl_MultiTexCoord1", Ty::vec(Ty::Float, 4));
        if (n == "vaUV1" || n == "vaUV2") {
            input("goanna_gl_MultiTexCoord1", Ty::vec(Ty::Float, 4));
            v.code = "ivec2(" + v.code + ".xy)";
            v.t = Ty::vec(Ty::Int, 2);
            return v;
        }
        if (n.compare(0, 16, "gl_MultiTexCoord") == 0) {
            v.code = "vec4(0.0, 0.0, 0.0, 1.0)";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
        if (n == "mc_Entity") {
            input("goanna_gl_Entity", Ty::vec(Ty::Float, 4));
            Ty t = tyFromName(m_mc_entity_type, m_structs);
            if (t.n < 4 && t.n >= 1) {
                static const char *sw[] = {"", ".x", ".xy", ".xyz"};
                v.code += sw[t.n];
                v.t = t;
            }
            return v;
        }
        if (n == "mc_midTexCoord") {
            // Declared as narrow as the pack likes (Photon's vec2), as GL
            // drops an attribute's trailing components.
            Ty t = tyFromName(m_mc_midtex_type, m_structs);
            static const char *mid[] = {"0.5", "vec2(0.5, 0.5)", "vec3(0.5, 0.5, 0.0)", "vec4(0.5, 0.5, 0.0, 1.0)"};
            int k = t.b == Ty::Float && t.n >= 1 && t.n <= 4 && !t.isMatrix() ? t.n : 4;
            v.code = mid[k - 1];
            v.t = Ty::vec(Ty::Float, k);
            return v;
        }
        if (n == "at_tangent") return input("goanna_gl_Tangent", Ty::vec(Ty::Float, 4));
        if (n == "at_midBlock") return input("goanna_gl_MidBlock", Ty::vec(Ty::Float, 4));
        if (n == "gl_VertexID") { v.code = "VERTEX_ID"; v.t = Ty::scalar(Ty::Int); return v; }
        if (n == "gl_InstanceID") { v.code = "INSTANCE_ID"; v.t = Ty::scalar(Ty::Int); return v; }
        if (n == "gl_Position") {
            if (!m_in_main) warn("gl_Position written outside main is not supported");
            m_vin.insert("goanna_gl_Position");
            v.code = "goanna_gl_Position";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
        if (n == "gl_FrontColor" || n == "gl_BackColor" || n == "gl_FrontSecondaryColor") {
            m_vin.insert("vary:goanna_v_FrontColor");
            v.code = "goanna_v_FrontColor";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
        if (n == "gl_FogFragCoord") {
            addDecl("varying float goanna_v_FogFragCoord;");
            v.code = "goanna_v_FogFragCoord";
            v.t = Ty::scalar(Ty::Float);
            return v;
        }
        if (n == "gl_PointSize" || n == "gl_ClipVertex") {
            warn(n + " is ignored");
            m_vin.insert("goanna_gl_Ignored");
            v.code = "goanna_gl_Ignored";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
    } else {
        if (n == "gl_FragCoord") return input("goanna_gl_FragCoord", Ty::vec(Ty::Float, 4));
        if (n == "gl_FrontFacing") {
            if (!m_in_main) {
                warn("gl_FrontFacing outside main reads true");
                v.code = "true";
            } else {
                v.code = "FRONT_FACING";
            }
            v.t = Ty::scalar(Ty::Bool);
            return v;
        }
        if (n == "gl_Color") {
            // Iris interpolates the vertex colour when the vertex stage does
            // not write gl_FrontColor itself.
            m_vin.insert("vary:goanna_v_FrontColor");
            m_fin.insert("vary:goanna_v_FrontColor");
            v.code = "goanna_v_FrontColor";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
        if (n == "gl_FogFragCoord") {
            addDecl("varying float goanna_v_FogFragCoord;");
            v.code = "goanna_v_FogFragCoord";
            v.t = Ty::scalar(Ty::Float);
            return v;
        }
        if (n == "gl_FragColor") {
            m_legacy_fragment_output = true;
            m_out_written.insert(0);
            v.code = "goanna_out_0";
            v.t = Ty::vec(Ty::Float, 4);
            return v;
        }
        if (n == "gl_FragDepth") {
            warn("gl_FragDepth is ignored");
            m_fin.insert("goanna_gl_FragDepth");
            v.code = "goanna_gl_FragDepth";
            v.t = Ty::scalar(Ty::Float);
            return v;
        }
    }
    if (n == "chunkOffset") {
        v.code = "vec3(0.0)";
        v.t = Ty::vec(Ty::Float, 3);
        return v;
    }
    if (const GlobalDef *g = m_o.shadow_pass && findShadowFixed(n) ? findShadowFixed(n) : findGlobal(n)) {
        v.code = needGlobal(g->godot, g->type);
        v.t = tyFromName(g->type, m_structs);
        return v;
    }
    found = false;
    return v;
}

Val Translator::ident(const Expr &e) {
    const std::string &n = e.text;
    if (const VarSym *l = findLocal(n))
        return {l->emitted, l->t, false};
    auto &g = m_globals[si(m_stage)];
    auto it = g.find(n);
    if (it != g.end()) {
        if (it->second.emitted.compare(0, 14, "goanna_lazy_fn") == 0) {
            // A global initialised from uniforms or inputs, now a function;
            // the built in inputs it reads are passed as for any helper.
            std::string fname = it->second.emitted.substr(15);
            std::string args;
            for (auto &in : m_lazy_inputs[fname]) {
                args += (args.empty() ? "" : ", ") + in;
                (m_stage == Stage::Fragment ? m_fin : m_vin).insert(in);
                if (!m_in_main && m_cur_func) m_cur_func->inputs.insert(in);
            }
            return {fname + "(" + args + ")", it->second.t, false};
        }
        if (it->second.t.b == Ty::Sampler && it->second.emitted == n) {
            // A sampler handed to a function as a value: its bound texture.
            SamplerRole role;
            samplerRole(n, role);
            // An unassigned sampler2D keeps OpenGL's texture unit zero.
            // The basic sky binds a white diffuse texture on that unit.
            if (role == SamplerRole::Black && chainTargetIndex(n) < 0 &&
                    m_o.surface == GbuffersSurface::SkyBasic && !m_o.shadow_pass &&
                    it->second.t.name == "sampler2D")
                role = SamplerRole::White;
            std::string tex;
            switch (role) {
            case SamplerRole::Lightmap: tex = needGlobal("iris_lightmap", "sampler2D"); break;
            case SamplerRole::Noise: tex = needGlobal("iris_noisetex", "sampler2D"); break;
            case SamplerRole::White: tex = needGlobal("iris_tex_white", "sampler2D"); break;
            case SamplerRole::Black: {
                const int ct = m_o.shadow_pass ? -1 : chainTargetIndex(n);
                if (ct >= 0) {
                    // The helper samples it with the pack's coordinates, so
                    // a screen texture's rows are not flipped there.
                    if (!m_o.data_targets.count(ct))
                        warn("sampler '" + n + "' passed to a function is read upside down");
                    tex = needGlobal("iris_colortex" + std::to_string(ct), "sampler2D");
                    m_reads.insert(ct);
                } else {
                    tex = needGlobal("iris_tex_black", "sampler2D");
                }
                break;
            }
            default:
                warn("the atlas passed to a function is read as black");
                tex = needGlobal("iris_tex_black", "sampler2D");
                break;
            }
            return {tex, it->second.t, false};
        }
        auto o = m_out_names.find(n);
        if (m_stage == Stage::Fragment && o != m_out_names.end())
            m_out_written.insert(o->second);
        return {it->second.emitted, it->second.t, false};
    }
    bool found = false;
    Val b = builtinIdent(n, found);
    if (found)
        return b;
    if (n == "gl_Fog") {
        warn("gl_Fog used whole");
        return {"vec4(0.0)", Ty::vec(Ty::Float, 4), false};
    }
    warn("unknown identifier '" + n + "'");
    return {n, Ty(), false};
}

// ---- expressions

Val Translator::member(const Expr &e) {
    const Expr &obj = *e.a[0];
    if (obj.kind == Expr::Ident && obj.text == "gl_Fog" && !findLocal("gl_Fog")) {
        const std::string &f = e.text;
        if (f == "color") {
            std::string c = needGlobal("iris_fogColor", "vec3");
            return {"vec4(" + c + ", 1.0)", Ty::vec(Ty::Float, 4), false};
        }
        if (f == "start") return {needGlobal("iris_fogStart", "float"), Ty::scalar(Ty::Float), false};
        if (f == "end") return {needGlobal("iris_fogEnd", "float"), Ty::scalar(Ty::Float), false};
        if (f == "density") return {needGlobal("iris_fogDensity", "float"), Ty::scalar(Ty::Float), false};
        if (f == "scale") {
            std::string s = needGlobal("iris_fogStart", "float"), en = needGlobal("iris_fogEnd", "float");
            return {"(1.0 / max(" + en + " - " + s + ", 1e-4))", Ty::scalar(Ty::Float), false};
        }
    }
    Val o = expr(e.a[0]);
    Val r;
    if (o.t.b == Ty::Struct) {
        auto sd = m_struct_defs.find(o.t.name);
        r.code = o.code + "." + e.text;
        if (sd != m_struct_defs.end())
            for (auto &f : sd->second->fields)
                if (f.name == e.text) {
                    r.t = specTy(f.type);
                    if (f.array) r.t.array = true;
                }
        return r;
    }
    // A swizzle. stpq is spelt xyzw, which every Godot version takes.
    std::string sw = e.text;
    for (auto &c : sw) {
        switch (c) {
        case 's': c = 'x'; break;
        case 't': c = 'y'; break;
        case 'p': c = 'z'; break;
        case 'q': c = 'w'; break;
        default: break;
        }
    }
    r.code = o.code + "." + sw;
    r.t = o.t.known() ? Ty::vec(o.t.b, (int)sw.size()) : Ty();
    return r;
}

FuncSym *Translator::resolve(const std::string &name, std::vector<Val> &args) {
    auto it = m_funcs[si(m_stage)].find(name);
    if (it == m_funcs[si(m_stage)].end())
        return nullptr;
    FuncSym *best = nullptr;
    int bestScore = -1;
    for (auto &f : it->second) {
        if (f.params.size() != args.size()) continue;
        int score = 0;
        bool ok = true;
        for (size_t i = 0; i < args.size(); ++i) {
            const Ty &p = f.params[i], &a = args[i].t;
            if (!a.known() || p == a) {
                score += 2;
            } else if (p.b == Ty::Float && a.numericInt() && p.n == a.n) {
                score += 1;
            } else {
                ok = false;
            }
        }
        if (ok && score > bestScore) {
            best = &f;
            bestScore = score;
        }
    }
    if (!best && it->second.size() == 1)
        best = &it->second[0];
    return best;
}

Val Translator::textureCall(const std::string &fn, const std::string &sampler, std::vector<Val> &args,
        const Expr &e) {
    SamplerRole role;
    samplerRole(sampler, role);
    // Translucent geometry reads the depth of everything opaque, which is
    // what Iris's depthtex1 holds while it draws. Godot gives a transparent
    // material exactly that through hint_depth_texture, so depthtex0 to 2
    // all read it there (Iris's depthtex0 is the buffer being drawn into).
    if (role == SamplerRole::White && !m_o.shadow_pass &&
            (m_o.surface == GbuffersSurface::Translucent || m_o.surface == GbuffersSurface::Clouds) &&
            (sampler.compare(0, 8, "depthtex") == 0 || sampler == "gdepthtex"))
        role = SamplerRole::SceneDepth;
    // A colortex (gaux1 and the other legacy names included): what the
    // chain left in it, as Iris lets a geometry program read the targets
    // earlier passes wrote.
    const int chain_target = role == SamplerRole::Black && !m_o.shadow_pass ? chainTargetIndex(sampler) : -1;
    if (chain_target >= 0)
        role = SamplerRole::ChainTarget;
    auto declaration = m_globals[si(m_stage)].find(sampler);
    if (role == SamplerRole::Black && m_o.surface == GbuffersSurface::SkyBasic &&
            !m_o.shadow_pass && declaration != m_globals[si(m_stage)].end() &&
            declaration->second.t.name == "sampler2D") {
        // GLSL leaves an unassigned sampler on texture unit zero. Iris's
        // basic sky uses white there, observed with the cloudTex probe.
        role = SamplerRole::White;
    }
    const bool array = m_o.surface == GbuffersSurface::ArrayOpaque || m_o.surface == GbuffersSurface::ArrayCutout;
    auto coord = [&](const Val &uv) {
        if (!array) return uv.code;
        m_layer_needed = true;
        return "vec3((" + uv.code + ").xy, float(goanna_layer))";
    };
    std::string tex;
    bool layered = false;
    // A texture of the screen (see plain() below), and whether its value is
    // Godot's reversed depth, read as OpenGL's.
    bool screen = false, gl_depth = false;
    switch (role) {
    case SamplerRole::SceneDepth:
        addDecl("uniform sampler2D goanna_scene_depth : hint_depth_texture, filter_nearest, repeat_disable;");
        tex = "goanna_scene_depth";
        screen = gl_depth = true;
        break;
    case SamplerRole::ChainTarget:
        tex = needGlobal("iris_colortex" + std::to_string(chain_target), "sampler2D");
        screen = !m_o.data_targets.count(chain_target);
        m_reads.insert(chain_target);
        break;
    case SamplerRole::Atlas:
        tex = array ? "albedo_array" : "albedo_tex";
        layered = array;
        break;
    case SamplerRole::Normals:
        if (array) {
            tex = "normal_array";
            layered = true;
        } else {
            tex = needGlobal("iris_tex_black", "sampler2D");
        }
        break;
    case SamplerRole::Specular:
        if (array) {
            tex = "spec_array";
            layered = true;
        } else {
            tex = needGlobal("iris_tex_black", "sampler2D");
        }
        break;
    case SamplerRole::Lightmap: tex = needGlobal("iris_lightmap", "sampler2D"); break;
    case SamplerRole::Noise: tex = needGlobal("iris_noisetex", "sampler2D"); break;
    case SamplerRole::White:
        tex = needGlobal("iris_tex_white", "sampler2D");
        warn("sampler '" + sampler + "' reads a constant white texture");
        break;
    case SamplerRole::Black:
        tex = needGlobal("iris_tex_black", "sampler2D");
        warn("sampler '" + sampler + "' reads a constant black texture");
        break;
    case SamplerRole::ShadowDepth0: tex = needGlobal("iris_shadowtex0", "sampler2D"); break;
    case SamplerRole::ShadowDepth1: tex = needGlobal("iris_shadowtex1", "sampler2D"); break;
    case SamplerRole::ShadowColour0: tex = needGlobal("iris_shadowcolor0", "sampler2D"); break;
    }
    const bool shadow_depth = role == SamplerRole::ShadowDepth0 || role == SamplerRole::ShadowDepth1;
    // Shadow comparisons. Godot has no comparison sampler, so a depth
    // map's compare is written out: lit (1.0) where the reference is no
    // further than the stored depth, as LESS_OR_EQUAL compares. Any other
    // shadow sampler says nothing is in shadow.
    bool shadow_cmp = fn.rfind("shadow2D", 0) == 0 ||
            (fn.compare(0, 7, "texture") == 0 && args.size() >= 2 && args[1].t.n == 3 && !layered &&
                    sampler.compare(0, 6, "shadow") == 0 && (role == SamplerRole::White || shadow_depth) &&
                    m_globals[si(m_stage)].count(sampler) &&
                    m_globals[si(m_stage)][sampler].t.name.find("Shadow") != std::string::npos);
    if (shadow_cmp && shadow_depth && args.size() >= 2) {
        std::string c = conv(args[1], Ty::vec(Ty::Float, 3)).code;
        std::string lod = fn.find("Lod") != std::string::npos && args.size() >= 3 ? conv(args[2], Ty::scalar(Ty::Float)).code : "";
        std::string read = lod.empty() ? "texture(" + tex + ", (" + c + ").xy).r"
                                       : "textureLod(" + tex + ", (" + c + ").xy, " + lod + ").r";
        std::string cmp = "step((" + c + ").z, " + read + ")";
        if (fn.rfind("shadow2D", 0) == 0)
            return {"vec4(" + cmp + ")", Ty::vec(Ty::Float, 4), false};
        return {cmp, Ty::scalar(Ty::Float), false};
    }
    if (shadow_cmp) {
        if (fn.rfind("shadow2D", 0) == 0)
            return {"vec4(1.0)", Ty::vec(Ty::Float, 4), false};
        return {"1.0", Ty::scalar(Ty::Float), false};
    }
    std::string base = fn;
    static const std::pair<const char *, const char *> legacy[] = {{"texture2DLod", "textureLod"},
            {"texture2DLodARB", "textureLod"}, {"texture2DGradARB", "textureGrad"}, {"texture2DGrad", "textureGrad"},
            {"texture2DProj", "textureProj"}, {"texture2D", "texture"}, {"texture3D", "texture"},
            {"textureCube", "texture"}, {"texelFetch2D", "texelFetch"}};
    for (auto &l : legacy)
        if (base == l.first) base = l.second;
    Ty v4 = Ty::vec(Ty::Float, 4);
    auto fl = [&](size_t i) { return conv(args[i], Ty::scalar(Ty::Float)).code; };
    // A screen texture's rows run top down, as Godot's screen coordinates
    // do, and the pack's coordinates bottom up, as gl_FragCoord's do in the
    // shell; scene depth is also reversed. plain() turns a pack coordinate
    // into the texture's, done() a sample into what the pack expects.
    auto plain = [&](const Val &uv) {
        return screen ? "goanna_screen_uv((" + uv.code + ").xy)" : uv.code;
    };
    auto done = [&](const std::string &code) -> Val {
        return {gl_depth ? "goanna_gl_depth(" + code + ")" : code, v4, false};
    };
    if (base == "texture" && args.size() >= 2) {
        std::string c = layered ? coord(args[1]) : plain(args[1]);
        return done("texture(" + tex + ", " + c + (args.size() > 2 ? ", " + fl(2) : "") + ")");
    }
    if (base == "textureLod" && args.size() >= 3) {
        std::string c = layered ? coord(args[1]) : plain(args[1]);
        return done("textureLod(" + tex + ", " + c + ", " + fl(2) + ")");
    }
    if (base == "textureGrad" && args.size() >= 4) {
        std::string c = layered ? coord(args[1]) : plain(args[1]);
        return done("textureGrad(" + tex + ", " + c + ", " +
                (screen ? "(" + args[2].code + ") * vec2(1.0, -1.0)" : args[2].code) + ", " +
                (screen ? "(" + args[3].code + ") * vec2(1.0, -1.0)" : args[3].code) + ")");
    }
    if (base == "textureProj" && args.size() >= 2) {
        if (layered || screen) {
            const char *q = args[1].t.n == 3 ? ".z" : ".w";
            Val uv = {"(" + args[1].code + ").xy / (" + args[1].code + ")" + q, Ty::vec(Ty::Float, 2), false};
            return done("texture(" + tex + ", " + (layered ? coord(uv) : plain(uv)) + ")");
        }
        return {"textureProj(" + tex + ", " + args[1].code + ")", v4, false};
    }
    if (base == "textureSize") {
        std::string lod = args.size() > 1 ? conv(args[1], Ty::scalar(Ty::Int)).code : "0";
        return {"textureSize(" + tex + ", " + lod + ").xy", Ty::vec(Ty::Int, 2), false};
    }
    if (base == "texelFetch" && args.size() >= 3) {
        if (layered) {
            m_layer_needed = true;
            return {"texelFetch(" + tex + ", ivec3(" + args[1].code + ", goanna_layer), " + args[2].code + ")", v4,
                    false};
        }
        if (screen)
            return done("texelFetch(" + tex + ", goanna_screen_texel(ivec2(" + args[1].code + "), textureSize(" +
                    tex + ", " + args[2].code + ")), " + args[2].code + ")");
        return {"texelFetch(" + tex + ", " + args[1].code + ", " + args[2].code + ")", v4, false};
    }
    if (base == "textureGather" || base == "textureOffset" || base == "textureLodOffset" ||
            base == "texelFetchOffset") {
        warn(base + " is read without its offset");
        if (base == "texelFetchOffset" && !layered) {
            std::string p = screen ? "goanna_screen_texel(ivec2(" + args[1].code + "), textureSize(" +
                                           tex + ", " + args[2].code + "))"
                                   : args[1].code;
            return done("texelFetch(" + tex + ", " + p + ", " + args[2].code + ")");
        }
        std::string c = layered ? coord(args[1]) : plain(args[1]);
        if (base == "textureLodOffset")
            return done("textureLod(" + tex + ", " + c + ", " + fl(2) + ")");
        return done("texture(" + tex + ", " + c + ")");
    }
    warn("texture function " + fn + " on '" + sampler + "' not translated");
    return {"vec4(0.0)", v4, false};
}

Val Translator::call(const Expr &e) {
    // a.length()
    if (e.method_of) {
        Val o = expr(e.method_of);
        if (e.text == "length")
            return {o.code + ".length()", Ty::scalar(Ty::Int), false};
        warn("method ." + e.text + "() not supported");
        return {o.code + "." + e.text + "()", Ty(), false};
    }
    const std::string &fn = e.text;
    // Sampler calls: the first argument names the sampler.
    bool texfn = fn.rfind("texture", 0) == 0 || fn.rfind("shadow2D", 0) == 0 || fn.rfind("texelFetch", 0) == 0 ||
            fn == "texelFetchOffset";
    if (texfn && !e.a.empty() && e.a[0]->kind == Expr::Ident) {
        const std::string &s = e.a[0]->text;
        auto &g = m_globals[si(m_stage)];
        auto it = g.find(s);
        bool is_sampler = (it != g.end() && it->second.t.b == Ty::Sampler) ||
                (!findLocal(s) && it == g.end() && (s == "texture" || s == "gtexture" || s == "lightmap" ||
                                                          s == "noisetex" || s == "normals" || s == "specular"));
        const VarSym *ls = findLocal(s);
        if (ls && ls->t.b == Ty::Sampler) {
            // A sampler parameter of a helper: the call passes through, and a
            // shadow comparison reads lit as the shadow samplers do.
            std::vector<Val> args;
            for (auto &a : e.a) args.push_back(expr(a));
            if (ls->t.name.find("Shadow") != std::string::npos)
                return fn.rfind("shadow2D", 0) == 0 ? Val{"vec4(1.0)", Ty::vec(Ty::Float, 4), false}
                                                    : Val{"1.0", Ty::scalar(Ty::Float), false};
            std::string g = fn;
            static const std::pair<const char *, const char *> legacy[] = {{"texture2DLod", "textureLod"},
                    {"texture2DGrad", "textureGrad"}, {"texture2D", "texture"}, {"texture3D", "texture"}};
            for (auto &l : legacy)
                if (g == l.first) g = l.second;
            std::string c;
            for (size_t i = 0; i < args.size(); ++i) c += (i ? ", " : "") + (i >= 2 && g != "texelFetch" && g != "textureGrad" ? conv(args[i], Ty::scalar(Ty::Float)).code : args[i].code);
            if (g == "textureSize") return {g + "(" + c + ")", Ty::vec(Ty::Int, 2), false};
            return {g + "(" + c + ")", Ty::vec(Ty::Float, 4), false};
        }
        if (is_sampler && !ls) {
            std::vector<Val> args;
            args.push_back({s, Ty(), false});
            for (size_t i = 1; i < e.a.size(); ++i)
                args.push_back(expr(e.a[i]));
            return textureCall(fn, s, args, e);
        }
    }
    if (fn == "ftransform" && m_stage == Stage::Vertex) {
        bool f;
        Val vtx = builtinIdent("gl_Vertex", f);
        std::string mvp = needGlobal(m_o.shadow_pass ? "iris_shadow_gl_ModelViewProjectionMatrix"
                                                     : "iris_gl_ModelViewProjectionMatrix", "mat4");
        return {"(" + mvp + " * " + vtx.code + ")", Ty::vec(Ty::Float, 4), false};
    }
    std::vector<Val> args;
    for (auto &a : e.a)
        args.push_back(expr(a));
    auto join = [&](const std::vector<Val> &v) {
        std::string s;
        for (size_t i = 0; i < v.size(); ++i) {
            if (i) s += ", ";
            s += v[i].code;
        }
        return s;
    };
    // Constructors
    Ty ct = tyFromName(fn, m_structs);
    if (ct.known() && ct.b != Ty::Sampler && ct.b != Ty::Void) {
        if (e.array_ctor) {
            Ty el = ct;
            for (auto &a : args) a = conv(a, el);
            std::string size = e.array_size ? expr(e.array_size).code : "";
            Ty at = ct;
            at.array = true;
            return {ct.godot() + "[" + size + "](" + join(args) + ")", at, false};
        }
        if (ct.b == Ty::Struct) {
            auto sd = m_struct_defs.find(ct.name);
            if (sd != m_struct_defs.end())
                for (size_t i = 0; i < args.size() && i < sd->second->fields.size(); ++i)
                    args[i] = conv(args[i], specTy(sd->second->fields[i].type));
            return {ct.name + "(" + join(args) + ")", ct, false};
        }
        if (ct.b == Ty::Float) {
            for (auto &a : args) {
                if (a.t.numericInt()) {
                    Ty to = a.t;
                    to.b = Ty::Float;
                    a = conv(a, to);
                }
            }
        }
        if (!ct.isMatrix() && ct.n == 1 && args.size() == 1 && args[0].t == ct)
            return {"(" + args[0].code + ")", ct, false};
        if (ct.isMatrix() && ct.cols != ct.rows) {
            // Godot has square matrices only. A CxR matrix becomes the
            // square one of the larger size, its columns padded with zeros
            // and any missing columns zero, which keeps indexing and the
            // products below (padded and cut back) right. Photon carries
            // pairs of vec3 as mat2x3 this way.
            int m = std::max(ct.cols, ct.rows);
            bool cols_given = (int)args.size() == ct.cols &&
                    std::all_of(args.begin(), args.end(), [&](const Val &a) {
                        return !a.t.isMatrix() && !a.t.array && a.t.n == ct.rows;
                    });
            if (cols_given) {
                std::string sq;
                for (int i = 0; i < m; ++i) {
                    std::string c = i < ct.cols ? padVec(args[i].code, ct.rows, m) : "vec" + std::to_string(m) + "(0.0)";
                    sq += (i ? ", " : "") + c;
                }
                return {ct.godot() + "(" + sq + ")", ct, false};
            }
            if (!(args.size() == 1 && args[0].t.isScalar()))
                warn("non-square matrix " + fn + " built from anything but its columns is not supported by Godot");
        }
        if (ct.isMatrix() && ct.cols == ct.rows && args.size() > 1) {
            // Godot builds a matrix from whole columns only: gather
            // consecutive scalars and vectors into vecN columns.
            int n = ct.rows;
            std::vector<std::string> cols;
            std::string cur;
            int have = 0;
            bool ok = true;
            for (auto &a : args) {
                int w = a.t.isMatrix() ? 0 : a.t.n;
                if (w == 0 || have + w > n) {
                    ok = false;
                    break;
                }
                cur += (have ? ", " : "") + a.code;
                have += w;
                if (have == n) {
                    cols.push_back(w == n && cur == a.code ? a.code : "vec" + std::to_string(n) + "(" + cur + ")");
                    cur.clear();
                    have = 0;
                }
            }
            if (ok && have == 0 && (int)cols.size() == n) {
                std::string s;
                for (size_t i = 0; i < cols.size(); ++i) s += (i ? ", " : "") + cols[i];
                return {ct.godot() + "(" + s + ")", ct, false};
            }
        }
        return {ct.godot() + "(" + join(args) + ")", ct, false};
    }
    // User functions
    if (FuncSym *f = resolve(fn, args)) {
        emitFunction(*f);
        for (size_t i = 0; i < args.size() && i < f->params.size(); ++i)
            args[i] = conv(args[i], f->params[i]);
        for (auto &r : f->routed) {
            const VarSym *l = findLocal(r);
            args.push_back({l ? l->emitted : routedName(r, m_stage), Ty(), false});
        }
        for (auto &in : f->inputs) {
            args.push_back({in, Ty(), false});
            if (!m_in_main && m_cur_func) m_cur_func->inputs.insert(in);
        }
        if (m_cur_func) m_cur_func->busy = m_cur_func->busy; // dependency recorded by emission order
        return {f->emitted + "(" + join(args) + ")", f->ret, false};
    }
    // Built in functions
    Ty widest;
    bool anyFloat = false;
    for (auto &a : args) {
        if (a.t.b == Ty::Float) anyFloat = true;
        if (!widest.known() || (a.t.known() && (a.t.n > widest.n || a.t.isMatrix()))) widest = a.t;
    }
    if (genericFloatFunctions().count(fn)) {
        // Only these have int overloads; the rest take floats alone.
        static const std::set<std::string> intToo = {"abs", "sign", "min", "max", "clamp", "mix"};
        if (anyFloat || !intToo.count(fn)) {
            for (auto &a : args)
                if (a.t.numericInt()) {
                    Ty to = a.t;
                    to.b = Ty::Float;
                    a = conv(a, to);
                }
            if (widest.known()) widest.b = Ty::Float;
        }
        return {fn + "(" + join(args) + ")", widest, false};
    }
    auto withFloats = [&]() {
        for (auto &a : args)
            if (a.t.numericInt()) {
                Ty to = a.t;
                to.b = Ty::Float;
                a = conv(a, to);
            }
    };
    if (fn == "length" || fn == "distance" || fn == "dot" || fn == "determinant") {
        withFloats();
        return {fn + "(" + join(args) + ")", Ty::scalar(Ty::Float), false};
    }
    if (fn == "modf" && args.size() == 2) {
        // Godot has it, with the whole part an out parameter as in GLSL;
        // the second argument is a variable, so it is passed unconverted.
        if (args[0].t.numericInt()) {
            Ty to = args[0].t;
            to.b = Ty::Float;
            args[0] = conv(args[0], to);
        }
        return {fn + "(" + join(args) + ")", args[0].t, false};
    }
    if (fn == "cross") {
        withFloats();
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Float, 3), false};
    }
    if (fn == "outerProduct") {
        withFloats();
        int c = args.size() > 1 ? args[1].t.n : 4, r = args.empty() ? 4 : args[0].t.n;
        return {fn + "(" + join(args) + ")", Ty::mat(c, r), false};
    }
    if (fn == "all" || fn == "any")
        return {fn + "(" + join(args) + ")", Ty::scalar(Ty::Bool), false};
    if (fn == "not")
        return {fn + "(" + join(args) + ")", args.empty() ? Ty() : args[0].t, false};
    if (fn == "lessThan" || fn == "lessThanEqual" || fn == "greaterThan" || fn == "greaterThanEqual" ||
            fn == "equal" || fn == "notEqual") {
        if (args.size() == 2) promote(args[0], args[1]);
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Bool, widest.n), false};
    }
    if (fn == "isnan" || fn == "isinf")
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Bool, widest.n), false};
    if (fn == "floatBitsToInt") return {fn + "(" + join(args) + ")", Ty::vec(Ty::Int, widest.n), false};
    if (fn == "floatBitsToUint") return {fn + "(" + join(args) + ")", Ty::vec(Ty::Uint, widest.n), false};
    if (fn == "intBitsToFloat" || fn == "uintBitsToFloat")
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Float, widest.n), false};
    if (fn == "packUnorm2x16" || fn == "packSnorm2x16" || fn == "packUnorm4x8" || fn == "packSnorm4x8" ||
            fn == "packHalf2x16")
        return {fn + "(" + join(args) + ")", Ty::scalar(Ty::Uint), false};
    if (fn == "unpackUnorm2x16" || fn == "unpackSnorm2x16" || fn == "unpackHalf2x16")
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Float, 2), false};
    if (fn == "unpackUnorm4x8" || fn == "unpackSnorm4x8")
        return {fn + "(" + join(args) + ")", Ty::vec(Ty::Float, 4), false};
    if (fn == "bitCount" || fn == "findLSB" || fn == "findMSB" || fn == "bitfieldExtract" ||
            fn == "bitfieldInsert" || fn == "bitfieldReverse")
        return {fn + "(" + join(args) + ")", widest, false};
    if (fn == "texture2D" || fn.compare(0, 7, "texture") == 0) {
        warn("texture call on a sampler expression not translated");
        return {"vec4(0.0)", Ty::vec(Ty::Float, 4), false};
    }
    warn("unknown function '" + fn + "'");
    return {fn + "(" + join(args) + ")", Ty(), false};
}

Val Translator::expr(const ExprP &ep) {
    const Expr &e = *ep;
    switch (e.kind) {
    case Expr::Lit: {
        Val v;
        switch (e.lit) {
        case Expr::LFloat: v = {floatLiteral(e.text), Ty::scalar(Ty::Float), false}; break;
        case Expr::LUint: v = {e.text, Ty::scalar(Ty::Uint), false}; break;
        case Expr::LBool: v = {e.text, Ty::scalar(Ty::Bool), false}; break;
        case Expr::LInt: v = {e.text, Ty::scalar(Ty::Int), true}; break;
        }
        return v;
    }
    case Expr::Ident: return ident(e);
    case Expr::Unary: {
        Val o = expr(e.a[0]);
        if (o.int_lit && e.text == "-")
            return {"-" + o.code, o.t, true};
        return {e.text + "(" + o.code + ")", o.t, false};
    }
    case Expr::Postfix: {
        Val o = expr(e.a[0]);
        return {o.code + e.text, o.t, false};
    }
    case Expr::Binary: {
        Val l = expr(e.a[0]), r = expr(e.a[1]);
        const std::string &op = e.text;
        if (op == "&&" || op == "||")
            return {"(" + l.code + " " + op + " " + r.code + ")", Ty::scalar(Ty::Bool), false};
        if (op == "^^")
            return {"(" + l.code + " != " + r.code + ")", Ty::scalar(Ty::Bool), false};
        if (op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=") {
            promote(l, r);
            return {"(" + l.code + " " + op + " " + r.code + ")", Ty::scalar(Ty::Bool), false};
        }
        if (op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == "%") {
            if (op == "%" && (l.t.b == Ty::Float || r.t.b == Ty::Float)) {
                promote(l, r);
                return {"mod(" + l.code + ", " + r.code + ")", l.t.n >= r.t.n ? l.t : r.t, false};
            }
            if (op != "<<" && op != ">>") promote(l, r);
            // GLSL lets an integer vector meet a scalar here; Godot wants
            // the scalar widened (Photon's ivec2 & int).
            auto widen = [](Val &s, const Ty &v) {
                if (!s.t.numericInt() || s.t.n != 1 || v.n < 2 || v.isMatrix() || v.array) return;
                Ty to = Ty::vec(v.b, v.n);
                s = {to.godot() + "(" + s.code + ")", to, false};
            };
            if (l.t.known() && r.t.known()) {
                widen(r, l.t);
                widen(l, r.t);
            }
            return {"(" + l.code + " " + op + " " + r.code + ")", l.t.n >= r.t.n ? l.t : r.t, false};
        }
        // + - * /
        // An identity texture matrix times a coordinate is the coordinate.
        // Written out, Godot 4.5.1's constant folding of mat4(1.0) * vec4
        // crashes the editor and the client alike (seen on Complementary).
        if (op == "*" && l.code == "mat4(1.0)" && r.t.n == 4 && !r.t.isMatrix())
            return r;
        // A non-square matrix is square in Godot (see the constructor): the
        // vector is padded to its size and the product cut back to the
        // width GLSL gives.
        if (op == "*" && l.t.isMatrix() && l.t.cols != l.t.rows && !r.t.isMatrix() && r.t.n == l.t.cols) {
            int m = std::max(l.t.cols, l.t.rows);
            Val rf = r;
            if (rf.t.numericInt()) rf = conv(rf, Ty::vec(Ty::Float, rf.t.n));
            return {cutVec("(" + l.code + " * " + padVec(rf.code, l.t.cols, m) + ")", m, l.t.rows),
                    Ty::vec(Ty::Float, l.t.rows), false};
        }
        if (op == "*" && r.t.isMatrix() && r.t.cols != r.t.rows && !l.t.isMatrix() && l.t.n == r.t.rows) {
            int m = std::max(r.t.cols, r.t.rows);
            Val lf = l;
            if (lf.t.numericInt()) lf = conv(lf, Ty::vec(Ty::Float, lf.t.n));
            return {cutVec("(" + padVec(lf.code, r.t.rows, m) + " * " + r.code + ")", m, r.t.cols),
                    Ty::vec(Ty::Float, r.t.cols), false};
        }
        promote(l, r);
        Ty t;
        if (l.t.known() && r.t.known()) {
            if (op == "*" && l.t.isMatrix() && r.t.isMatrix()) t = Ty::mat(r.t.cols, l.t.rows);
            else if (op == "*" && l.t.isMatrix() && !r.t.isMatrix() && r.t.n > 1) t = Ty::vec(Ty::Float, l.t.rows);
            else if (op == "*" && r.t.isMatrix() && !l.t.isMatrix() && l.t.n > 1) t = Ty::vec(Ty::Float, r.t.cols);
            else if (l.t.isMatrix()) t = l.t;
            else if (r.t.isMatrix()) t = r.t;
            else t = l.t.n >= r.t.n ? l.t : r.t;
        }
        return {"(" + l.code + " " + op + " " + r.code + ")", t, false};
    }
    case Expr::Assign: {
        Val l = expr(e.a[0]), r = expr(e.a[1]);
        if (e.text == "=" || e.text == "+=" || e.text == "-=" || e.text == "*=" || e.text == "/=") {
            if (l.t.b == Ty::Float && r.t.numericInt()) {
                Ty to = r.t;
                to.b = Ty::Float;
                r = conv(r, to);
            } else if (l.t.b == Ty::Uint && r.t.b == Ty::Int) {
                Ty to = r.t;
                to.b = Ty::Uint;
                r = conv(r, to);
            }
        }
        if (e.text == "%=" && l.t.b == Ty::Float)
            return {l.code + " = mod(" + l.code + ", " + conv(r, l.t.n == 1 ? l.t : r.t).code + ")", l.t, false};
        return {l.code + " " + e.text + " " + r.code, l.t, false};
    }
    case Expr::Ternary: {
        Val c = expr(e.a[0]), a = expr(e.a[1]), b = expr(e.a[2]);
        promote(a, b);
        return {"(" + c.code + " ? " + a.code + " : " + b.code + ")", a.t.known() ? a.t : b.t, false};
    }
    case Expr::Call: return call(e);
    case Expr::Member: return member(e);
    case Expr::Index: {
        // gl_FragData[n] and gl_TexCoord[n] and gl_TextureMatrix[n]
        if (e.a[0]->kind == Expr::Ident && !findLocal(e.a[0]->text)) {
            const std::string &n = e.a[0]->text;
            const Expr &ix = *e.a[1];
            if (n == "gl_FragData" || n == "gl_TexCoord" || n == "gl_TextureMatrix") {
                if (ix.kind != Expr::Lit) {
                    warn(n + " indexed by a non-constant");
                    return {"vec4(0.0)", Ty::vec(Ty::Float, 4), false};
                }
                int k = std::atoi(ix.text.c_str());
                if (n == "gl_FragData") {
                    m_legacy_fragment_output = true;
                    m_out_written.insert(k);
                    return {"goanna_out_" + std::to_string(k), Ty::vec(Ty::Float, 4), false};
                }
                if (n == "gl_TexCoord") {
                    std::string v = "goanna_v_TexCoord" + std::to_string(k);
                    addDecl("varying vec4 " + v + ";");
                    return {v, Ty::vec(Ty::Float, 4), false};
                }
                if (k == 1) {
                    m_texmat1 = true;
                    return {"goanna_lightmap_texmat", Ty::mat(4, 4), false};
                }
                return {"mat4(1.0)", Ty::mat(4, 4), false};
            }
        }
        Val o = expr(e.a[0]), i = expr(e.a[1]);
        Ty t;
        if (o.t.array) t = o.t.elem();
        else if (o.t.isMatrix()) t = Ty::vec(Ty::Float, o.t.rows);
        else if (o.t.known()) t = Ty::scalar(o.t.b);
        if (i.t.b == Ty::Uint) i.code = "int(" + i.code + ")";
        // A column of a padded non-square matrix, cut back to its rows.
        if (!o.t.array && o.t.isMatrix() && o.t.rows < o.t.cols)
            return {cutVec(o.code + "[" + i.code + "]", o.t.cols, o.t.rows), t, false};
        return {o.code + "[" + i.code + "]", t, false};
    }
    case Expr::Comma: {
        Val l = expr(e.a[0]), r = expr(e.a[1]);
        return {l.code + ", " + r.code, r.t, false};
    }
    }
    return {"0.0", Ty(), false};
}

// ---- statements

std::string Translator::declStmt(const Stmt &s, const std::string &pad) {
    std::string out;
    Ty base = specTy(s.type);
    for (auto &d : s.decls) {
        Ty t = base;
        std::string size;
        bool array = s.type.array || d.array;
        if (d.array) size = d.size ? expr(d.size).code : "";
        else if (s.type.array) size = s.type.size ? expr(s.type.size).code : "";
        if (array) t.array = true;
        std::string init;
        if (d.has_list) {
            Ty el = t.elem();
            for (size_t i = 0; i < d.init_list.size(); ++i) {
                if (i) init += ", ";
                init += conv(expr(d.init_list[i]), el).code;
            }
            init = "{" + init + "}";
        } else if (d.init) {
            init = conv(expr(d.init), t).code;
        }
        std::string name = declareLocal(d.name, t);
        out += pad + (s.is_const ? "const " : "") + base.elem().godot() + " " + name +
                (array ? "[" + size + "]" : "") + (init.empty() ? "" : " = " + init) + ";\n";
    }
    return out;
}

std::string Translator::stmt(const StmtP &sp, int indent) {
    const Stmt &s = *sp;
    std::string pad(indent, '\t');
    switch (s.kind) {
    case Stmt::Block: {
        m_scopes.emplace_back();
        std::string o = pad + "{\n";
        for (auto &c : s.body)
            o += stmt(c, indent + 1);
        o += pad + "}\n";
        m_scopes.pop_back();
        return o;
    }
    case Stmt::Decl: return declStmt(s, pad);
    case Stmt::ExprS: {
        // Godot has no comma operator: a, b; is two statements.
        std::vector<ExprP> parts;
        std::function<void(const ExprP &)> split = [&](const ExprP &x) {
            if (x->kind == Expr::Comma) {
                split(x->a[0]);
                split(x->a[1]);
            } else {
                parts.push_back(x);
            }
        };
        split(s.e);
        std::string o;
        for (auto &x : parts) o += pad + expr(x).code + ";\n";
        return o;
    }
    case Stmt::If: {
        std::string o = pad + "if (" + expr(s.e).code + ")\n";
        o += s.s1->kind == Stmt::Block ? stmt(s.s1, indent) : pad + "{\n" + stmt(s.s1, indent + 1) + pad + "}\n";
        if (s.s2) {
            o += pad + "else\n";
            o += s.s2->kind == Stmt::Block ? stmt(s.s2, indent)
                                           : pad + "{\n" + stmt(s.s2, indent + 1) + pad + "}\n";
        }
        return o;
    }
    case Stmt::For: {
        m_scopes.emplace_back();
        std::string init;
        if (s.s1) {
            init = stmt(s.s1, 0);
            while (!init.empty() && (init.back() == '\n' || init.back() == ';')) init.pop_back();
        }
        std::string cond = s.e ? expr(s.e).code : "";
        std::string iter = s.e2 ? expr(s.e2).code : "";
        ++m_loop_depth;
        std::string body = s.s3->kind == Stmt::Block ? stmt(s.s3, indent)
                                                     : pad + "{\n" + stmt(s.s3, indent + 1) + pad + "}\n";
        --m_loop_depth;
        m_scopes.pop_back();
        return pad + "for (" + init + "; " + cond + "; " + iter + ")\n" + body;
    }
    case Stmt::While: {
        std::string c = expr(s.e).code;
        ++m_loop_depth;
        std::string body = stmt(s.s1, indent + (s.s1->kind == Stmt::Block ? 0 : 1));
        --m_loop_depth;
        if (s.s1->kind != Stmt::Block) body = pad + "{\n" + body + pad + "}\n";
        return pad + "while (" + c + ")\n" + body;
    }
    case Stmt::Do: {
        ++m_loop_depth;
        std::string body = stmt(s.s1, indent + (s.s1->kind == Stmt::Block ? 0 : 1));
        --m_loop_depth;
        if (s.s1->kind != Stmt::Block) body = pad + "{\n" + body + pad + "}\n";
        return pad + "do\n" + body + pad + "while (" + expr(s.e).code + ");\n";
    }
    case Stmt::Return: {
        if (m_in_main) {
            // main's body runs inside a one pass loop, so the epilogue after
            // it still writes the outputs.
            m_main_return = true;
            if (m_loop_depth > 0 || m_switch_depth > 0)
                warn("return from main inside a loop or switch leaves the outputs unwritten");
            else
                return pad + "break;\n";
            return pad + "return;\n";
        }
        if (!s.e) return pad + "return;\n";
        Val v = expr(s.e);
        if (m_cur_func) v = conv(v, m_cur_func->ret);
        return pad + "return " + v.code + ";\n";
    }
    case Stmt::Break: return pad + "break;\n";
    case Stmt::Continue: return pad + "continue;\n";
    case Stmt::Discard:
        if (m_stage != Stage::Fragment) warn("discard outside the fragment stage");
        return pad + "discard;\n";
    case Stmt::Switch: {
        Val sv = expr(s.e);
        m_switch_uint.push_back(sv.t.b == Ty::Uint);
        std::string o = pad + "switch (" + sv.code + ") {\n";
        ++m_switch_depth;
        m_scopes.emplace_back();
        for (auto &c : s.body)
            o += stmt(c, indent + 1);
        m_scopes.pop_back();
        --m_switch_depth;
        m_switch_uint.pop_back();
        return o + pad + "}\n";
    }
    case Stmt::Case: {
        Val c = expr(s.e);
        // a uint switch wants uint labels
        if (!m_switch_uint.empty() && m_switch_uint.back() && c.t.b == Ty::Int) c = conv(c, Ty::scalar(Ty::Uint));
        return pad + "case " + c.code + ":\n";
    }
    case Stmt::Default: return pad + "default:\n";
    case Stmt::Empty: return "";
    }
    return "";
}

// ---- routing stage globals through helper functions

std::string Translator::routedName(const std::string &pack, Stage st) {
    const VarSym &v = m_globals[si(st)].at(pack);
    return v.kind == 1 ? "goanna_vx_" + v.emitted : v.emitted;
}

void Translator::route(Stage st) {
    auto &globals = m_globals[si(st)];
    auto &funcs = m_funcs[si(st)];
    std::map<std::string, std::set<std::string>> direct, callees;
    std::function<void(const ExprP &, std::set<std::string> &, std::set<std::string> &)> we =
            [&](const ExprP &e, std::set<std::string> &d, std::set<std::string> &c) {
                if (!e) return;
                if (e->kind == Expr::Ident) {
                    auto it = globals.find(e->text);
                    if (it != globals.end() && it->second.kind != 0) d.insert(e->text);
                }
                if (e->kind == Expr::Call && funcs.count(e->text)) c.insert(e->text);
                for (auto &x : e->a) we(x, d, c);
                we(e->method_of, d, c);
                we(e->array_size, d, c);
            };
    std::function<void(const StmtP &, std::set<std::string> &, std::set<std::string> &)> ws =
            [&](const StmtP &s, std::set<std::string> &d, std::set<std::string> &c) {
                if (!s) return;
                we(s->e, d, c);
                we(s->e2, d, c);
                for (auto &dc : s->decls) {
                    we(dc.init, d, c);
                    we(dc.size, d, c);
                    for (auto &x : dc.init_list) we(x, d, c);
                }
                ws(s->s1, d, c);
                ws(s->s2, d, c);
                ws(s->s3, d, c);
                for (auto &b : s->body) ws(b, d, c);
            };
    for (auto &kv : funcs)
        for (auto &f : kv.second) {
            if (!f.f->body) continue;
            std::set<std::string> d;
            ws(f.f->body, d, callees[kv.first]);
            // a parameter of the same name shadows the global
            for (auto &p : f.f->params) d.erase(p.name);
            direct[kv.first].insert(d.begin(), d.end());
        }
    for (bool changed = true; changed;) {
        changed = false;
        for (auto &kv : callees)
            for (auto &c : kv.second) {
                auto &mine = direct[kv.first];
                size_t before = mine.size();
                mine.insert(direct[c].begin(), direct[c].end());
                changed |= mine.size() != before;
            }
    }
    for (auto &kv : funcs)
        for (auto &f : kv.second) {
            auto &d = direct[kv.first];
            f.routed.assign(d.begin(), d.end());
            m_routed_all[si(st)].insert(d.begin(), d.end());
        }
}

// ---- functions

void Translator::emitFunction(FuncSym &f) {
    if (f.done || f.busy) return;
    if (!f.f->body) {
        warn("function '" + f.f->name + "' is declared but never defined");
        f.done = true;
        return;
    }
    f.busy = true;
    // Save the caller's state; this function is emitted on its own.
    auto scopes = std::move(m_scopes);
    auto locals = std::move(m_local_names);
    bool in_main = m_in_main;
    FuncSym *outer = m_cur_func;
    int ld = m_loop_depth, sd = m_switch_depth;
    m_scopes.clear();
    m_scopes.emplace_back();
    m_local_names.clear();
    m_in_main = false;
    m_cur_func = &f;
    m_loop_depth = m_switch_depth = 0;

    std::string sig = f.ret.godot() + (f.ret.array ? "[]" : "") + " " + f.emitted + "(";
    for (size_t i = 0; i < f.f->params.size(); ++i) {
        const Param &p = f.f->params[i];
        Ty t = f.params[i];
        if (i) sig += ", ";
        if (!p.qual.empty() && p.qual != "in") sig += p.qual + " ";
        if (p.is_const && (p.qual.empty() || p.qual == "in")) sig += "const ";
        std::string name = declareLocal(p.name.empty() ? "goanna_unused" + std::to_string(i) : p.name, t);
        sig += t.elem().godot() + " " + name;
        if (t.array) sig += "[" + (p.size ? expr(p.size).code : (f.f->params[i].type.size ? expr(f.f->params[i].type.size).code : "")) + "]";
    }
    for (auto &r : f.routed) {
        const VarSym &v = m_globals[si(f.stage)].at(r);
        std::string n = routedName(r, f.stage);
        if (v.kind == 2) m_out_written.insert(m_out_names[r]);
        sig += std::string(sig.back() == '(' ? "" : ", ") + "inout " + v.t.elem().godot() + " " + n;
        if (v.t.array) warn("array '" + r + "' passed to a function is not supported");
        m_scopes.back()[r] = {n, v.t};
    }
    std::string body = stmt(f.f->body, 0);
    for (auto &in : f.inputs) {
        std::string decl = stageBuiltin(in, f.stage);
        std::string type = decl.substr(0, decl.find(' '));
        sig += std::string(sig.back() == '(' ? "" : ", ") + "in " + type + " " + in;
    }
    sig += ")";
    f.code = sig + "\n" + body;
    bool shared = false;
    if (f.stage == Stage::Fragment) {
        // The same function in both stages (a library both include) is
        // emitted once; a different body under the same name is renamed.
        auto v = m_funcs[0].find(f.f->name);
        if (v != m_funcs[0].end())
            for (auto &vf : v->second)
                if (vf.key == f.key && vf.emitted == f.emitted && vf.done) {
                    if (vf.code == f.code) {
                        shared = true;
                    } else {
                        f.emitted = uniqueGlobal(f.f->name + "_frag");
                        size_t paren = sig.find('(');
                        size_t sp = sig.rfind(' ', paren);
                        f.code = sig.substr(0, sp + 1) + f.emitted + sig.substr(paren) + "\n" + body;
                    }
                }
    }
    if (!shared)
        m_func_order.push_back(f.code);

    m_scopes = std::move(scopes);
    m_local_names = std::move(locals);
    m_in_main = in_main;
    m_cur_func = outer;
    m_loop_depth = ld;
    m_switch_depth = sd;
    f.busy = false;
    f.done = true;
}

// ---- globals

bool Translator::collectGlobals(Stage st, std::string &err) {
    m_stage = st;
    Unit &u = m_unit[si(st)];
    auto &globals = m_globals[si(st)];
    // Structs are shared: both stages see the same definition, emitted once.
    for (auto &it : u.items) {
        if (it.kind != Item::StructItem) continue;
        if (m_struct_defs.count(it.def.name)) continue;
        m_structs.insert(it.def.name);
        m_struct_defs[it.def.name] = &it.def;
        std::string code = "struct " + it.def.name + " {\n";
        for (auto &f : it.def.fields) {
            Ty t = specTy(f.type);
            std::string size = f.size ? "" : "";
            code += "\t" + t.godot() + " " + f.name;
            if (f.array) {
                m_scopes.emplace_back();
                code += "[" + (f.size ? expr(f.size).code : "") + "]";
                m_scopes.pop_back();
            }
            code += ";\n";
        }
        code += "};";
        m_struct_code.push_back(code);
        m_used_names.insert(it.def.name);
    }
    m_scopes.clear();
    m_scopes.emplace_back();
    // Fragment outputs: a located one keeps its location, and unlocated ones
    // take the lowest locations left, in declaration order, as a GL linker
    // assigns them and as the screen space chain's translator does.
    auto locationOf = [](const std::string &layout) {
        auto p = layout.find("location");
        if (p == std::string::npos) return -1;
        auto eq = layout.find('=', p);
        return eq == std::string::npos ? -1 : std::atoi(layout.c_str() + eq + 1);
    };
    std::set<int> located;
    if (st == Stage::Fragment)
        for (auto &it : u.items)
            if (it.kind == Item::GlobalItem && it.global.storage == "out" && locationOf(it.global.layout) >= 0)
                located.insert(locationOf(it.global.layout));
    int out_loc = 0;
    if (st == Stage::Vertex) {
        // gl_Position is a local of vertex(), passed to any helper that
        // writes it.
        globals["gl_Position"] = {"goanna_gl_Position", Ty::vec(Ty::Float, 4), 3};
        m_vin.insert("goanna_gl_Position");
    }
    // gl_FogFragCoord is carried like a pack's own varying, so it shares a
    // slot and costs nothing where the fragment stage does not read it.
    m_used_names.insert("goanna_v_FogFragCoord");
    globals["gl_FogFragCoord"] = {"goanna_v_FogFragCoord", Ty::scalar(Ty::Float), st == Stage::Vertex ? 1 : 3};
    m_carried[si(st)]["gl_FogFragCoord"] = {"goanna_v_FogFragCoord", Ty::scalar(Ty::Float), false, {}};
    for (auto &it : u.items) {
        if (it.kind == Item::FunctionItem) {
            const Function &f = it.function;
            if (f.name == "main") continue;
            FuncSym fs;
            fs.f = &f;
            fs.stage = st;
            fs.emitted = godotReserved().count(f.name) ? "p_" + f.name : f.name;
            fs.ret = specTy(f.ret);
            fs.key = f.name + "(";
            for (auto &p : f.params) {
                Ty t = specTy(p.type);
                if (p.array) t.array = true;
                fs.params.push_back(t);
                fs.key += t.godot() + (t.array ? "[]" : "") + ",";
            }
            fs.key += ")";
            auto &list = m_funcs[si(st)][f.name];
            bool replaced = false;
            for (auto &existing : list) {
                if (existing.key == fs.key) {
                    if (!existing.f->body && f.body) existing.f = &f; // a prototype, then the definition
                    replaced = true;
                }
            }
            if (!replaced) list.push_back(fs);
            continue;
        }
        if (it.kind != Item::GlobalItem) continue;
        const Global &g = it.global;
        Ty base = specTy(g.type);
        for (auto &d0 : g.decls) {
            // vec2[8] x is x[8]
            Declarator d = d0;
            if (g.type.array && !d.array) {
                d.array = true;
                d.size = g.type.size;
            }
            Ty t = base;
            if (d.array) t.array = true;
            const std::string &st_ = g.storage;
            if (st_ == "uniform") {
                if (t.b == Ty::Sampler) {
                    globals[d.name] = {d.name, t};
                    continue;
                }
                if (d.name == "renderStage") {
                    addDecl("uniform int goanna_render_stage = " + std::to_string(m_o.render_stage) + ";");
                    globals[d.name] = {"goanna_render_stage", t};
                    continue;
                }
                // A custom uniform named like a standard one replaces it, as
                // in the screen space chain.
                if (m_o.custom_uniforms.count(d.name) && !d.array && t.b != Ty::Struct &&
                        !(m_o.shadow_pass && findShadowFixed(d.name))) {
                    // a custom uniform, evaluated on the CPU each frame
                    globals[d.name] = {needGlobal("iris_cu_" + d.name, t.godot()), t};
                    continue;
                }
                if (const GlobalDef *gd = m_o.shadow_pass && findShadowFixed(d.name) ? findShadowFixed(d.name)
                                                                                    : findGlobal(d.name)) {
                    Ty gt = tyFromName(gd->type, m_structs);
                    std::string code = gd->godot;
                    if (gt != t && !t.array) {
                        // the pack declared it with another type: convert on read
                        code = t.godot() + "(" + gd->godot + ")";
                        warn("uniform '" + d.name + "' declared " + t.godot() + ", supplied as " + gd->type);
                    }
                    needGlobal(gd->godot, gd->type);
                    globals[d.name] = {code, t};
                    continue;
                }
                if (d.name == "chunkOffset") {
                    globals[d.name] = {"vec3(0.0)", t};
                    continue;
                }
                auto &other_u = m_globals[1 - si(st)];
                auto ou = other_u.find(d.name);
                if (ou != other_u.end() && ou->second.t == t) {
                    globals[d.name] = ou->second;
                    continue;
                }
                std::string name = uniqueGlobal(d.name);
                std::string init;
                if (d.init) init = " = " + conv(expr(d.init), t).code;
                else warn("uniform '" + d.name + "' is not an Iris uniform, reads zero");
                std::string size = d.array ? "[" + (d.size ? expr(d.size).code : "") + "]" : "";
                addDecl("uniform " + t.elem().godot() + " " + name + size + init + ";");
                globals[d.name] = {name, t};
                continue;
            }
            bool vary_out = st == Stage::Vertex && (st_ == "varying" || st_ == "out");
            bool vary_in = st == Stage::Fragment && (st_ == "varying" || st_ == "in");
            if (vary_out || vary_in) {
                // Both stages name a varying the same; its Godot name is fixed
                // by whichever stage saw it first.
                std::string name;
                auto &other = m_globals[1 - si(st)];
                auto o = other.find(d.name);
                if (o != other.end()) {
                    name = o->second.emitted;
                } else {
                    name = uniqueGlobal(d.name);
                }
                std::string interp = g.interp;
                if ((t.b == Ty::Int || t.b == Ty::Uint || t.b == Ty::Bool) && interp.find("flat") == std::string::npos)
                    interp = "flat";
                if (interp.find("centroid") != std::string::npos || interp.find("noperspective") != std::string::npos ||
                        interp.find("sample") != std::string::npos)
                    interp = interp.find("flat") != std::string::npos ? "flat" : "";
                // A varying is carried packed (packVaryings): the vertex
                // stage writes a local, copied into a shared slot at the
                // end of vertex(); the fragment stage reads a local of
                // fragment() unpacked from the slot. Several scalars then
                // share one interpolator, which matters because Godot counts
                // varyings one per declaration, its own included, against a
                // limit of 32 (MakeUp's terrain needed 33), and a varying
                // the fragment stage never reads costs nothing. A struct
                // varying (Photon's water carries its fog parameters in
                // one), which Godot refuses, goes field by field, and a bool
                // as a flat int.
                std::vector<std::pair<std::string, Ty>> fields;
                bool carry = !d.array && carriable(t);
                if (t.b == Ty::Struct && !d.array && m_struct_defs.count(t.name)) {
                    carry = true;
                    for (auto &f : m_struct_defs.at(t.name)->fields) {
                        Ty ft = specTy(f.type);
                        if (f.array || !carriable(ft)) carry = false;
                        fields.push_back({f.name, ft});
                    }
                    if (fields.empty()) carry = false;
                    if (!carry) warn("struct varying '" + d.name + "' has a field Godot cannot carry in a varying");
                }
                if (carry) {
                    globals[d.name] = {name, t, st == Stage::Vertex ? 1 : 3};
                    m_carried[si(st)][d.name] = {name, t, interp.find("flat") != std::string::npos, fields};
                    continue;
                }
                if (t.b == Ty::Bool)
                    warn("bool varying '" + d.name + "' is not allowed in Godot");
                std::string size = d.array ? "[" + (d.size ? expr(d.size).code : "") + "]" : "";
                addDecl("varying " + (interp.empty() ? "" : interp + " ") + t.elem().godot() + " " + name + size + ";");
                globals[d.name] = {name, t, st == Stage::Vertex ? 1 : 0};
                continue;
            }
            if (st == Stage::Vertex && (st_ == "attribute" || st_ == "in")) {
                bool found = false;
                if (d.name == "mc_Entity") m_mc_entity_type = g.type.name;
                if (d.name == "mc_midTexCoord") m_mc_midtex_type = g.type.name;
                // Known attributes resolve through builtinIdent on use.
                static const std::set<std::string> known = {"mc_Entity", "mc_midTexCoord", "at_tangent",
                        "at_midBlock", "vaPosition", "vaNormal", "vaColor", "vaUV0", "vaUV1", "vaUV2"};
                found = known.count(d.name) > 0;
                if (!found) {
                    warn("attribute '" + d.name + "' is not supplied, reads zero");
                    globals[d.name] = {"(" + t.godot() + "(0))", t};
                    if (t.b == Ty::Float) globals[d.name].emitted = t.godot() + "(0.0)";
                }
                continue;
            }
            if (st == Stage::Fragment && st_ == "out") {
                int loc = locationOf(g.layout);
                if (loc < 0) {
                    while (located.count(out_loc)) ++out_loc;
                    loc = out_loc++;
                }
                std::string name = "goanna_out_" + std::to_string(loc);
                // An output keeps the type the pack gave it (Photon's
                // shadow program writes a vec3), widened to a vec4 where
                // it is drawn (outVec4).
                Ty ot = Ty::vec(Ty::Float, 4);
                if (!t.array && !t.isMatrix() && (t.b == Ty::Float || t.b == Ty::Int || t.b == Ty::Uint))
                    ot = t;
                globals[d.name] = {name, ot, 2};
                m_out_names[d.name] = loc;
                m_out_types[loc] = ot;
                continue;
            }
            bool promote_const = st_.empty() && (d.init || d.has_list) && !assigned(d.name) &&
                    (d.has_list ? std::all_of(d.init_list.begin(), d.init_list.end(),
                                          [&](const ExprP &x) { return constExpr(x, st); })
                                : constExpr(d.init, st));
            if (st_ == "const" || promote_const) {
                m_consts[si(st)].insert(d.name);
                std::string init = d.has_list ? "" : (d.init ? conv(expr(d.init), t).code : "");
                if (d.has_list) {
                    for (size_t i = 0; i < d.init_list.size(); ++i)
                        init += (i ? ", " : "") + conv(expr(d.init_list[i]), t.elem()).code;
                    init = "{" + init + "}";
                }
                auto &other = m_globals[1 - si(st)];
                auto o = other.find(d.name);
                std::string name;
                if (o != other.end() && o->second.t == t) {
                    name = o->second.emitted;
                } else {
                    name = uniqueGlobal(d.name);
                }
                std::string size = d.array ? "[" + (d.size ? expr(d.size).code : "") + "]" : "";
                // Godot wants a global const array sized and initialised
                // from a list.
                if (d.array && d.init && d.init->kind == Expr::Call && d.init->array_ctor) {
                    init.clear();
                    for (size_t i = 0; i < d.init->a.size(); ++i)
                        init += (i ? ", " : "") + conv(expr(d.init->a[i]), t.elem()).code;
                    init = "{" + init + "}";
                    if (!d.size) size = "[" + std::to_string(d.init->a.size()) + "]";
                } else if (d.array && d.has_list && !d.size) {
                    size = "[" + std::to_string(d.init_list.size()) + "]";
                }
                addDecl("const " + t.elem().godot() + " " + name + size + " = " + init + ";");
                globals[d.name] = {name, t};
                continue;
            }
            if (st_.empty()) {
                // A plain global variable. Godot has none: one with an
                // initialiser that is never assigned becomes a function
                // returning the initialiser; anything else a local of each
                // main body, which holds only if no other function writes it.
                // An initialiser reading a local of main (a carried varying,
                // Mellow's dFdx(texcoord)) makes a local too: a function
                // could not see it.
                std::function<bool(const ExprP &)> readsLocal = [&](const ExprP &e) {
                    if (!e) return false;
                    if (e->kind == Expr::Ident) {
                        auto it = globals.find(e->text);
                        if (it != globals.end() && it->second.kind != 0) return true;
                    }
                    for (auto &x : e->a)
                        if (readsLocal(x)) return true;
                    return readsLocal(e->method_of);
                };
                if (d.init && !d.array && !assigned(d.name) && !readsLocal(d.init)) {
                    std::string fname = uniqueGlobal("goanna_global_" + d.name);
                    m_scopes.emplace_back();
                    FuncSym lazy;
                    lazy.stage = st;
                    FuncSym *outer = m_cur_func;
                    m_cur_func = &lazy;
                    std::string init = conv(expr(d.init), t).code;
                    m_cur_func = outer;
                    m_scopes.pop_back();
                    std::string params;
                    for (auto &in : lazy.inputs) {
                        std::string decl = stageBuiltin(in, st);
                        params += (params.empty() ? "" : ", ") + std::string("in ") +
                                decl.substr(0, decl.find(' ')) + " " + in;
                        m_lazy_inputs[fname].push_back(in);
                    }
                    m_func_order.push_back(t.godot() + " " + fname + "(" + params + ") {\n\treturn " + init +
                            ";\n}\n");
                    globals[d.name] = {"goanna_lazy_fn:" + fname, t};
                } else {
                    std::string name = uniqueGlobal(d.name);
                    globals[d.name] = {name, t, 3};
                    std::string size = d.array ? "[" + (d.size ? expr(d.size).code : "") + "]" : "";
                    std::string init;
                    if (d.init) {
                        m_scopes.emplace_back();
                        init = " = " + conv(expr(d.init), t).code;
                        m_scopes.pop_back();
                    }
                    m_main_locals[si(st)].push_back(t.elem().godot() + " " + name + size + init);
                }
                continue;
            }
            if (st_ == "in" || st_ == "out" || st_ == "varying" || st_ == "attribute") {
                // an out in the fragment's sense handled above; others ignored
                continue;
            }
            warn("storage '" + st_ + "' for '" + d.name + "' is not supported");
        }
    }
    (void)err;
    return true;
}

std::string Translator::emitMain(Stage st, std::string &err) {
    m_stage = st;
    const Function *main = nullptr;
    for (auto &it : m_unit[si(st)].items)
        if (it.kind == Item::FunctionItem && it.function.name == "main" && it.function.body)
            main = &it.function;
    if (!main) {
        err = std::string(st == Stage::Vertex ? "vertex" : "fragment") + " stage has no main";
        return "";
    }
    m_scopes.clear();
    m_scopes.emplace_back();
    m_local_names.clear();
    m_in_main = true;
    m_cur_func = nullptr;
    m_main_return = false;
    for (auto &r : m_routed_all[si(st)]) {
        const VarSym &v = m_globals[si(st)].at(r);
        if (v.kind == 1) m_scopes.back()[r] = {routedName(r, st), v.t};
    }
    m_loop_depth = m_switch_depth = 0;
    std::string body;
    for (auto &s : main->body->body)
        body += stmt(s, 2);
    m_in_main = false;
    if (m_main_return)
        body = "\tfor (int goanna_once = 0; goanna_once < 1; goanna_once++) {\n" + body + "\t}\n";
    else {
        // one level of indent less
        std::string b2;
        std::stringstream ss(body);
        std::string line;
        while (std::getline(ss, line)) b2 += (line.size() && line[0] == '\t' ? line.substr(1) : line) + "\n";
        body = b2;
    }
    return body;
}

// The prologue line that sets up a built in input.
std::string Translator::stageBuiltin(const std::string &local, Stage st) {
    if (st == Stage::Vertex) {
        if (local == "goanna_gl_Vertex") return "vec4 goanna_gl_Vertex = MODEL_MATRIX * vec4(VERTEX, 1.0);";
        if (local == "goanna_gl_Normal") return "vec3 goanna_gl_Normal = normalize(mat3(MODEL_MATRIX) * NORMAL);";
        if (local == "goanna_gl_Color") {
            if (m_o.surface == GbuffersSurface::SkyBasic || m_o.surface == GbuffersSurface::SkyTextured) {
                addDecl("uniform vec4 goanna_sky_colour = vec4(1.0);");
                return "vec4 goanna_gl_Color = goanna_sky_colour;";
            }
            if (m_o.surface == GbuffersSurface::Clouds) {
                // The face shade in the vertex colour, times the deck's
                // colour and opacity as Luanti's cloud material applies it.
                addDecl("uniform vec4 goanna_cloud_colour = vec4(1.0);");
                return "vec4 goanna_gl_Color = COLOR * goanna_cloud_colour;";
            }
            return "vec4 goanna_gl_Color = goanna_vertex_colour(COLOR, CUSTOM2, mat3(MODEL_MATRIX) * NORMAL);";
        }
        // Cloud geometry has no texture or light coordinates; Iris gives
        // such a vertex format zero texture coordinates and full light.
        if (local == "goanna_gl_MultiTexCoord0" && m_o.surface == GbuffersSurface::Clouds)
            return "vec4 goanna_gl_MultiTexCoord0 = vec4(0.0, 0.0, 0.0, 1.0);";
        if (local == "goanna_gl_MultiTexCoord1" && m_o.surface == GbuffersSurface::Clouds)
            return "vec4 goanna_gl_MultiTexCoord1 = vec4(240.0, 240.0, 0.0, 1.0);";
        if (local == "goanna_gl_MultiTexCoord0") return "vec4 goanna_gl_MultiTexCoord0 = vec4(UV, 0.0, 1.0);";
        if (local == "goanna_gl_MultiTexCoord1") return "vec4 goanna_gl_MultiTexCoord1 = vec4(CUSTOM2.gb * 240.0, 0.0, 1.0);";
        if (local == "goanna_gl_Entity") return "vec4 goanna_gl_Entity = vec4(goanna_block_entity(UV2.y), -1.0, 0.0, 0.0);";
        if (local == "goanna_gl_Tangent") return "vec4 goanna_gl_Tangent = vec4(normalize(mat3(MODEL_MATRIX) * TANGENT), 1.0);";
        if (local == "goanna_gl_MidBlock") return "vec4 goanna_gl_MidBlock = vec4(goanna_mid_block(MODEL_MATRIX, VERTEX, NORMAL), 0.0);";
        if (local == "goanna_gl_Position") return "vec4 goanna_gl_Position = vec4(0.0, 0.0, 0.0, 1.0);";
        if (local == "goanna_gl_Ignored") return "vec4 goanna_gl_Ignored = vec4(0.0);";
    } else {
        if (local == "goanna_gl_FragCoord") return "vec4 goanna_gl_FragCoord = goanna_frag_coord(FRAGCOORD, VIEWPORT_SIZE, VERTEX, iris_gbufferProjection);";
        if (local == "goanna_gl_FragDepth") return "float goanna_gl_FragDepth = 0.0;";
    }
    return "";
}

// Whether code names an identifier: a whole word, not a member after a dot.
static bool mentions(const std::string &code, const std::string &name) {
    auto word = [](char c) { return std::isalnum((unsigned char)c) || c == '_'; };
    for (size_t k = code.find(name); k != std::string::npos; k = code.find(name, k + 1)) {
        if (k > 0 && (word(code[k - 1]) || code[k - 1] == '.')) continue;
        size_t e = k + name.size();
        if (e < code.size() && word(code[e])) continue;
        return true;
    }
    return false;
}

// The carried varyings (see collectGlobals) into as few slots as they fit:
// each value split into float, int or uint runs of one to four components,
// grouped by base type and by flat or smooth interpolation, and packed
// largest first into four component slots. A varying the fragment stage
// never names gets no slot. vertex_out copies the vertex locals into the
// slots at the end of vertex(); fragment_in rebuilds the fragment's locals
// at the start of fragment().
void Translator::packVaryings(const std::string &reads, std::string &vertex_out, std::string &fragment_in) {
    struct Item {
        std::string from; // the vertex expression
        int n = 1;
        int group = 0; // 0 smooth float, 1 flat float, 2 flat int, 3 flat uint
        bool zero = false; // the vertex stage does not write it
    };
    std::vector<Item> items;
    auto groupOf = [](Ty::B b, bool flat) { return b == Ty::Float ? (flat ? 1 : 0) : b == Ty::Uint ? 3 : 2; };
    auto zero = [](int group, int n) {
        std::string s = group == 3 ? "0u" : group == 2 ? "0" : "0.0";
        if (n == 1) return s;
        return std::string(group == 3 ? "u" : group == 2 ? "i" : "") + "vec" + std::to_string(n) + "(" + s + ")";
    };
    // Items for one value of type t, from the vertex expression from (empty
    // when the vertex stage does not write it: zeros).
    std::function<void(const std::string &, const Ty &, bool, std::vector<int> &)> parts =
            [&](const std::string &from, const Ty &t, bool flat, std::vector<int> &out) {
                Item it;
                it.zero = from.empty();
                if (t.isMatrix()) {
                    int d = std::max(t.cols, t.rows);
                    for (int c = 0; c < d; ++c) {
                        it.n = d;
                        it.group = groupOf(Ty::Float, flat);
                        it.from = from.empty() ? zero(it.group, d) : from + "[" + std::to_string(c) + "]";
                        out.push_back((int)items.size());
                        items.push_back(it);
                    }
                    return;
                }
                it.n = t.b == Ty::Bool ? 1 : t.n;
                it.group = t.b == Ty::Bool ? 2 : groupOf(t.b, flat || t.b != Ty::Float);
                it.from = from.empty() ? zero(it.group, it.n)
                        : t.b == Ty::Bool ? "(" + from + " ? 1 : 0)" : from;
                out.push_back((int)items.size());
                items.push_back(it);
            };
    struct Use {
        const Carried *c;
        std::vector<int> items;
    };
    std::vector<Use> uses;
    for (auto &kv : m_carried[1]) {
        const Carried &c = kv.second;
        if (!mentions(reads, c.emitted)) continue;
        auto v = m_carried[0].find(kv.first);
        std::string from = v == m_carried[0].end() ? "" : routedName(kv.first, Stage::Vertex);
        Use u{&c, {}};
        if (c.fields.empty()) {
            parts(from, c.t, c.flat, u.items);
        } else {
            for (auto &f : c.fields)
                parts(from.empty() ? "" : from + "." + f.first, f.second, c.flat, u.items);
        }
        uses.push_back(u);
    }
    // First fit, largest first, within each group. An item that fits whole
    // in no open slot is split over the room the open slots have left, when
    // that is enough, so a group takes as few slots as its components need.
    std::vector<int> order(items.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = (int)i;
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return items[a].n > items[b].n; });
    struct Piece {
        int item, from, n; // components [from, from + n) of the item
    };
    struct Slot {
        int group, used;
        std::vector<Piece> pieces;
        std::string name;
    };
    std::vector<Slot> slots;
    // Where each item's components went, in order: slot and component.
    std::vector<std::vector<std::pair<int, int>>> placed(items.size());
    auto put = [&](int i, int s, int from, int n) {
        for (int c = 0; c < n; ++c) placed[i].push_back({s, slots[s].used + c});
        slots[s].pieces.push_back({i, from, n});
        slots[s].used += n;
    };
    for (int i : order) {
        const Item &it = items[i];
        int s = -1, room = 0;
        for (size_t k = 0; k < slots.size(); ++k) {
            if (slots[k].group != it.group) continue;
            if (s < 0 && slots[k].used + it.n <= 4) s = (int)k;
            room += 4 - slots[k].used;
        }
        if (s >= 0) {
            put(i, s, 0, it.n);
        } else if (room >= it.n) {
            int from = 0;
            for (size_t k = 0; k < slots.size() && from < it.n; ++k) {
                if (slots[k].group != it.group || slots[k].used == 4) continue;
                int n = std::min(4 - slots[k].used, it.n - from);
                put(i, (int)k, from, n);
                from += n;
            }
        } else {
            slots.push_back({it.group, 0, {}, ""});
            put(i, (int)slots.size() - 1, 0, it.n);
        }
    }
    auto typeOf = [](int group, int n) {
        if (n == 1) return std::string(group == 3 ? "uint" : group == 2 ? "int" : "float");
        return std::string(group == 3 ? "u" : group == 2 ? "i" : "") + "vec" + std::to_string(n);
    };
    std::ostringstream vo, fo;
    for (size_t k = 0; k < slots.size(); ++k) {
        Slot &s = slots[k];
        s.name = uniqueGlobal("goanna_pk" + std::to_string(k));
        std::string type = typeOf(s.group, s.used);
        addDecl("varying " + std::string(s.group == 0 ? "" : "flat ") + type + " " + s.name + ";");
        std::vector<std::string> parts_of;
        for (auto &p : s.pieces) {
            const Item &it = items[p.item];
            if (p.n == it.n)
                parts_of.push_back(it.from);
            else if (it.zero)
                parts_of.push_back(zero(it.group, p.n));
            else
                parts_of.push_back(it.from + "." + std::string("xyzw").substr(p.from, p.n));
        }
        std::string value = parts_of.size() == 1 ? parts_of[0] : type + "(";
        if (parts_of.size() > 1) {
            for (size_t j = 0; j < parts_of.size(); ++j) value += (j ? ", " : "") + parts_of[j];
            value += ")";
        }
        vo << "\t" << s.name << " = " << value << ";\n";
    }
    // An item read back: its components from their slots, joined into one
    // vector when they lie apart.
    auto access = [&](int i) {
        const auto &pl = placed[i];
        std::vector<std::string> runs;
        for (size_t c = 0; c < pl.size();) {
            const Slot &s = slots[pl[c].first];
            size_t e = c + 1;
            while (e < pl.size() && pl[e].first == pl[c].first && pl[e].second == pl[e - 1].second + 1) ++e;
            bool whole = pl[c].second == 0 && (int)(e - c) == s.used;
            runs.push_back(whole ? s.name : s.name + "." + std::string("xyzw").substr(pl[c].second, e - c));
            c = e;
        }
        if (runs.size() == 1) return runs[0];
        std::string v = typeOf(items[i].group, items[i].n) + "(";
        for (size_t j = 0; j < runs.size(); ++j) v += (j ? ", " : "") + runs[j];
        return v + ")";
    };
    // The value of type t rebuilt from its items, taken in order from k.
    auto rebuild = [&](const Ty &t, const std::vector<int> &its, size_t &k) {
        if (t.isMatrix()) {
            int d = std::max(t.cols, t.rows);
            std::string m = "mat" + std::to_string(d) + "(";
            for (int c = 0; c < d; ++c) m += (c ? ", " : "") + access(its[k++]);
            return m + ")";
        }
        if (t.b == Ty::Bool) return "(" + access(its[k++]) + " != 0)";
        return access(its[k++]);
    };
    for (auto &u : uses) {
        size_t k = 0;
        std::string value;
        if (u.c->fields.empty()) {
            value = rebuild(u.c->t, u.items, k);
        } else {
            value = u.c->t.name + "(";
            for (size_t j = 0; j < u.c->fields.size(); ++j)
                value += (j ? ", " : "") + rebuild(u.c->fields[j].second, u.items, k);
            value += ")";
        }
        fo << "\t" << u.c->t.godot() << " " << u.c->emitted << " = " << value << ";\n";
    }
    vertex_out = vo.str();
    fragment_in = fo.str();
}

bool Translator::run(const Program &p, std::string &err) {
    // ---- preprocess and parse both stages
    MacroTable base;
    // The macro set the pack loader and the screen space chain use too.
    for (auto &m : standardMacros())
        defineMacro(base, m.first, m.second);
    for (auto &kv : m_o.defines)
        base[kv.first] = kv.second;
    m_r.drawbuffers = scanDrawBuffers(p.fsh);
    const std::string *src[2] = {&p.vsh, &p.fsh};
    for (int s = 0; s < 2; ++s) {
        MacroTable m = base;
        defineMacro(m, s == 0 ? "VERTEX_SHADER" : "FRAGMENT_SHADER");
        std::string pp;
        std::vector<std::string> perr;
        preprocess(*src[s], m, pp, perr);
        // Read the live directive after conditionals and option macros,
        // rather than the pack-wide inventory of all source branches.
        std::map<std::string, std::string> active_consts;
        scanConsts(pp, active_consts);
        auto ao = active_consts.find("ambientOcclusionLevel");
        if (ao != active_consts.end()) {
            char *end = nullptr;
            float value = std::strtof(ao->second.c_str(), &end);
            if (end && (*end == 'f' || *end == 'F')) ++end;
            if (end && end != ao->second.c_str() && *end == '\0' && std::isfinite(value))
                m_r.ao_level = std::clamp(value, 0.0f, 1.0f);
            else
                warn("ambientOcclusionLevel is not a numeric literal; using 1.0");
        }
        for (auto &e : perr)
            warn(std::string(s == 0 ? "vsh " : "fsh ") + e);
        std::string perr2;
        if (!ast::parse(pp, m_unit[s], perr2)) {
            err = std::string(s == 0 ? "vertex" : "fragment") + " stage: " + perr2;
            return false;
        }
    }
    // Reserve the shell's own names.
    for (const char *n : {"albedo_array", "normal_array", "spec_array", "albedo_tex", "layer_anim",
                 "goanna_layer", "goanna_anim_layer", "goanna_block_entity", "goanna_vertex_colour",
                 "goanna_frag_coord", "goanna_mid_block", "goanna_to_linear", "goanna_lightmap_texmat",
                 "goanna_iris_block_ids", "goanna_iris_entity_override", "goanna_old_lighting", "goanna_shadow_position",
                 "goanna_node_anim_time"})
        m_used_names.insert(n);

    if (!collectGlobals(Stage::Vertex, err) || !collectGlobals(Stage::Fragment, err))
        return false;

    route(Stage::Vertex);
    route(Stage::Fragment);
    // A carried varying is always a local of vertex(), packed into its slot
    // at the end.
    for (auto &kv : m_carried[0])
        m_routed_all[0].insert(kv.first);
    std::string vbody = emitMain(Stage::Vertex, err);
    if (!err.empty()) return false;
    std::string fbody = emitMain(Stage::Fragment, err);
    if (!err.empty()) return false;
    std::string pack_out, unpack_in;
    {
        // What the fragment stage can read: its main body, its main's
        // locals and every function emitted (a superset, which only costs
        // a slot).
        std::string reads = fbody;
        for (auto &g : m_main_locals[1]) reads += "\n" + g;
        for (auto &f : m_func_order) reads += "\n" + f;
        packVaryings(reads, pack_out, unpack_in);
    }

    // ---- the vertex stage around the pack's body
    std::ostringstream vo, fo;
    vo << "void vertex() {\n";
    // inputs first, in a fixed order
    for (const char *n : {"goanna_gl_Vertex", "goanna_gl_Normal", "goanna_gl_Color", "goanna_gl_MultiTexCoord0",
                 "goanna_gl_MultiTexCoord1", "goanna_gl_Entity", "goanna_gl_Tangent", "goanna_gl_MidBlock",
                 "goanna_gl_Position", "goanna_gl_Ignored"}) {
        if (!m_vin.count(n)) continue;
        vo << "\t" << stageBuiltin(n, Stage::Vertex) << "\n";
    }
    if (m_vin.count("vary:goanna_v_FrontColor") || m_fin.count("vary:goanna_v_FrontColor")) {
        addDecl("varying vec4 goanna_v_FrontColor;");
        // The vertex colour reaches the fragment's gl_Color unless the pack
        // writes gl_FrontColor itself, which it then does below.
        if (!m_vin.count("goanna_gl_Color"))
            vo << "\t" << stageBuiltin("goanna_gl_Color", Stage::Vertex) << "\n";
        vo << "\tgoanna_v_FrontColor = goanna_gl_Color;\n";
    }
    for (auto &r : m_routed_all[0]) {
        const VarSym &v = m_globals[0].at(r);
        if (v.kind == 1) vo << "\t" << v.t.elem().godot() << " " << routedName(r, Stage::Vertex) << ";\n";
    }
    for (auto &g : m_main_locals[0]) vo << "\t" << g << ";\n";
    if (m_layer_needed) {
        addDecl("varying flat int goanna_layer;");
        vo << "\tgoanna_layer = " << "goanna_anim_layer(int(round(UV2.x)))" << ";\n";
    }
    vo << vbody;
    for (auto &r : m_routed_all[0]) {
        const VarSym &v = m_globals[0].at(r);
        if (v.kind != 1 || m_carried[0].count(r)) continue;
        vo << "\t" << v.emitted << " = " << routedName(r, Stage::Vertex) << ";\n";
    }
    vo << pack_out;
    // gl_Position. Plain ftransform() leaves VERTEX alone. Anything else is
    // taken back to a world position through the player camera matrices it
    // was made with, so every pass Godot draws (the shadow pass too) puts
    // the displaced vertex in the same place.
    bool plain = true;
    {
        std::function<void(const StmtP &)> scanS;
        std::function<void(const ExprP &)> scanE = [&](const ExprP &e) {
            if (!e) return;
            if (e->kind == Expr::Assign && e->a[0]->kind == Expr::Ident && e->a[0]->text == "gl_Position") {
                const Expr &r = *e->a[1];
                bool ft = r.kind == Expr::Call && r.text == "ftransform" && e->text == "=";
                if (!ft) plain = false;
            }
            if (e->kind == Expr::Member && e->a[0]->kind == Expr::Ident && e->a[0]->text == "gl_Position") {
                // gl_Position.xy = ... on the left of an assignment
            }
            for (auto &c : e->a) scanE(c);
        };
        scanS = [&](const StmtP &s) {
            if (!s) return;
            scanE(s->e);
            scanE(s->e2);
            for (auto &d : s->decls) scanE(d.init);
            scanS(s->s1);
            scanS(s->s2);
            scanS(s->s3);
            for (auto &c : s->body) scanS(c);
        };
        for (auto &it : m_unit[0].items)
            if (it.kind == Item::FunctionItem && it.function.name == "main") scanS(it.function.body);
        // any other write (gl_Position.y += ...) also moves
        if (vbody.find("goanna_gl_Position.") != std::string::npos &&
                vbody.find("goanna_gl_Position.") < vbody.size())
            for (size_t k = vbody.find("goanna_gl_Position."); k != std::string::npos;
                    k = vbody.find("goanna_gl_Position.", k + 1)) {
                size_t eq = vbody.find_first_of("=;\n", k);
                if (eq != std::string::npos && vbody[eq] == '=' && vbody[eq + 1] != '=') plain = false;
            }
    }
    if (m_routed_all[0].count("gl_Position")) plain = false;
    if (m_o.shadow_pass) {
        // The light's clip position goes out as it is, in Goanna's shadow
        // camera only; see goanna_shadow_position in the shell.
        m_r.moves_vertices = !plain;
        vo << "\tPOSITION = goanna_shadow_position("
           << (m_vin.count("goanna_gl_Position") ? "goanna_gl_Position" : "vec4(2.0, 2.0, 2.0, 1.0)")
           << ", CAMERA_VISIBLE_LAYERS);\n";
    } else if (m_o.surface == GbuffersSurface::SkyBasic || m_o.surface == GbuffersSurface::SkyTextured) {
        // Keep the pack's projected direction, but put the sky at the far
        // depth so even coarse terrain occludes it. The dome follows the eye.
        if (m_vin.count("goanna_gl_Position"))
            vo << "\tPOSITION = vec4(goanna_gl_Position.xy, 0.0, goanna_gl_Position.w);\n";
    } else if (m_vin.count("goanna_gl_Position") && !plain) {
        m_r.moves_vertices = true;
        std::string P = needGlobal("iris_gbufferProjection", "mat4");
        std::string MVI = needGlobal("iris_gbufferModelViewInverse", "mat4");
        std::string CAM = needGlobal("iris_cameraPosition", "vec3");
        vo << "\tVERTEX = goanna_unproject(goanna_gl_Position, " << P << ", " << MVI << ", " << CAM
           << ", MODEL_MATRIX);\n";
    }
    vo << "}\n";

    // ---- the fragment stage
    fo << "void fragment() {\n";
    if (!m_o.shadow_pass && (m_o.surface == GbuffersSurface::SingleCutout ||
            m_o.surface == GbuffersSurface::SingleOpaque ||
            m_o.surface == GbuffersSurface::Translucent)) {
        // One translated shader serves cube leaves, glass and double-sided
        // plants. Preserve the server's per-material culling in colour and
        // secondary outputs, without changing the shadow pass's policy.
        addDecl("uniform bool single_sided = false;");
        fo << "\tif (single_sided && !FRONT_FACING)\n\t\tdiscard;\n";
    }
    if (m_fin.count("goanna_gl_FragCoord")) {
        needGlobal("iris_gbufferProjection", "mat4");
        fo << "\t" << stageBuiltin("goanna_gl_FragCoord", Stage::Fragment) << "\n";

    }
    if (m_fin.count("goanna_gl_FragDepth")) fo << "\t" << stageBuiltin("goanna_gl_FragDepth", Stage::Fragment) << "\n";
    fo << unpack_in;
    for (auto &g : m_main_locals[1]) fo << "\t" << g << ";\n";
    std::vector<int> db = m_r.drawbuffers;
    if (db.empty()) db.push_back(0);
    for (int k : m_out_written) {
        Ty ot = outType(k);
        std::string init = ot.b == Ty::Float && ot.n == 4 ? "vec4(0.0, 0.0, 0.0, 1.0)"
                : ot.godot() + (ot.b == Ty::Float ? "(0.0)" : ot.b == Ty::Uint ? "(0u)" : "(0)");
        fo << "\t" << ot.godot() << " goanna_out_" << k << " = " << init << ";\n";
    }
    fo << fbody;
    // The colour target: whichever output DRAWBUFFERS sends to colortex0,
    // else the first written.
    int colour = -1;
    for (int k : m_out_written)
        if (k < (int)db.size() && db[k] == 0) colour = k;
    if (colour < 0 && !m_out_written.empty()) {
        colour = *m_out_written.begin();
        warn("no output goes to colortex0; output " + std::to_string(colour) + " (colortex" +
                std::to_string(colour < (int)db.size() ? db[colour] : colour) + ") is drawn as the colour");
    }
    if (colour >= 0)
        m_r.colour_target = colour < (int)db.size() ? db[colour] : colour;
    // Every other target written is a second output: a camera drawing that
    // colortex for the chain (kGbuffersPassShift) gets it in place of the
    // colour, which is how a pack's normals, masks and lightmap reach its
    // composite programs past Godot's one colour output. The colour's own
    // target is one too when it is not colortex0, so a pack that keeps its
    // colour in colortex1 finds it there.
    std::map<int, int> second; // colortex -> output
    for (int k : m_out_written) {
        int ct = k < (int)db.size() ? db[k] : k;
        if (ct >= 1 && ct <= 15)
            second[ct] = k;
        else if (k != colour)
            m_r.dropped.push_back(ct);
    }
    for (auto &kv : second)
        m_r.second.push_back(kv.first);
    m_r.reads.assign(m_reads.begin(), m_reads.end());
    if (!m_r.dropped.empty()) {
        std::string list;
        for (int ct : m_r.dropped) list += (list.empty() ? "" : ", ") + std::string("colortex") + std::to_string(ct);
        warn("outputs to " + list + " cannot be expressed and are dropped");
    }
    const bool blended = m_o.surface == GbuffersSurface::Translucent ||
            m_o.surface == GbuffersSurface::SkyTextured || m_o.surface == GbuffersSurface::Clouds;
    if (colour >= 0) {
        std::string c = outVec4(colour);
        if (m_legacy_fragment_output &&
                (m_o.surface == GbuffersSurface::ArrayCutout ||
                 m_o.surface == GbuffersSurface::SingleCutout ||
                 m_o.surface == GbuffersSurface::Translucent ||
                 m_o.surface == GbuffersSurface::Clouds)) {
            std::string ref = needGlobal("iris_alphaTestRef", "float");
            fo << "\tif (" << c << ".a < " << ref << ")\n\t\tdiscard;\n";
        }
        std::string ind;
        // The shadow program draws one target, shadowcolor0.
        const bool split = !m_o.shadow_pass;
        if (split) {
            // A target this program does not write keeps what is under it,
            // as GL's masked write does: alpha 0 where blended, and where
            // opaque the clear value, so the surface still hides what is
            // behind it in that target.
            fo << "\tuint goanna_pass = (CAMERA_VISIBLE_LAYERS >> " << kGbuffersPassShift << "u) & "
               << kGbuffersPassBits << "u;\n";
            fo << "\tif (goanna_pass >= 2u && goanna_pass <= 16u) {\n";
            fo << "\t\tvec4 goanna_second = vec4(0.0);\n";
            for (auto &kv : second)
                fo << "\t\tif (goanna_pass == " << kv.first + 1 << "u)\n\t\t\tgoanna_second = " << outVec4(kv.second)
                   << ";\n";
            for (auto &kv : second)
                if (m_o.packed_targets.count(kv.first)) {
                    fo << "\t\tif (goanna_pass == " << kv.first + 1 << "u)\n"
                       << "\t\t\tgoanna_second.rgb = goanna_pack_unorm16(goanna_second, "
                       << "(CAMERA_VISIBLE_LAYERS & 8192u) != 0u);\n";
                    if (blended) warn("UNORM16 byte transport is exact only for unblended geometry");
                }
            fo << "\t\tALBEDO = goanna_second.rgb;\n";
            if (blended)
                fo << "\t\tALPHA = clamp(goanna_second.a, 0.0, 1.0);\n";
            fo << "\t} else {\n";
            ind = "\t";
        }
        // The shadow program's colour is shadowcolor0, kept as written.
        fo << "\t" << ind << "ALBEDO = "
           << (m_o.shadow_pass ? "clamp(" + c + ".rgb, 0.0, 1.0)" :
                m_o.raw_colour ? c + ".rgb" : "goanna_to_linear(" + c + ".rgb)") << ";\n";
        if (blended)
            fo << "\t" << ind << "ALPHA = clamp(" << c << ".a, 0.0, 1.0);\n";
        if (split)
            fo << "\t}\n";
    } else {
        warn("the fragment stage writes no colour");
        fo << "\tALBEDO = vec3(1.0, 0.0, 1.0);\n";
    }
    fo << "}\n";

    // ---- assembly
    std::ostringstream o;
    o << "// Generated by Goanna from the shader pack program " << m_o.label << ".\n";
    o << "// Translated at load; see src/iris/iris_gbuffers.cpp and docs/design/iris-compat.md.\n";
    o << "shader_type spatial;\n";
    o << "render_mode unshaded, fog_disabled, ";
    // Translucent geometry writes depth in Minecraft, so a pack finds its
    // water in depthtex0 and not in depthtex1 and measures the water's
    // depth from the two (GbuffersOptions::translucent_depth). Godot's own
    // water writes none.
    if (m_o.surface == GbuffersSurface::SkyBasic || m_o.surface == GbuffersSurface::SkyTextured)
        o << "cull_disabled, depth_draw_never;\n";
    else if (m_o.surface == GbuffersSurface::Translucent)
        o << "blend_mix, cull_disabled, " << (m_o.translucent_depth ? "depth_draw_always" : "depth_draw_opaque")
          << ";\n";
    else if (m_o.surface == GbuffersSurface::SingleCutout ||
            m_o.surface == GbuffersSurface::SingleOpaque || m_o.shadow_pass)
        o << "cull_disabled;\n";
    // Minecraft's cloud boxes write depth, so a nearer box hides the faces
    // behind it rather than blending over them.
    else if (m_o.surface == GbuffersSurface::Clouds)
        o << "blend_mix, cull_back, depth_draw_always;\n";
    else
        o << "cull_back;\n";
    if (m_o.surface == GbuffersSurface::ArrayOpaque || m_o.surface == GbuffersSurface::ArrayCutout)
        o << "#define GOANNA_IRIS_ARRAY\n";
    if (m_o.old_lighting)
        o << "#define GOANNA_IRIS_OLD_LIGHTING\n";
    if (m_o.separate_ao && !m_o.shadow_pass)
        o << "#define GOANNA_IRIS_SEPARATE_AO\n";
    o << "const float goanna_iris_ao_level = " << std::showpoint << m_r.ao_level << std::noshowpoint << ";\n";
    if (m_o.shadow_pass)
        o << "#define GOANNA_IRIS_SHADOW\n";
    o << "#include \"res://shaders/iris_gbuffers_shell.gdshaderinc\"\n\n";
    if (m_texmat1)
        o << "const mat4 goanna_lightmap_texmat = mat4(vec4(1.0 / 256.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0 / 256.0, 0.0, 0.0), "
             "vec4(0.0, 0.0, 1.0, 0.0), vec4(1.0 / 32.0, 1.0 / 32.0, 0.0, 1.0));\n";
    for (auto &s : m_struct_code) o << s << "\n";
    for (auto &d : m_decl_lines) o << d << "\n";
    o << "\n";
    for (auto &f : m_func_order) o << f << "\n";
    o << vo.str() << "\n" << fo.str();
    m_r.code = o.str();
    return true;
}

} // namespace

bool translateGbuffers(const Program &p, const GbuffersOptions &o, GbuffersResult &out, std::string &err) {
    out = GbuffersResult();
    Translator t(o, out);
    return t.run(p, err);
}

std::vector<std::string> gbuffersFallback(const std::string &program) {
    std::vector<std::string> out = {program};
    if (program == "gbuffers_terrain_cutout" || program == "gbuffers_terrain_cutout_mip" ||
            program == "gbuffers_terrain_solid") {
        out.push_back("gbuffers_terrain");
    }
    if (program == "gbuffers_skybasic") return {program, "gbuffers_basic"};
    if (program == "gbuffers_skytextured") return {program, "gbuffers_textured", "gbuffers_basic"};
    if (program == "gbuffers_clouds") return {program, "gbuffers_textured", "gbuffers_basic"};
    if (program == "gbuffers_water") out.push_back("gbuffers_terrain");
    for (const char *n : {"gbuffers_textured_lit", "gbuffers_textured", "gbuffers_basic"})
        if (std::find(out.begin(), out.end(), n) == out.end()) out.push_back(n);
    return out;
}

bool gbuffersGlobal(const std::string &pack_name, std::string &godot_name, std::string &godot_type) {
    const GlobalDef *g = findGlobal(pack_name);
    if (!g) return false;
    godot_name = g->godot;
    godot_type = g->type;
    return true;
}

} // namespace iris
} // namespace goanna
