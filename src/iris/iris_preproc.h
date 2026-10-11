// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A C preprocessor for shader pack GLSL, enough of one for the gbuffers
// translator (iris_gbuffers.h), which has to see a program after its
// #ifdef options and macros are resolved: it parses the result into Godot's
// shading language, and a declaration inside an #ifdef cannot be parsed
// before the #ifdef is decided. The screen space chain does not use it;
// glslang preprocesses those programs itself.
//
// Object and function-like #define, #undef, #if, #ifdef, #ifndef, #elif,
// #else and #endif, with defined() and integer and floating arithmetic in
// conditions. #include must already be resolved (iris::Pack does that);
// #version, #extension, #pragma and #line are dropped. Lines that are
// removed stay as blank lines, so a line number in the output is the same
// line in the input.
//
// Written from the C preprocessor's documented behaviour, not from any
// loader's source. Pure string work with no Godot and no shared state, so
// it runs on whichever thread calls it. Main function: iris::preprocess.
#pragma once

#include <map>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

struct Macro {
    bool function = false;
    std::vector<std::string> params;
    std::string body;
};

using MacroTable = std::map<std::string, Macro>;

// Defines `name` as `value`, an object-like macro.
void defineMacro(MacroTable &table, const std::string &name, const std::string &value = "1");

// Preprocesses `src` with the macros in `macros` defined at the start, and
// leaves in `macros` what is defined at the end. Comments are removed. On a
// malformed directive the error names the line and the rest of the source
// is still processed, so a caller can choose to warn rather than fail.
bool preprocess(const std::string &src, MacroTable &macros, std::string &out,
        std::vector<std::string> &errors);

// Evaluates a #if expression after macro expansion, for tests.
bool evalCondition(const std::string &expr, const MacroTable &macros, double &value, std::string &err);

} // namespace iris
} // namespace goanna
