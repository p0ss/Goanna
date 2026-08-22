// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// An Iris or OptiFine shader pack on disk: shaders.properties, the programs
// it ships, the const directives its sources carry, and #include resolution.
// Nothing here touches the GPU; see goanna_iris_effect.h for that.
#pragma once

#include "iris_glsl.h"

#include <map>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

class Pack {
public:
    // `dir` is the pack root (the directory holding shaders/) or the shaders/
    // directory itself. Zips are not read; unpack first.
    bool load(const std::string &dir, std::string &err);

    const std::string &name() const { return m_name; }
    const std::string &shadersDir() const { return m_shaders; }
    const std::map<std::string, std::string> &properties() const { return m_props; }
    // const int colortex0Format = RGBA16F; and friends, gathered from every
    // program source, comments included. Last one read wins, as in Iris.
    const std::map<std::string, std::string> &consts() const { return m_consts; }
    // Program names that have a fragment stage, in discovery order.
    const std::vector<std::string> &programNames() const { return m_programs; }
    bool hasProgram(const std::string &name) const;

    // Reads both stages with #include resolved. A program with no .vsh gets an
    // empty vertex source; the translator supplies a pass through.
    bool program(const std::string &name, Program &out, std::string &err) const;

    // Composite chain order: deferred, deferred1..99, composite, composite1..99,
    // final. Only names that exist are returned.
    std::vector<std::string> compositeChain() const;

private:
    std::string readResolved(const std::string &path, int depth, std::string &err) const;
    std::string findProgramFile(const std::string &name, const char *ext) const;
    std::string m_root, m_shaders, m_name, m_world;
    std::map<std::string, std::string> m_props;
    std::map<std::string, std::string> m_consts;
    std::vector<std::string> m_programs;
};

} // namespace iris
} // namespace goanna
