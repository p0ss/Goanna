// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// An Iris or OptiFine shader pack on disk: shaders.properties, the programs
// it ships, the options its sources declare, the const directives they
// carry, its custom uniforms, and #include resolution. Nothing here touches
// the GPU; see goanna_iris_effect.h for that. It is read on the main thread,
// from GoannaIrisEffect::load_pack. Main type: iris::Pack.
#pragma once

#include "iris_expr.h"
#include "iris_glsl.h"

#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace goanna {
namespace iris {

// standardMacros(), the macros a pack sees before its own, is in
// iris_preproc.h, which iris_expr.h brings in.

// GOANNA_SHADERPACK_OPTIONS's form: NAME=value pairs separated by commas
// or spaces. Both GoannaIrisEffect and GoannaIrisGbuffers read the variable
// through this, so the two halves of a pack see one set of options.
std::map<std::string, std::string> parseOptionOverrides(const std::string &text);

class Pack {
public:
    // Option values to use instead of the pack's defaults, as Iris's options
    // file holds them: NAME=value, with true and false for a boolean
    // option. Set before load. Unknown names are ignored and listed by
    // unknownOverrides().
    void setOptionOverrides(const std::map<std::string, std::string> &o) { m_overrides = o; }

    // `dir` is the pack root (the directory holding shaders/) or the shaders/
    // directory itself. Zips are not read; unpack first.
    bool load(const std::string &dir, std::string &err);

    const std::string &name() const { return m_name; }
    const std::string &shadersDir() const { return m_shaders; }
    // shaders.properties after its conditionals have run against the
    // options, so a key inside a dead #if branch is absent.
    const std::map<std::string, std::string> &properties() const { return m_props; }
    // const int colortex0Format = RGBA16F; and friends, gathered from every
    // program source, comments included. Last one read wins, as in Iris.
    const std::map<std::string, std::string> &consts() const { return m_consts; }
    // Options the sources declare, as each will be compiled: a value option
    // maps to its value, a boolean that is on maps to "" and one that is off
    // is absent. Overrides applied. These are the macros the properties
    // conditionals see.
    const std::map<std::string, std::string> &options() const { return m_options; }
    // Boolean options found commented out (//#define NAME), which are off.
    const std::set<std::string> &optionsOff() const { return m_options_off; }
    std::vector<std::string> unknownOverrides() const;
    // uniform.* and variable.* lines, in order, ready to evaluate.
    const CustomUniforms &customUniforms() const { return m_custom; }
    // Problems with the properties file: conditionals that did not parse and
    // custom uniforms that were skipped.
    const std::vector<std::string> &propertyWarnings() const { return m_prop_warnings; }
    // Iris optional features (iris.features.required) the pack needs and
    // Goanna does not supply. Goanna declares none of them, so every name
    // listed is missing, and a pack with any is refused, as Iris refuses
    // one on a loader without them. Read from the preprocessed properties.
    std::vector<std::string> missingFeatures() const;
    // Program names that have a fragment stage, in discovery order.
    const std::vector<std::string> &programNames() const { return m_programs; }
    bool hasProgram(const std::string &name) const;
    // program.<name>.enabled (or program.world0/<name>.enabled) evaluated
    // against the options. True when the pack says nothing.
    bool programEnabled(const std::string &name) const;

    // Reads both stages with #include resolved and the preprocessor
    // conditionals run (#define lines kept), so only the live branch reaches
    // the translator. A program with no .vsh gets a pass through vertex
    // stage. Conditions that would not evaluate are added to `warnings`.
    bool program(const std::string &name, Program &out, std::string &err,
            std::vector<std::string> *warnings = nullptr) const;

    // Composite chain order: deferred, deferred1..99, composite, composite1..99,
    // final. Only names that exist and are enabled are returned.
    std::vector<std::string> compositeChain() const;
    // Programs the chain skipped because the properties disable them.
    std::vector<std::string> disabledPrograms() const;

private:
    std::string readResolved(const std::string &path, int depth, std::string &err) const;
    std::string findProgramFile(const std::string &name, const char *ext) const;
    void scanOptions(const std::string &src);
    void readProperties();
    std::string m_root, m_shaders, m_name, m_world;
    std::map<std::string, std::string> m_props;
    std::map<std::string, std::string> m_consts;
    std::map<std::string, std::string> m_options;
    std::set<std::string> m_options_off;
    std::set<std::string> m_options_seen;
    std::map<std::string, std::string> m_overrides;
    CustomUniforms m_custom;
    std::vector<std::string> m_prop_warnings;
    std::vector<std::string> m_programs;
};

} // namespace iris
} // namespace goanna
