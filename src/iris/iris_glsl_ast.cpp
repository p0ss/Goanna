// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The GLSL parser for the gbuffers translator. See iris_glsl_ast.h.

#include "iris_glsl_ast.h"

#include <cctype>
#include <cstring>
#include <set>
#include <stdexcept>

namespace goanna {
namespace iris {
namespace ast {

namespace {

struct Token {
    enum Kind { End, Ident, Number, Punct };
    Kind kind = End;
    std::string text;
    int line = 0;
};

const char *kPuncts[] = {"<<=", ">>=", "++", "--", "&&", "||", "^^", "==", "!=", "<=", ">=", "+=", "-=", "*=",
        "/=", "%=", "&=", "|=", "^=", "<<", ">>"};

std::vector<Token> lex(const std::string &s) {
    std::vector<Token> out;
    size_t i = 0, n = s.size();
    int line = 1;
    while (i < n) {
        char c = s[i];
        if (c == '\n') {
            ++line;
            ++i;
            continue;
        }
        if (std::isspace((unsigned char)c)) {
            ++i;
            continue;
        }
        Token t;
        t.line = line;
        if (std::isalpha((unsigned char)c) || c == '_') {
            size_t j = i;
            while (j < n && (std::isalnum((unsigned char)s[j]) || s[j] == '_')) ++j;
            t.kind = Token::Ident;
            t.text = s.substr(i, j - i);
            i = j;
        } else if (std::isdigit((unsigned char)c) || (c == '.' && i + 1 < n && std::isdigit((unsigned char)s[i + 1]))) {
            size_t j = i;
            bool hex = s.compare(i, 2, "0x") == 0 || s.compare(i, 2, "0X") == 0;
            if (hex) j += 2;
            while (j < n) {
                char d = s[j];
                if (std::isalnum((unsigned char)d) || d == '.') {
                    ++j;
                } else if ((d == '+' || d == '-') && !hex && (s[j - 1] == 'e' || s[j - 1] == 'E')) {
                    ++j;
                } else {
                    break;
                }
            }
            t.kind = Token::Number;
            t.text = s.substr(i, j - i);
            i = j;
        } else {
            t.kind = Token::Punct;
            bool found = false;
            for (auto p : kPuncts) {
                size_t l = std::strlen(p);
                if (s.compare(i, l, p) == 0) {
                    t.text = p;
                    i += l;
                    found = true;
                    break;
                }
            }
            if (!found) {
                t.text = std::string(1, c);
                ++i;
            }
        }
        out.push_back(t);
    }
    Token end;
    end.line = line;
    out.push_back(end);
    return out;
}

struct ParseError : std::runtime_error {
    int line;
    ParseError(const std::string &m, int l) : std::runtime_error(m), line(l) {}
};

const std::set<std::string> &qualifierWords() {
    static const std::set<std::string> q = {"flat", "smooth", "noperspective", "centroid", "invariant", "sample",
            "patch", "highp", "mediump", "lowp", "precise", "coherent", "volatile", "restrict", "readonly",
            "writeonly"};
    return q;
}

class Parser {
public:
    explicit Parser(const std::string &src) : m_t(lex(src)) {}

    void unit(Unit &out) {
        while (!at(Token::End)) {
            if (acceptP(";"))
                continue;
            topLevel(out);
        }
    }

private:
    std::vector<Token> m_t;
    size_t m_i = 0;
    std::set<std::string> m_structs;

    const Token &cur() const { return m_t[m_i]; }
    const Token &peek(int k = 1) const { return m_t[std::min(m_i + k, m_t.size() - 1)]; }
    bool at(Token::Kind k) const { return cur().kind == k; }
    bool isP(const char *p) const { return cur().kind == Token::Punct && cur().text == p; }
    bool isW(const char *w) const { return cur().kind == Token::Ident && cur().text == w; }
    bool acceptP(const char *p) {
        if (!isP(p)) return false;
        ++m_i;
        return true;
    }
    bool acceptW(const char *w) {
        if (!isW(w)) return false;
        ++m_i;
        return true;
    }
    [[noreturn]] void fail(const std::string &m) const {
        throw ParseError(m + " near '" + cur().text + "'", cur().line);
    }
    void expectP(const char *p) {
        if (!acceptP(p)) fail(std::string("expected '") + p + "'");
    }
    std::string ident() {
        if (!at(Token::Ident)) fail("expected a name");
        return m_t[m_i++].text;
    }
    bool isTypeName(const std::string &n) const { return isBuiltinTypeName(n) || m_structs.count(n); }

    TypeSpec typeSpec() {
        TypeSpec t;
        t.name = ident();
        if (isP("[")) {
            ++m_i;
            t.array = true;
            if (!isP("]")) t.size = expr();
            expectP("]");
        }
        return t;
    }

    void arraySuffix(bool &array, ExprP &size) {
        if (acceptP("[")) {
            array = true;
            if (!isP("]")) size = expr();
            expectP("]");
        }
    }

    StructDef structBody(const std::string &name) {
        StructDef d;
        d.name = name;
        d.line = cur().line;
        expectP("{");
        while (!acceptP("}")) {
            while (at(Token::Ident) && qualifierWords().count(cur().text)) ++m_i;
            TypeSpec t = typeSpec();
            do {
                StructDef::Field f;
                f.type = t;
                f.name = ident();
                arraySuffix(f.array, f.size);
                d.fields.push_back(f);
            } while (acceptP(","));
            expectP(";");
        }
        m_structs.insert(name);
        return d;
    }

    void declarators(std::vector<Declarator> &out) {
        do {
            Declarator d;
            d.name = ident();
            arraySuffix(d.array, d.size);
            if (acceptP("=")) {
                if (isP("{")) {
                    d.has_list = true;
                    initList(d.init_list);
                } else {
                    d.init = assignment();
                }
            }
            out.push_back(d);
        } while (acceptP(","));
    }

    void initList(std::vector<ExprP> &out) {
        expectP("{");
        if (acceptP("}")) return;
        do {
            if (isP("}")) break;
            out.push_back(assignment());
        } while (acceptP(","));
        expectP("}");
    }

    void topLevel(Unit &out) {
        int line = cur().line;
        if (acceptW("precision")) {
            while (!acceptP(";")) ++m_i;
            return;
        }
        Global g;
        g.line = line;
        std::string interp;
        // layout(...), storage and interpolation qualifiers in any order
        for (;;) {
            if (isW("layout")) {
                ++m_i;
                expectP("(");
                int depth = 1;
                std::string text;
                while (depth > 0) {
                    if (at(Token::End)) fail("unclosed layout(");
                    if (isP("(")) ++depth;
                    if (isP(")") && --depth == 0) break;
                    text += cur().text + " ";
                    ++m_i;
                }
                expectP(")");
                g.layout = text;
                continue;
            }
            if (isW("uniform") || isW("varying") || isW("attribute") || isW("in") || isW("out") ||
                    isW("const") || isW("buffer") || isW("shared")) {
                g.storage = cur().text;
                ++m_i;
                continue;
            }
            if (at(Token::Ident) && qualifierWords().count(cur().text)) {
                const std::string &w = cur().text;
                if (w != "highp" && w != "mediump" && w != "lowp" && w != "invariant" && w != "precise") {
                    if (!interp.empty()) interp += ' ';
                    interp += w;
                }
                ++m_i;
                continue;
            }
            break;
        }
        g.interp = interp;
        if (isW("struct")) {
            ++m_i;
            std::string name = ident();
            Item it;
            it.kind = Item::StructItem;
            it.def = structBody(name);
            it.def.line = line;
            out.items.push_back(it);
            if (acceptP(";")) return;
            // struct S { } s; : a variable of the new type follows
            g.type.name = name;
            declarators(g.decls);
            expectP(";");
            Item gi;
            gi.kind = Item::GlobalItem;
            gi.global = g;
            out.items.push_back(gi);
            return;
        }
        if (at(Token::Ident) && peek().kind == Token::Punct && peek().text == "{" && !g.storage.empty()) {
            fail("interface blocks are not supported");
        }
        if (isW("in") || isW("out")) fail("unexpected qualifier");
        TypeSpec type = typeSpec();
        if (at(Token::Ident) && peek().kind == Token::Punct && peek().text == "(" && g.storage.empty() &&
                g.layout.empty()) {
            Item it;
            it.kind = Item::FunctionItem;
            Function &f = it.function;
            f.ret = type;
            f.name = ident();
            f.line = line;
            expectP("(");
            if (isW("void") && peek().kind == Token::Punct && peek().text == ")") ++m_i;
            if (!isP(")")) {
                do {
                    Param p;
                    for (;;) {
                        if (isW("in") || isW("out") || isW("inout")) {
                            p.qual = cur().text;
                            ++m_i;
                        } else if (isW("const")) {
                            p.is_const = true;
                            ++m_i;
                        } else if (at(Token::Ident) && qualifierWords().count(cur().text)) {
                            ++m_i;
                        } else {
                            break;
                        }
                    }
                    p.type = typeSpec();
                    if (at(Token::Ident)) {
                        p.name = ident();
                        arraySuffix(p.array, p.size);
                    }
                    f.params.push_back(p);
                } while (acceptP(","));
            }
            expectP(")");
            if (!acceptP(";"))
                f.body = block();
            out.items.push_back(it);
            return;
        }
        g.type = type;
        if (acceptP(";")) return; // a bare type, nothing declared
        declarators(g.decls);
        expectP(";");
        Item it;
        it.kind = Item::GlobalItem;
        it.global = g;
        out.items.push_back(it);
    }

    StmtP block() {
        auto s = std::make_shared<Stmt>();
        s->kind = Stmt::Block;
        s->line = cur().line;
        expectP("{");
        while (!acceptP("}")) {
            if (at(Token::End)) fail("unclosed block");
            s->body.push_back(statement());
        }
        return s;
    }

    bool declarationAhead() const {
        // [const] [qualifiers] Type name ... or Type[N] name
        size_t k = m_i;
        while (m_t[k].kind == Token::Ident &&
                (m_t[k].text == "const" || qualifierWords().count(m_t[k].text)))
            ++k;
        if (m_t[k].kind != Token::Ident || !isTypeName(m_t[k].text)) return false;
        const Token &nx = m_t[k + 1];
        if (nx.kind == Token::Ident) return true;
        if (nx.kind == Token::Punct && nx.text == "[") {
            // Type[N] name, as against an index into a variable named like a type
            int depth = 0;
            size_t j = k + 1;
            for (; j < m_t.size(); ++j) {
                if (m_t[j].kind == Token::Punct && m_t[j].text == "[") ++depth;
                if (m_t[j].kind == Token::Punct && m_t[j].text == "]" && --depth == 0) break;
            }
            return j + 1 < m_t.size() && m_t[j + 1].kind == Token::Ident;
        }
        return false;
    }

    StmtP declaration() {
        auto s = std::make_shared<Stmt>();
        s->kind = Stmt::Decl;
        s->line = cur().line;
        for (;;) {
            if (acceptW("const")) {
                s->is_const = true;
                continue;
            }
            if (at(Token::Ident) && qualifierWords().count(cur().text)) {
                ++m_i;
                continue;
            }
            break;
        }
        s->type = typeSpec();
        declarators(s->decls);
        return s;
    }

    StmtP statement() {
        int line = cur().line;
        auto s = std::make_shared<Stmt>();
        s->line = line;
        if (isP("{")) return block();
        if (acceptP(";")) {
            s->kind = Stmt::Empty;
            return s;
        }
        if (acceptW("if")) {
            s->kind = Stmt::If;
            expectP("(");
            s->e = expr();
            expectP(")");
            s->s1 = statement();
            if (acceptW("else")) s->s2 = statement();
            return s;
        }
        if (acceptW("for")) {
            s->kind = Stmt::For;
            expectP("(");
            if (acceptP(";")) {
                s->s1 = nullptr;
            } else if (declarationAhead()) {
                s->s1 = declaration();
                expectP(";");
            } else {
                auto es = std::make_shared<Stmt>();
                es->kind = Stmt::ExprS;
                es->e = expr();
                es->line = line;
                s->s1 = es;
                expectP(";");
            }
            if (!isP(";")) s->e = expr();
            expectP(";");
            if (!isP(")")) s->e2 = expr();
            expectP(")");
            s->s3 = statement();
            return s;
        }
        if (acceptW("while")) {
            s->kind = Stmt::While;
            expectP("(");
            s->e = expr();
            expectP(")");
            s->s1 = statement();
            return s;
        }
        if (acceptW("do")) {
            s->kind = Stmt::Do;
            s->s1 = statement();
            if (!acceptW("while")) fail("expected while");
            expectP("(");
            s->e = expr();
            expectP(")");
            expectP(";");
            return s;
        }
        if (acceptW("return")) {
            s->kind = Stmt::Return;
            if (!isP(";")) s->e = expr();
            expectP(";");
            return s;
        }
        if (acceptW("break")) {
            s->kind = Stmt::Break;
            expectP(";");
            return s;
        }
        if (acceptW("continue")) {
            s->kind = Stmt::Continue;
            expectP(";");
            return s;
        }
        if (acceptW("discard")) {
            s->kind = Stmt::Discard;
            expectP(";");
            return s;
        }
        if (acceptW("switch")) {
            s->kind = Stmt::Switch;
            expectP("(");
            s->e = expr();
            expectP(")");
            expectP("{");
            while (!acceptP("}")) {
                if (at(Token::End)) fail("unclosed switch");
                s->body.push_back(statement());
            }
            return s;
        }
        if (acceptW("case")) {
            s->kind = Stmt::Case;
            s->e = expr();
            expectP(":");
            return s;
        }
        if (acceptW("default")) {
            s->kind = Stmt::Default;
            expectP(":");
            return s;
        }
        if (declarationAhead()) {
            StmtP d = declaration();
            expectP(";");
            return d;
        }
        s->kind = Stmt::ExprS;
        s->e = expr();
        expectP(";");
        return s;
    }

    // ---- expressions

    ExprP make(Expr::Kind k, const std::string &text, int line) {
        auto e = std::make_shared<Expr>();
        e->kind = k;
        e->text = text;
        e->line = line;
        return e;
    }

    ExprP expr() {
        ExprP l = assignment();
        while (isP(",")) {
            int line = cur().line;
            ++m_i;
            ExprP r = assignment();
            ExprP c = make(Expr::Comma, ",", line);
            c->a = {l, r};
            l = c;
        }
        return l;
    }

    ExprP assignment() {
        ExprP l = ternary();
        static const char *ops[] = {"=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^="};
        for (auto op : ops) {
            if (isP(op)) {
                int line = cur().line;
                ++m_i;
                ExprP r = assignment();
                ExprP a = make(Expr::Assign, op, line);
                a->a = {l, r};
                return a;
            }
        }
        return l;
    }

    ExprP ternary() {
        ExprP c = binary(0);
        if (isP("?")) {
            int line = cur().line;
            ++m_i;
            ExprP a = assignment();
            expectP(":");
            ExprP b = assignment();
            ExprP t = make(Expr::Ternary, "?", line);
            t->a = {c, a, b};
            return t;
        }
        return c;
    }

    ExprP binary(int level) {
        static const std::vector<std::vector<const char *>> levels = {
            {"||"}, {"^^"}, {"&&"}, {"|"}, {"^"}, {"&"}, {"==", "!="}, {"<", ">", "<=", ">="}, {"<<", ">>"},
            {"+", "-"}, {"*", "/", "%"}};
        if (level >= (int)levels.size()) return unary();
        ExprP l = binary(level + 1);
        for (;;) {
            bool matched = false;
            for (auto op : levels[level]) {
                if (isP(op)) {
                    int line = cur().line;
                    ++m_i;
                    ExprP r = binary(level + 1);
                    ExprP b = make(Expr::Binary, op, line);
                    b->a = {l, r};
                    l = b;
                    matched = true;
                    break;
                }
            }
            if (!matched) return l;
        }
    }

    ExprP unary() {
        static const char *ops[] = {"++", "--", "+", "-", "!", "~"};
        for (auto op : ops) {
            if (isP(op)) {
                int line = cur().line;
                ++m_i;
                ExprP u = make(Expr::Unary, op, line);
                u->a = {unary()};
                return u;
            }
        }
        return postfix();
    }

    void callArgs(ExprP call) {
        expectP("(");
        if (isW("void") && peek().kind == Token::Punct && peek().text == ")") ++m_i;
        if (!isP(")")) {
            do {
                call->a.push_back(assignment());
            } while (acceptP(","));
        }
        expectP(")");
    }

    ExprP postfix() {
        ExprP e = primary();
        for (;;) {
            int line = cur().line;
            if (isP("[")) {
                ++m_i;
                ExprP i = expr();
                expectP("]");
                ExprP x = make(Expr::Index, "[]", line);
                x->a = {e, i};
                e = x;
            } else if (isP(".")) {
                ++m_i;
                std::string name = ident();
                if (isP("(")) {
                    ExprP c = make(Expr::Call, name, line);
                    c->method_of = e;
                    callArgs(c);
                    e = c;
                } else {
                    ExprP m = make(Expr::Member, name, line);
                    m->a = {e};
                    e = m;
                }
            } else if (isP("++") || isP("--")) {
                ExprP p = make(Expr::Postfix, cur().text, line);
                ++m_i;
                p->a = {e};
                e = p;
            } else {
                return e;
            }
        }
    }

    ExprP primary() {
        int line = cur().line;
        if (acceptP("(")) {
            ExprP e = expr();
            expectP(")");
            return e;
        }
        if (at(Token::Number)) {
            std::string t = cur().text;
            ++m_i;
            ExprP e = make(Expr::Lit, t, line);
            bool hex = t.size() > 1 && (t[1] == 'x' || t[1] == 'X');
            if (!hex && (t.find('.') != std::string::npos || t.find('e') != std::string::npos ||
                                t.find('E') != std::string::npos || t.back() == 'f' || t.back() == 'F'))
                e->lit = Expr::LFloat;
            else if (t.back() == 'u' || t.back() == 'U')
                e->lit = Expr::LUint;
            else
                e->lit = Expr::LInt;
            return e;
        }
        if (isW("true") || isW("false")) {
            ExprP e = make(Expr::Lit, cur().text, line);
            e->lit = Expr::LBool;
            ++m_i;
            return e;
        }
        if (at(Token::Ident)) {
            std::string name = ident();
            if (isP("[") && isTypeName(name)) {
                // float[3](...) or float[](...)
                size_t save = m_i;
                ++m_i;
                ExprP size;
                if (!isP("]")) size = expr();
                expectP("]");
                if (isP("(")) {
                    ExprP c = make(Expr::Call, name, line);
                    c->array_ctor = true;
                    c->array_size = size;
                    callArgs(c);
                    return c;
                }
                m_i = save;
            }
            if (isP("(")) {
                ExprP c = make(Expr::Call, name, line);
                callArgs(c);
                return c;
            }
            return make(Expr::Ident, name, line);
        }
        fail("expected an expression");
    }
};

} // namespace

bool isBuiltinTypeName(const std::string &n) {
    static const std::set<std::string> types = {"void", "bool", "int", "uint", "float", "double", "vec2", "vec3",
            "vec4", "bvec2", "bvec3", "bvec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "dvec2",
            "dvec3", "dvec4", "mat2", "mat3", "mat4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4",
            "mat4x2", "mat4x3", "mat4x4", "sampler1D", "sampler2D", "sampler3D", "samplerCube", "sampler2DRect",
            "sampler1DShadow", "sampler2DShadow", "sampler2DArray", "sampler2DArrayShadow", "samplerCubeShadow",
            "isampler2D", "usampler2D", "isampler3D", "usampler3D", "image2D", "image3D", "uimage2D",
            "iimage2D", "sampler2DMS"};
    return types.count(n) > 0;
}

bool parse(const std::string &src, Unit &out, std::string &err) {
    Parser p(src);
    try {
        p.unit(out);
    } catch (const ParseError &e) {
        err = "line " + std::to_string(e.line) + ": " + e.what();
        return false;
    }
    return true;
}

} // namespace ast
} // namespace iris
} // namespace goanna
