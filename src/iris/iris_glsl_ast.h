// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A parser for preprocessed shader pack GLSL into a small syntax tree, for
// the gbuffers translator (iris_gbuffers.h), which re-emits a program in
// Godot's shading language and needs to know the type of every expression
// to do it: Godot converts nothing implicitly, where GLSL turns an int into
// a float wherever one is wanted.
//
// It covers the language a gbuffers program is written in: declarations
// with storage, interpolation and layout qualifiers, structs, functions and
// prototypes, every statement, and expressions with GLSL's precedence. It
// does not type anything; iris_gbuffers.cpp does that as it emits. Input
// must already be preprocessed (iris_preproc.h).
//
// Written from the GLSL specification, not from any loader's source. Pure
// data with no Godot and no shared state. Main entry: iris::ast::parse.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace goanna {
namespace iris {
namespace ast {

struct Expr;
struct Stmt;
using ExprP = std::shared_ptr<Expr>;
using StmtP = std::shared_ptr<Stmt>;

// A type as written: a name (float, vec3, sampler2D, a struct) and an
// optional array size written on the type (float[3] x).
struct TypeSpec {
    std::string name;
    bool array = false; // float[N] or float[]
    ExprP size;         // null for float[]
};

struct Expr {
    enum Kind { Lit, Ident, Unary, Postfix, Binary, Assign, Ternary, Call, Member, Index, Comma };
    Kind kind = Lit;
    // Lit: the literal's text; Ident: the name; Unary, Postfix, Binary and
    // Assign: the operator; Call: the callee's name; Member: the field or
    // swizzle.
    std::string text;
    enum LitKind { LInt, LUint, LFloat, LBool };
    LitKind lit = LInt;
    // Unary/Postfix: [operand]; Binary/Assign: [lhs, rhs]; Ternary: [cond,
    // a, b]; Call: the arguments; Member: [object]; Index: [object, index];
    // Comma: [lhs, rhs].
    std::vector<ExprP> a;
    // Call only: float[3](...) is an array constructor (array set, size may
    // be null), and a.length() a method call on `method_of`.
    bool array_ctor = false;
    ExprP array_size;
    ExprP method_of;
    int line = 0;
};

struct Declarator {
    std::string name;
    bool array = false;
    ExprP size; // null for an unsized array
    ExprP init;
    // An initialiser list { a, b } rather than an expression.
    std::vector<ExprP> init_list;
    bool has_list = false;
};

struct Stmt {
    enum Kind { Block, Decl, ExprS, If, For, While, Do, Return, Break, Continue, Discard, Switch, Case, Default,
        Empty };
    Kind kind = Empty;
    std::vector<StmtP> body; // Block, Switch
    ExprP e;                 // ExprS, If cond, While cond, Do cond, For cond, Return value, Switch, Case
    ExprP e2;                // For iteration
    StmtP s1, s2, s3;        // If then/else; For init and body in s1, s3; While/Do body in s1
    // Decl
    bool is_const = false;
    TypeSpec type;
    std::vector<Declarator> decls;
    int line = 0;
};

struct Param {
    std::string qual; // in, out, inout or empty
    bool is_const = false;
    TypeSpec type;
    std::string name;
    bool array = false;
    ExprP size;
};

struct Function {
    TypeSpec ret;
    std::string name;
    std::vector<Param> params;
    StmtP body; // null for a prototype
    int line = 0;
};

struct StructDef {
    std::string name;
    struct Field {
        TypeSpec type;
        std::string name;
        bool array = false;
        ExprP size;
    };
    std::vector<Field> fields;
    int line = 0;
};

// A declaration at global scope.
struct Global {
    // uniform, in, out, varying, attribute, const, or empty for a plain
    // global variable.
    std::string storage;
    std::string interp; // flat, smooth, noperspective, centroid ... joined
    std::string layout; // the text inside layout(...), if any
    TypeSpec type;
    std::vector<Declarator> decls;
    int line = 0;
};

struct Item {
    enum Kind { GlobalItem, FunctionItem, StructItem };
    Kind kind;
    Global global;
    Function function;
    StructDef def;
};

struct Unit {
    std::vector<Item> items;
};

// Parses a preprocessed source. On a syntax error returns false with `err`
// naming the line; what was parsed so far is left in `out`.
bool parse(const std::string &src, Unit &out, std::string &err);

// True for the names GLSL treats as built in types (float, vec3, mat4,
// sampler2D and the rest), which is how the parser tells a declaration from
// an expression statement. Struct names are added per unit by the parser.
bool isBuiltinTypeName(const std::string &name);

} // namespace ast
} // namespace iris
} // namespace goanna
