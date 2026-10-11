// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Expressions in a shader pack's own text, outside the GLSL: the
// preprocessor conditionals `shaders.properties` carries (#if, #ifdef and
// friends, evaluated against the pack's option defaults and the MC_ and
// IRIS_ macros), and the custom uniform language of `uniform.<type>.<name>`
// and `variable.<type>.<name>` lines, which Iris evaluates on the CPU every
// frame. Written from the OptiFine shader documentation (shaders.txt), not
// from any loader's source. See docs/design/iris-compat.md.
//
// Pure C++ with no Godot, so the tests run it without a GPU. A CustomUniforms
// is built on the main thread at load and then only evaluated, on the render
// thread, by GoannaIrisEffect. Main types: iris::Value, iris::Expr and
// iris::CustomUniforms.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

// A scalar or a vector of up to four floats. Booleans are 0 and 1, integers
// are carried as floats and truncated when written to an int uniform.
struct Value {
    int n = 1;
    float v[4] = {0, 0, 0, 0};
    static Value scalar(float f) {
        Value r;
        r.v[0] = f;
        return r;
    }
};

struct ExprNode;

// A parsed expression. Identifiers are resolved at evaluation through a
// callback, so the same tree serves both languages.
class Expr {
public:
    // Parses `text`; on failure returns false with `err` set.
    bool parse(const std::string &text, std::string &err);
    using Lookup = std::function<bool(const std::string &name, Value &out)>;
    // Calls are resolved by `call`, which returns false for an unknown name.
    using Call = std::function<bool(const std::string &name, const std::vector<Value> &args,
            const ExprNode *node, Value &out)>;
    Value eval(const Lookup &lookup, const Call &call) const;
    bool empty() const { return !m_root; }

private:
    std::shared_ptr<ExprNode> m_root;
};

// #if expressions. Identifiers that are macros expand to their value (which
// may itself be an expression); undefined ones are 0; `defined X` and
// `defined(X)` test the table. The result is the C truth of the expression.
bool conditionHolds(const std::string &expr, const std::map<std::string, std::string> &macros, std::string &err);

// Runs the conditional directives over `text`, line by line: #if, #ifdef,
// #ifndef, #elif, #else, #endif, and #define and #undef in live branches,
// which update `macros`. Lines in dead branches and the directives
// themselves come back empty, so line numbers keep. Any other line starting
// with # is left alone (shaders.properties uses # for comments too). With
// `keep_defines`, #define and #undef lines in live branches stay in the
// output, for GLSL that a compiler will preprocess again.
std::string runConditionals(const std::string &text, std::map<std::string, std::string> &macros,
        std::vector<std::string> *errors = nullptr, bool keep_defines = false);

// The pack's `uniform.*` and `variable.*` definitions, in file order. Each
// may read the built in uniforms and every definition before it.
class CustomUniforms {
public:
    struct Def {
        std::string type; // float, int, bool, vec2, vec3, vec4
        std::string name;
        bool is_uniform = true; // false for variable.*, which shaders never see
        std::string source;
        Expr expr;
    };
    // Adds one definition; a later one of the same name replaces it in place,
    // which is what a pack's conditional blocks rely on.
    bool add(const std::string &type, const std::string &name, bool is_uniform, const std::string &text,
            std::string &err);
    // Evaluates every definition in order. `builtin` answers the standard
    // uniforms; `dt` is the frame time in seconds, for smooth().
    void evaluate(const Expr::Lookup &builtin, float dt);
    bool value(const std::string &name, Value &out) const;
    const std::vector<Def> &defs() const { return m_defs; }
    // Identifiers some definition read that nothing answered, so they read
    // zero. For the effect's report.
    const std::vector<std::string> &unresolved() const { return m_unresolved; }

private:
    std::vector<Def> m_defs;
    std::map<std::string, Value> m_values;
    // smooth() state, keyed by its id argument or by the call's node.
    std::map<std::string, float> m_smooth;
    std::vector<std::string> m_unresolved;
    uint64_t m_frame = 0;
};

} // namespace iris
} // namespace goanna
