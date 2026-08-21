// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Translation of Iris and OptiFine shader pack GLSL into Vulkan GLSL 450 that
// RenderingDevice::shader_compile_spirv_from_source accepts. This is a
// rewriter over a small, documented dialect, not a GLSL compiler: it only has
// to produce what the driver's compiler will take, and glslang does the rest.
//
// Written from the shader pack format as documented, not from any loader's
// source. See docs/iris-compat.md, "On licence".
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

// Uniform value types we can lay out in a std140 block.
enum class UType { Mat4, Mat3, Mat2, Vec4, Vec3, Vec2, IVec4, IVec3, IVec2, Float, Int, Bool };
const char *utypeName(UType t);
bool utypeFromName(const std::string &name, UType &out);
uint32_t utypeSize(UType t);
uint32_t utypeAlign(UType t);

// A std140 uniform block: the member list, their offsets, and the GLSL that
// declares it. One layout is shared by every program (the standard Iris set),
// and each program may add a second for uniforms it declares that we do not
// know, so the pack still compiles and reads zero.
struct Layout {
    struct Member {
        std::string name;
        UType type;
        uint32_t offset;
    };
    std::vector<Member> members;
    uint32_t size = 0; // bytes used; the buffer wants paddedSize()
    uint32_t paddedSize() const;
    void add(const std::string &name, UType t);
    const Member *find(const std::string &name) const;
    std::string declaration(const char *block, int set, int binding) const;
};

// The standard Iris uniforms, plus Goanna's own fixed function stand ins
// (goanna_mvp and friends, which replace gl_ModelViewProjectionMatrix).
const Layout &standardLayout();

// Samplers Iris defines, each with a fixed binding in descriptor set 0.
// Legacy names (gcolor, gaux1, gdepthtex ...) are rewritten to the canonical
// one by the translator, so a program never declares the same binding twice.
int samplerBinding(const std::string &canonical);
std::string canonicalSampler(const std::string &name);
// Bindings for samplers we do not recognise start here; they get a dummy.
constexpr int kFirstUnknownSamplerBinding = 32;

enum class ProgramKind { Composite, Gbuffers, Shadow };

struct Program {
    std::string name;
    std::string vsh, fsh; // raw source with #include already resolved
};

struct Translated {
    std::string vertex, fragment;
    // Canonical sampler names referenced by either stage, each with the GLSL
    // sampler type the pack declared it as (sampler2D unless it said otherwise)
    // and the binding it was given.
    struct Sampler {
        std::string name, type;
        int binding;
    };
    std::vector<Sampler> samplers;
    Layout extra; // uniforms the pack declared that are not in the standard set
    // Output location -> colortex index, from /* DRAWBUFFERS */ or
    // /* RENDERTARGETS */. Empty means the program declared none.
    std::vector<int> drawbuffers;
    std::vector<std::string> warnings;
};

struct TranslateOptions {
    ProgramKind kind = ProgramKind::Composite;
    std::string extraDefines; // appended to the prelude verbatim
    bool labpbr = false;
};

bool translate(const Program &p, const TranslateOptions &o, Translated &out, std::string &err);

// Helpers shared with the pack loader.
std::string stripComments(const std::string &s);
// Scans raw source (comments included, because packs put these in comments)
// for "const <type> <name> = <value>;" and returns name -> value text.
void scanConsts(const std::string &raw, std::map<std::string, std::string> &out);
// Scans raw source for the DRAWBUFFERS / RENDERTARGETS directive.
std::vector<int> scanDrawBuffers(const std::string &raw);

} // namespace iris
} // namespace goanna
