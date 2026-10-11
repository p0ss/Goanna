// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The expression languages of a shader pack's properties: preprocessor
// conditionals and custom uniforms. See iris_expr.h.

#include "iris_expr.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <set>
#include <sstream>

namespace goanna {
namespace iris {

// ---------------------------------------------------------------------------
// Tokens

namespace {

enum class Tok { Num, Ident, Op, End };

struct Token {
    Tok kind;
    std::string text;
    double num = 0;
};

bool isIdentChar(char c) { return std::isalnum((unsigned char)c) || c == '_'; }

bool tokenize(const std::string &s, std::vector<Token> &out, std::string &err) {
    size_t i = 0, n = s.size();
    static const char *ops[] = {"&&", "||", "==", "!=", "<=", ">=", "<<", ">>", "(", ")", ",", "!", "~", "*",
            "/", "%", "+", "-", "<", ">", "&", "|", "^", "?", ":", "."};
    while (i < n) {
        char c = s[i];
        if (std::isspace((unsigned char)c)) { ++i; continue; }
        // m.1.2 is a matrix element (column 1, row 2) when it follows a name
        if (c == '.' && i + 1 < n && std::isdigit((unsigned char)s[i + 1]) && !out.empty() &&
                out.back().kind == Tok::Ident) {
            size_t b = ++i;
            while (i < n && std::isdigit((unsigned char)s[i])) ++i;
            out.back().text += "." + s.substr(b, i - b);
            continue;
        }
        if (std::isdigit((unsigned char)c) || (c == '.' && i + 1 < n && std::isdigit((unsigned char)s[i + 1]))) {
            const char *start = s.c_str() + i;
            char *end = nullptr;
            double v;
            if (c == '0' && i + 1 < n && (s[i + 1] == 'x' || s[i + 1] == 'X'))
                v = (double)std::strtoll(start, &end, 16);
            else
                v = std::strtod(start, &end);
            i += end - start;
            // GLSL and C suffixes: 1.0f, 2u, 3L
            while (i < n && (s[i] == 'f' || s[i] == 'F' || s[i] == 'u' || s[i] == 'U' || s[i] == 'l' || s[i] == 'L'))
                ++i;
            out.push_back({Tok::Num, "", v});
            continue;
        }
        if (std::isalpha((unsigned char)c) || c == '_') {
            size_t b = i;
            while (i < n && isIdentChar(s[i])) ++i;
            out.push_back({Tok::Ident, s.substr(b, i - b)});
            continue;
        }
        bool matched = false;
        for (auto op : ops) {
            size_t l = std::char_traits<char>::length(op);
            if (s.compare(i, l, op) == 0) {
                out.push_back({Tok::Op, op});
                i += l;
                matched = true;
                break;
            }
        }
        if (!matched) {
            err = std::string("unexpected character '") + c + "'";
            return false;
        }
    }
    out.push_back({Tok::End, ""});
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// Tree

struct ExprNode {
    enum Kind { Num, Ident, Member, Unary, Binary, Ternary, Call, Defined } kind;
    double num = 0;
    std::string text; // identifier, member swizzle, operator or callee
    std::vector<std::shared_ptr<ExprNode>> kids;
};

namespace {

using NodeP = std::shared_ptr<ExprNode>;

NodeP mk(ExprNode::Kind k, const std::string &t = "") {
    auto n = std::make_shared<ExprNode>();
    n->kind = k;
    n->text = t;
    return n;
}

class Parser {
public:
    Parser(const std::vector<Token> &t) : m_t(t) {}
    NodeP parse(std::string &err) {
        NodeP r = ternary();
        if (!m_err.empty()) { err = m_err; return nullptr; }
        if (m_t[m_i].kind != Tok::End) { err = "trailing '" + m_t[m_i].text + "'"; return nullptr; }
        return r;
    }

private:
    const std::vector<Token> &m_t;
    size_t m_i = 0;
    std::string m_err;

    bool isOp(const char *op) const { return m_t[m_i].kind == Tok::Op && m_t[m_i].text == op; }
    bool accept(const char *op) {
        if (isOp(op)) { ++m_i; return true; }
        return false;
    }
    void fail(const std::string &e) {
        if (m_err.empty()) m_err = e;
    }

    NodeP ternary() {
        NodeP c = binary(0);
        if (accept("?")) {
            NodeP a = ternary();
            if (!accept(":")) { fail("expected ':'"); return c; }
            NodeP b = ternary();
            NodeP t = mk(ExprNode::Ternary);
            t->kids = {c, a, b};
            return t;
        }
        return c;
    }

    // Binary levels, lowest first, as in C.
    NodeP binary(int level) {
        static const std::vector<std::vector<const char *>> levels = {
            {"||"}, {"&&"}, {"|"}, {"^"}, {"&"}, {"==", "!="}, {"<", ">", "<=", ">="}, {"<<", ">>"},
            {"+", "-"}, {"*", "/", "%"},
        };
        if (level >= (int)levels.size())
            return unary();
        NodeP l = binary(level + 1);
        for (;;) {
            const char *hit = nullptr;
            for (auto op : levels[level])
                if (isOp(op)) { hit = op; break; }
            if (!hit || !m_err.empty())
                return l;
            ++m_i;
            NodeP r = binary(level + 1);
            NodeP b = mk(ExprNode::Binary, hit);
            b->kids = {l, r};
            l = b;
        }
    }

    NodeP unary() {
        for (const char *op : {"!", "-", "+", "~"}) {
            if (accept(op)) {
                NodeP u = mk(ExprNode::Unary, op);
                u->kids = {unary()};
                return u;
            }
        }
        return postfix();
    }

    NodeP postfix() {
        NodeP p = primary();
        while (m_err.empty() && accept(".")) {
            if (m_t[m_i].kind != Tok::Ident) { fail("expected a component after '.'"); break; }
            NodeP m = mk(ExprNode::Member, m_t[m_i].text);
            ++m_i;
            m->kids = {p};
            p = m;
        }
        return p;
    }

    NodeP primary() {
        const Token &t = m_t[m_i];
        if (t.kind == Tok::Num) {
            ++m_i;
            NodeP n = mk(ExprNode::Num);
            n->num = t.num;
            return n;
        }
        if (t.kind == Tok::Ident) {
            ++m_i;
            if (t.text == "defined") {
                bool paren = accept("(");
                if (m_t[m_i].kind != Tok::Ident) { fail("expected a name after defined"); return mk(ExprNode::Num); }
                NodeP d = mk(ExprNode::Defined, m_t[m_i].text);
                ++m_i;
                if (paren && !accept(")")) fail("expected ')' after defined(");
                return d;
            }
            if (accept("(")) {
                NodeP c = mk(ExprNode::Call, t.text);
                if (!accept(")")) {
                    do {
                        c->kids.push_back(ternary());
                    } while (m_err.empty() && accept(","));
                    if (!accept(")")) fail("expected ')' to close " + t.text + "(");
                }
                return c;
            }
            return mk(ExprNode::Ident, t.text);
        }
        if (accept("(")) {
            NodeP e = ternary();
            if (!accept(")")) fail("expected ')'");
            return e;
        }
        fail(t.kind == Tok::End ? "unexpected end of expression" : "unexpected '" + t.text + "'");
        ++m_i;
        return mk(ExprNode::Num);
    }
};

Value broadcast(const Value &a, int n) {
    if (a.n == n || a.n != 1) return a;
    Value r;
    r.n = n;
    for (int i = 0; i < n; ++i) r.v[i] = a.v[0];
    return r;
}

bool truth(const Value &a) { return a.v[0] != 0.0f; }

int swizzleIndex(char c) {
    switch (c) {
    case 'x': case 'r': case 's': return 0;
    case 'y': case 'g': case 't': return 1;
    case 'z': case 'b': case 'p': return 2;
    case 'w': case 'a': case 'q': return 3;
    }
    return -1;
}

Value evalNode(const ExprNode *n, const Expr::Lookup &lookup, const Expr::Call &call) {
    switch (n->kind) {
    case ExprNode::Num:
        return Value::scalar((float)n->num);
    case ExprNode::Ident: {
        Value v;
        if (lookup && lookup(n->text, v)) return v;
        return Value();
    }
    case ExprNode::Defined: {
        Value v;
        return Value::scalar(lookup && lookup("defined " + n->text, v) ? 1.0f : 0.0f);
    }
    case ExprNode::Member: {
        Value a = evalNode(n->kids[0].get(), lookup, call);
        Value r;
        r.n = (int)std::min<size_t>(4, n->text.size());
        for (int i = 0; i < r.n; ++i) {
            int k = swizzleIndex(n->text[i]);
            r.v[i] = (k >= 0 && k < a.n) ? a.v[k] : 0.0f;
        }
        return r;
    }
    case ExprNode::Unary: {
        Value a = evalNode(n->kids[0].get(), lookup, call);
        const std::string &op = n->text;
        if (op == "!") return Value::scalar(truth(a) ? 0.0f : 1.0f);
        if (op == "~") return Value::scalar((float)~(long long)a.v[0]);
        if (op == "-")
            for (int i = 0; i < a.n; ++i) a.v[i] = -a.v[i];
        return a;
    }
    case ExprNode::Ternary: {
        Value c = evalNode(n->kids[0].get(), lookup, call);
        return evalNode(n->kids[truth(c) ? 1 : 2].get(), lookup, call);
    }
    case ExprNode::Binary: {
        const std::string &op = n->text;
        if (op == "&&") {
            if (!truth(evalNode(n->kids[0].get(), lookup, call))) return Value::scalar(0);
            return Value::scalar(truth(evalNode(n->kids[1].get(), lookup, call)) ? 1.0f : 0.0f);
        }
        if (op == "||") {
            if (truth(evalNode(n->kids[0].get(), lookup, call))) return Value::scalar(1);
            return Value::scalar(truth(evalNode(n->kids[1].get(), lookup, call)) ? 1.0f : 0.0f);
        }
        Value a = evalNode(n->kids[0].get(), lookup, call);
        Value b = evalNode(n->kids[1].get(), lookup, call);
        float x = a.v[0], y = b.v[0];
        if (op == "==") return Value::scalar(x == y);
        if (op == "!=") return Value::scalar(x != y);
        if (op == "<") return Value::scalar(x < y);
        if (op == ">") return Value::scalar(x > y);
        if (op == "<=") return Value::scalar(x <= y);
        if (op == ">=") return Value::scalar(x >= y);
        if (op == "&") return Value::scalar((float)((long long)x & (long long)y));
        if (op == "|") return Value::scalar((float)((long long)x | (long long)y));
        if (op == "^") return Value::scalar((float)((long long)x ^ (long long)y));
        if (op == "<<") return Value::scalar((float)((long long)x << ((long long)y & 63)));
        if (op == ">>") return Value::scalar((float)((long long)x >> ((long long)y & 63)));
        int w = std::max(a.n, b.n);
        a = broadcast(a, w);
        b = broadcast(b, w);
        Value r;
        r.n = w;
        for (int i = 0; i < w; ++i) {
            float p = a.v[i], q = b.v[i];
            if (op == "+") r.v[i] = p + q;
            else if (op == "-") r.v[i] = p - q;
            else if (op == "*") r.v[i] = p * q;
            else if (op == "/") r.v[i] = q != 0.0f ? p / q : 0.0f;
            else if (op == "%") r.v[i] = q != 0.0f ? std::fmod(p, q) : 0.0f;
        }
        return r;
    }
    case ExprNode::Call: {
        std::vector<Value> args;
        args.reserve(n->kids.size());
        for (auto &k : n->kids)
            args.push_back(evalNode(k.get(), lookup, call));
        Value r;
        if (call && call(n->text, args, n, r)) return r;
        if (lookup) lookup("call " + n->text, r); // reported, reads zero
        return Value();
    }
    }
    return Value();
}

std::string trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

} // namespace

bool Expr::parse(const std::string &text, std::string &err) {
    std::vector<Token> toks;
    m_root.reset();
    if (!tokenize(text, toks, err)) return false;
    Parser p(toks);
    m_root = p.parse(err);
    return m_root != nullptr;
}

Value Expr::eval(const Lookup &lookup, const Call &call) const {
    if (!m_root) return Value();
    return evalNode(m_root.get(), lookup, call);
}

// ---------------------------------------------------------------------------
// Preprocessor conditionals

namespace {

// Expands macros in a token list. `defined X` is kept as is. A macro naming
// itself, directly or through others, stops expanding there, as in C.
void expandMacros(const std::vector<Token> &in, const std::map<std::string, std::string> &macros,
        std::set<std::string> &active, int depth, std::vector<Token> &out) {
    for (size_t i = 0; i < in.size(); ++i) {
        const Token &t = in[i];
        if (t.kind == Tok::End) continue;
        if (t.kind == Tok::Ident && t.text == "defined") {
            out.push_back(t);
            // copy the operand untouched: "X" or "( X )"
            size_t j = i + 1;
            if (j < in.size() && in[j].kind == Tok::Op && in[j].text == "(") {
                for (; j < in.size(); ++j) {
                    out.push_back(in[j]);
                    if (in[j].kind == Tok::Op && in[j].text == ")") break;
                }
            } else if (j < in.size()) {
                out.push_back(in[j]);
            }
            i = j;
            continue;
        }
        if (t.kind == Tok::Ident && depth < 32 && !active.count(t.text)) {
            auto m = macros.find(t.text);
            if (m != macros.end()) {
                std::vector<Token> sub;
                std::string err;
                if (tokenize(m->second, sub, err)) {
                    active.insert(t.text);
                    expandMacros(sub, macros, active, depth + 1, out);
                    active.erase(t.text);
                    continue;
                }
            }
        }
        out.push_back(t);
    }
}

} // namespace

bool conditionHolds(const std::string &expr, const std::map<std::string, std::string> &macros, std::string &err) {
    std::vector<Token> raw, expanded;
    if (!tokenize(expr, raw, err)) return false;
    std::set<std::string> active;
    expandMacros(raw, macros, active, 0, expanded);
    expanded.push_back({Tok::End, ""});
    Parser p(expanded);
    NodeP root = p.parse(err);
    if (!root) return false;
    Expr::Lookup lookup = [&](const std::string &name, Value &out) {
        if (name.rfind("defined ", 0) == 0) return macros.count(name.substr(8)) > 0;
        out = Value(); // an identifier left after expansion is 0, as in C
        return true;
    };
    return truth(evalNode(root.get(), lookup, nullptr));
}

std::string runConditionals(const std::string &text, std::map<std::string, std::string> &macros,
        std::vector<std::string> *errors, bool keep_defines) {
    struct Frame {
        bool parent_live, taken, live;
    };
    std::vector<Frame> stack;
    auto live = [&]() { return stack.empty() || stack.back().live; };
    std::string out;
    std::stringstream ss(text);
    std::string line;
    int lineno = 0;
    // Whether a /* comment is open at the start of the line. A directive
    // inside a block comment is commented out, which packs do to switch a
    // block off.
    bool in_comment = false;
    auto advanceComments = [&](const std::string &l) {
        for (size_t i = 0; i + 1 < l.size(); ++i) {
            if (in_comment) {
                if (l[i] == '*' && l[i + 1] == '/') { in_comment = false; ++i; }
            } else if (l[i] == '/' && l[i + 1] == '/') {
                return;
            } else if (l[i] == '/' && l[i + 1] == '*') {
                in_comment = true;
                ++i;
            }
        }
    };
    while (std::getline(ss, line)) {
        ++lineno;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::string t = trim(line);
        bool commented = in_comment;
        advanceComments(line);
        if (t.empty() || t[0] != '#' || commented) {
            if (live()) out += line;
            out += '\n';
            continue;
        }
        size_t k = 1;
        while (k < t.size() && std::isspace((unsigned char)t[k])) ++k;
        size_t ws = k;
        while (k < t.size() && std::isalpha((unsigned char)t[k])) ++k;
        std::string word = t.substr(ws, k - ws);
        std::string rest = trim(t.substr(k));
        // a trailing // comment is not part of a directive
        size_t cm = rest.find("//");
        if (cm != std::string::npos) rest = trim(rest.substr(0, cm));
        auto note = [&](const std::string &e) {
            if (errors) errors->push_back("line " + std::to_string(lineno) + ": " + e);
        };
        if (word == "if" || word == "ifdef" || word == "ifndef") {
            bool parent = live();
            bool cond = false;
            if (parent) {
                if (word == "if") {
                    std::string e;
                    cond = conditionHolds(rest, macros, e);
                    if (!e.empty()) note("#if " + rest + ": " + e);
                } else {
                    std::string name = rest.substr(0, rest.find_first_of(" \t"));
                    cond = macros.count(name) > 0;
                    if (word == "ifndef") cond = !cond;
                }
            }
            stack.push_back({parent, parent && cond, parent && cond});
        } else if (word == "elif") {
            if (stack.empty()) { note("#elif without #if"); out += '\n'; continue; }
            Frame &f = stack.back();
            if (f.parent_live && !f.taken) {
                std::string e;
                bool cond = conditionHolds(rest, macros, e);
                if (!e.empty()) note("#elif " + rest + ": " + e);
                f.live = cond;
                f.taken = cond;
            } else {
                f.live = false;
            }
        } else if (word == "else") {
            if (stack.empty()) { note("#else without #if"); out += '\n'; continue; }
            Frame &f = stack.back();
            f.live = f.parent_live && !f.taken;
            f.taken = true;
        } else if (word == "endif") {
            if (stack.empty()) note("#endif without #if");
            else stack.pop_back();
        } else if (word == "define") {
            if (live()) {
                size_t e = 0;
                while (e < rest.size() && isIdentChar(rest[e])) ++e;
                std::string name = rest.substr(0, e);
                // A function like macro's body is not expanded in a condition.
                if (!name.empty() && (e >= rest.size() || rest[e] != '('))
                    macros[name] = trim(rest.substr(e));
                // A function like macro is still a name #ifdef can test.
                else if (!name.empty())
                    macros[name] = "";
                if (keep_defines) out += line;
            }
        } else if (word == "undef") {
            if (live()) {
                macros.erase(rest.substr(0, rest.find_first_of(" \t")));
                if (keep_defines) out += line;
            }
        } else {
            // not a directive: a comment line, kept for the caller to skip
            if (live()) out += line;
        }
        out += '\n';
    }
    if (!stack.empty() && errors)
        errors->push_back("unterminated #if at end of file");
    return out;
}

// ---------------------------------------------------------------------------
// Custom uniforms

bool CustomUniforms::add(const std::string &type, const std::string &name, bool is_uniform,
        const std::string &text, std::string &err) {
    static const std::set<std::string> types = {"float", "int", "bool", "vec2", "vec3", "vec4"};
    if (!types.count(type)) {
        err = "unsupported custom uniform type " + type;
        return false;
    }
    Def d;
    d.type = type;
    d.name = name;
    d.is_uniform = is_uniform;
    d.source = text;
    if (!d.expr.parse(text, err))
        return false;
    for (auto &e : m_defs) {
        if (e.name == name) {
            e = std::move(d);
            return true;
        }
    }
    m_defs.push_back(std::move(d));
    return true;
}

namespace {

int typeWidth(const std::string &type) {
    if (type == "vec2") return 2;
    if (type == "vec3") return 3;
    if (type == "vec4") return 4;
    return 1;
}

// Biome, category and precipitation names, which OptiFine and Iris define as
// constants. Goanna knows no biome; `biome` reads as plains, so a pack's
// `in(biome, BIOME_SNOWY_PLAINS, ...)` is false rather than true for every
// name that would otherwise share the value 0.
bool namedConstant(const std::string &name, Value &out) {
    static std::map<std::string, int> ids;
    auto numbered = [&](const char *prefix, const char *first) -> bool {
        if (name.rfind(prefix, 0) != 0) return false;
        auto it = ids.find(name);
        if (it == ids.end()) {
            int next = name == first ? 1 : 2 + (int)ids.size();
            it = ids.emplace(name, next).first;
        }
        out = Value::scalar((float)it->second);
        return true;
    };
    if (name == "pi") { out = Value::scalar(3.14159265358979f); return true; }
    if (name == "true") { out = Value::scalar(1); return true; }
    if (name == "false") { out = Value::scalar(0); return true; }
    if (name == "PPT_NONE") { out = Value::scalar(0); return true; }
    if (name == "PPT_RAIN") { out = Value::scalar(1); return true; }
    if (name == "PPT_SNOW") { out = Value::scalar(2); return true; }
    // Biome and player state OptiFine offers to expressions and the
    // protocol does not carry: precipitation reads as rain, since the
    // particle side says when it falls, and the player flags read false.
    if (name == "biome_precipitation") { out = Value::scalar(1); return true; }
    static const char *flags[] = {"is_alive", "is_burning", "is_child", "is_glowing", "is_hurt", "is_in_lava",
            "is_in_water", "is_invisible", "is_on_ground", "is_ridden", "is_riding", "is_sneaking",
            "is_sprinting", "is_wet"};
    for (auto f : flags)
        if (name == f) { out = Value::scalar(std::string(f) == "is_alive" ? 1.0f : 0.0f); return true; }
    return numbered("BIOME_", "BIOME_PLAINS") || numbered("CAT_", "CAT_PLAINS");
}

bool builtinCall(const std::string &f, const std::vector<Value> &a, Value &r) {
    auto x = [&](size_t i) { return i < a.size() ? a[i].v[0] : 0.0f; };
    auto one = [&](float v) { r = Value::scalar(v); return true; };
    size_t n = a.size();
    if (f == "if") {
        // if(c1, v1, c2, v2, ..., else)
        for (size_t i = 0; i + 1 < n; i += 2)
            if (truth(a[i])) { r = a[i + 1]; return true; }
        r = (n % 2 == 1) ? a[n - 1] : Value();
        return true;
    }
    if (f == "vec2" || f == "vec3" || f == "vec4") {
        int w = f[3] - '0';
        r = Value();
        r.n = w;
        int k = 0;
        for (auto &v : a)
            for (int i = 0; i < v.n && k < w; ++i) r.v[k++] = v.v[i];
        if (n == 1 && a[0].n == 1)
            for (int i = 1; i < w; ++i) r.v[i] = a[0].v[0];
        return true;
    }
    if (f == "abs") return one(std::fabs(x(0)));
    if (f == "frac") return one(x(0) - std::floor(x(0)));
    if (f == "floor") return one(std::floor(x(0)));
    if (f == "ceil") return one(std::ceil(x(0)));
    if (f == "round") return one(std::round(x(0)));
    if (f == "signum" || f == "sign") return one((float)((x(0) > 0) - (x(0) < 0)));
    if (f == "sqrt") return one(std::sqrt(std::max(0.0f, x(0))));
    if (f == "exp") return one(std::exp(x(0)));
    if (f == "exp2") return one(std::exp2(x(0)));
    if (f == "exp10") return one(std::pow(10.0f, x(0)));
    if (f == "log") return one(x(0) > 0 ? std::log(x(0)) : 0.0f);
    if (f == "log2") return one(x(0) > 0 ? std::log2(x(0)) : 0.0f);
    if (f == "log10") return one(x(0) > 0 ? std::log10(x(0)) : 0.0f);
    if (f == "sin") return one(std::sin(x(0)));
    if (f == "cos") return one(std::cos(x(0)));
    if (f == "tan") return one(std::tan(x(0)));
    if (f == "asin") return one(std::asin(std::clamp(x(0), -1.0f, 1.0f)));
    if (f == "acos") return one(std::acos(std::clamp(x(0), -1.0f, 1.0f)));
    if (f == "atan") return one(n > 1 ? std::atan2(x(0), x(1)) : std::atan(x(0)));
    if (f == "atan2") return one(std::atan2(x(0), x(1)));
    if (f == "torad") return one(x(0) * 0.0174532925f);
    if (f == "todeg") return one(x(0) * 57.2957795f);
    if (f == "pow") return one(std::pow(x(0), x(1)));
    if (f == "fmod") return one(x(1) != 0 ? std::fmod(x(0), x(1)) : 0.0f);
    if (f == "hypot") return one(std::hypot(x(0), x(1)));
    if (f == "clamp") return one(std::clamp(x(0), std::min(x(1), x(2)), std::max(x(1), x(2))));
    if (f == "mix") return one(x(0) + (x(1) - x(0)) * x(2));
    if (f == "smoothstep") {
        float t = x(1) != x(0) ? std::clamp((x(2) - x(0)) / (x(1) - x(0)), 0.0f, 1.0f) : 0.0f;
        return one(t * t * (3 - 2 * t));
    }
    if (f == "min" || f == "max") {
        if (n == 0) return one(0);
        float v = x(0);
        for (size_t i = 1; i < n; ++i) v = f == "min" ? std::min(v, x(i)) : std::max(v, x(i));
        return one(v);
    }
    if (f == "between") return one(x(0) >= x(1) && x(0) <= x(2));
    if (f == "equals") return one(std::fabs(x(0) - x(1)) <= (n > 2 ? x(2) : 0.0f));
    if (f == "in") {
        for (size_t i = 1; i < n; ++i)
            if (x(0) == x(i)) return one(1);
        return one(0);
    }
    if (f == "random") return one((float)std::rand() / (float)RAND_MAX);
    return false;
}

} // namespace

void CustomUniforms::evaluate(const Expr::Lookup &builtin, float dt) {
    std::set<std::string> missing(m_unresolved.begin(), m_unresolved.end());
    Expr::Lookup lookup = [&](const std::string &name, Value &out) {
        auto it = m_values.find(name);
        if (it != m_values.end()) { out = it->second; return true; }
        if (builtin && builtin(name, out)) return true;
        if (namedConstant(name, out)) return true;
        missing.insert(name);
        out = Value();
        return true;
    };
    Expr::Call call = [&](const std::string &f, const std::vector<Value> &a, const ExprNode *node, Value &r) {
        if (f == "smooth") {
            // smooth([id,] value [, fade up [, fade down]]), the times in
            // seconds to get most of the way there; one second by default.
            size_t vi = a.size() >= 4 ? 1 : 0;
            std::string key = a.size() >= 4 ? "id " + std::to_string((int)a[0].v[0])
                                            : "node " + std::to_string((uintptr_t)node);
            float target = vi < a.size() ? a[vi].v[0] : 0.0f;
            float up = vi + 1 < a.size() ? a[vi + 1].v[0] : 1.0f;
            float down = vi + 2 < a.size() ? a[vi + 2].v[0] : up;
            auto it = m_smooth.find(key);
            if (it == m_smooth.end() || m_frame == 0) {
                m_smooth[key] = target;
            } else {
                float t = target > it->second ? up : down;
                float k = t > 0 ? 1.0f - std::pow(0.01f, dt / t) : 1.0f;
                it->second += (target - it->second) * std::clamp(k, 0.0f, 1.0f);
            }
            r = Value::scalar(m_smooth[key]);
            return true;
        }
        if (builtinCall(f, a, r)) return true;
        missing.insert(f + "()");
        return false;
    };
    for (auto &d : m_defs) {
        Value v = d.expr.eval(lookup, call);
        int w = typeWidth(d.type);
        v = broadcast(v, w);
        v.n = w;
        if (d.type == "int")
            v.v[0] = std::trunc(v.v[0]);
        else if (d.type == "bool")
            v.v[0] = truth(v) ? 1.0f : 0.0f;
        m_values[d.name] = v;
    }
    m_unresolved.assign(missing.begin(), missing.end());
    ++m_frame;
}

bool CustomUniforms::value(const std::string &name, Value &out) const {
    auto it = m_values.find(name);
    if (it == m_values.end()) return false;
    out = it->second;
    return true;
}

} // namespace iris
} // namespace goanna
