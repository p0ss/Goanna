// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// The one C preprocessor for shader pack text. It has two users with two
// needs. iris::Pack runs only the conditionals (runConditionals) over
// shaders.properties, block.properties and every program source, so that
// only the live branch of a pack's options reaches anything after it; the
// screen space chain's GLSL then goes to glslang, which expands the macros
// itself. The gbuffers translator (iris_gbuffers.h) parses the result into
// Godot's shading language, which has no preprocessor of the right kind, so
// it runs the full preprocessor (preprocess) on top, expanding macros too.
// One engine serves both, so an #if means the same to the chain and to the
// geometry programs.
//
// Object and function-like #define, #undef, #if, #ifdef, #ifndef, #elif,
// #else and #endif, with defined() and integer and floating arithmetic in
// conditions. #include must already be resolved (iris::Pack does that);
// #version, #extension, #pragma and #line are dropped by the full
// preprocessor. Lines that are removed stay as blank lines, so a line
// number in the output is the same line in the input.
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

// The macros a pack sees before any of its own: MC_VERSION, IS_IRIS and the
// rest. The pack loader, the screen space chain's prelude and the gbuffers
// translator all start from this one set.
const std::map<std::string, std::string> &standardMacros();

// #if expressions over a name to value table. Identifiers that are macros
// expand to their value (which may itself be an expression); undefined ones
// are 0; `defined X` and `defined(X)` test the table. The result is the C
// truth of the expression.
bool conditionHolds(const std::string &expr, const std::map<std::string, std::string> &macros, std::string &err);

// Runs the conditional directives over `text`, line by line: #if, #ifdef,
// #ifndef, #elif, #else, #endif, and #define and #undef in live branches,
// which update `macros`. Lines in dead branches and the directives
// themselves come back empty, so line numbers keep. Text is not expanded
// and comments stay; a directive inside a block comment is ignored. Any
// other line starting with # is left alone (shaders.properties uses # for
// comments too). With `keep_defines`, #define and #undef lines in live
// branches stay in the output, for GLSL that a compiler will preprocess
// again. A function-like macro comes back in `macros` with no value.
std::string runConditionals(const std::string &text, std::map<std::string, std::string> &macros,
        std::vector<std::string> *errors = nullptr, bool keep_defines = false);

} // namespace iris
} // namespace goanna
