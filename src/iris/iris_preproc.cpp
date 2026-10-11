// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The shader pack preprocessor. See iris_preproc.h.

#include "iris_preproc.h"

#include "iris_glsl.h"

#include <cctype>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <set>
#include <sstream>

namespace goanna {
namespace iris {

namespace {

bool identStart(char c) { return std::isalpha((unsigned char)c) || c == '_'; }
bool identChar(char c) { return std::isalnum((unsigned char)c) || c == '_'; }

std::string trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

// Length of the number token starting at i: digits, letters (suffixes, hex,
// exponent marker), dots, and a sign straight after an exponent marker.
size_t numberLength(const std::string &s, size_t i) {
    size_t j = i;
    bool hex = s.compare(i, 2, "0x") == 0 || s.compare(i, 2, "0X") == 0;
    while (j < s.size()) {
        char c = s[j];
        if (identChar(c) || c == '.') {
            ++j;
        } else if ((c == '+' || c == '-') && !hex && j > i && (s[j - 1] == 'e' || s[j - 1] == 'E')) {
            ++j;
        } else {
            break;
        }
    }
    return j - i;
}

bool startsNumber(const std::string &s, size_t i) {
    return std::isdigit((unsigned char)s[i]) ||
            (s[i] == '.' && i + 1 < s.size() && std::isdigit((unsigned char)s[i + 1]));
}

// Splits a macro argument list starting just after '(' at `i`. Returns the
// index after the closing ')', or npos if it does not close.
size_t collectArgs(const std::string &s, size_t i, std::vector<std::string> &args) {
    int depth = 0;
    std::string cur;
    for (; i < s.size(); ++i) {
        char c = s[i];
        if (c == '(') {
            ++depth;
        } else if (c == ')') {
            if (depth == 0) {
                args.push_back(trim(cur));
                return i + 1;
            }
            --depth;
        } else if (c == ',' && depth == 0) {
            args.push_back(trim(cur));
            cur.clear();
            continue;
        }
        cur += c;
    }
    return std::string::npos;
}

std::string expand(const std::string &s, const MacroTable &macros, std::set<std::string> &disabled, int depth);

std::string substitute(const Macro &m, const std::vector<std::string> &raw,
        const std::vector<std::string> &expanded) {
    std::string out;
    const std::string &b = m.body;
    size_t i = 0;
    while (i < b.size()) {
        if (identStart(b[i])) {
            size_t j = i;
            while (j < b.size() && identChar(b[j])) ++j;
            std::string w = b.substr(i, j - i);
            bool done = false;
            for (size_t k = 0; k < m.params.size(); ++k) {
                if (w == m.params[k]) {
                    // An operand of ## is pasted unexpanded, as in C.
                    size_t a = j;
                    while (a < b.size() && b[a] == ' ') ++a;
                    bool paste_after = b.compare(a, 2, "##") == 0;
                    size_t p = out.find_last_not_of(' ');
                    bool paste_before = p != std::string::npos && p >= 1 && out.compare(p - 1, 2, "##") == 0;
                    out += (paste_after || paste_before) ? (k < raw.size() ? raw[k] : "")
                                                         : (k < expanded.size() ? expanded[k] : "");
                    done = true;
                    break;
                }
            }
            if (!done) out += w;
            i = j;
        } else if (startsNumber(b, i)) {
            size_t n = numberLength(b, i);
            out += b.substr(i, n);
            i += n;
        } else {
            out += b[i++];
        }
    }
    // Token pasting: drop ## and the spaces round it.
    std::string pasted;
    for (size_t k = 0; k < out.size(); ++k) {
        if (out.compare(k, 2, "##") == 0) {
            while (!pasted.empty() && pasted.back() == ' ') pasted.pop_back();
            k += 1;
            while (k + 1 < out.size() && out[k + 1] == ' ') ++k;
            continue;
        }
        pasted += out[k];
    }
    return pasted;
}

std::string expand(const std::string &s, const MacroTable &macros, std::set<std::string> &disabled, int depth) {
    if (depth > 64)
        return s;
    std::string out;
    size_t i = 0;
    while (i < s.size()) {
        if (startsNumber(s, i)) {
            size_t n = numberLength(s, i);
            out += s.substr(i, n);
            i += n;
            continue;
        }
        if (!identStart(s[i])) {
            out += s[i++];
            continue;
        }
        size_t j = i;
        while (j < s.size() && identChar(s[j])) ++j;
        std::string w = s.substr(i, j - i);
        auto it = macros.find(w);
        if (it == macros.end() || disabled.count(w)) {
            out += w;
            i = j;
            continue;
        }
        const Macro &m = it->second;
        if (!m.function) {
            disabled.insert(w);
            out += expand(m.body, macros, disabled, depth + 1);
            disabled.erase(w);
            i = j;
            continue;
        }
        size_t k = j;
        while (k < s.size() && std::isspace((unsigned char)s[k])) ++k;
        if (k >= s.size() || s[k] != '(') {
            out += w; // a function-like macro's name alone is not a call
            i = j;
            continue;
        }
        std::vector<std::string> raw;
        size_t end = collectArgs(s, k + 1, raw);
        if (end == std::string::npos) {
            out += w;
            i = j;
            continue;
        }
        if (raw.size() == 1 && raw[0].empty() && m.params.empty())
            raw.clear();
        std::vector<std::string> expanded;
        for (auto &a : raw)
            expanded.push_back(expand(a, macros, disabled, depth + 1));
        disabled.insert(w);
        out += expand(substitute(m, raw, expanded), macros, disabled, depth + 1);
        disabled.erase(w);
        i = end;
    }
    return out;
}

// ---- #if expression evaluation, over doubles

struct Eval {
    const std::string &s;
    size_t i = 0;
    std::string err;
    explicit Eval(const std::string &src) : s(src) {}

    void ws() {
        while (i < s.size() && std::isspace((unsigned char)s[i])) ++i;
    }
    bool peek(const char *op) {
        ws();
        return s.compare(i, std::strlen(op), op) == 0;
    }
    bool take(const char *op) {
        if (!peek(op)) return false;
        i += std::strlen(op);
        return true;
    }
    double primary() {
        ws();
        if (i >= s.size()) {
            err = "unexpected end of expression";
            return 0;
        }
        if (take("(")) {
            double v = ternary();
            if (!take(")")) err = "missing )";
            return v;
        }
        if (take("!")) return primaryUnary() == 0 ? 1 : 0;
        if (take("~")) return (double)(~(long long)primaryUnary());
        if (take("-")) return -primaryUnary();
        if (take("+")) return primaryUnary();
        if (startsNumber(s, i)) {
            size_t n = numberLength(s, i);
            std::string t = s.substr(i, n);
            i += n;
            while (!t.empty() && (t.back() == 'f' || t.back() == 'F' || t.back() == 'u' || t.back() == 'U' ||
                                         t.back() == 'l' || t.back() == 'L') &&
                    !(t.size() > 2 && (t[1] == 'x' || t[1] == 'X')))
                t.pop_back();
            if (t.size() > 2 && (t[1] == 'x' || t[1] == 'X'))
                return (double)std::strtoll(t.c_str(), nullptr, 16);
            return std::strtod(t.c_str(), nullptr);
        }
        if (identStart(s[i])) {
            // An identifier left after expansion is not a macro: it reads 0.
            while (i < s.size() && identChar(s[i])) ++i;
            return 0;
        }
        err = std::string("unexpected '") + s[i] + "'";
        ++i;
        return 0;
    }
    double primaryUnary() { return primary(); }
    double binary(int level) {
        // Levels, loosest first: || && | ^ & equality relational shift additive multiplicative
        if (level > 9) return primary();
        double l = binary(level + 1);
        for (;;) {
            ws();
            bool matched = false;
            auto op = [&](const char *t, const char *not_followed = nullptr) {
                if (!peek(t)) return false;
                if (not_followed && s.compare(i + std::strlen(t), std::strlen(not_followed), not_followed) == 0)
                    return false;
                i += std::strlen(t);
                matched = true;
                return true;
            };
            double r;
            switch (level) {
            case 0:
                if (op("||")) { r = binary(level + 1); l = (l != 0 || r != 0) ? 1 : 0; }
                break;
            case 1:
                if (op("&&")) { r = binary(level + 1); l = (l != 0 && r != 0) ? 1 : 0; }
                break;
            case 2:
                if (!peek("||") && op("|")) { r = binary(level + 1); l = (double)((long long)l | (long long)r); }
                break;
            case 3:
                if (op("^")) { r = binary(level + 1); l = (double)((long long)l ^ (long long)r); }
                break;
            case 4:
                if (!peek("&&") && op("&")) { r = binary(level + 1); l = (double)((long long)l & (long long)r); }
                break;
            case 5:
                if (op("==")) { r = binary(level + 1); l = l == r ? 1 : 0; }
                else if (op("!=")) { r = binary(level + 1); l = l != r ? 1 : 0; }
                break;
            case 6:
                if (op("<=")) { r = binary(level + 1); l = l <= r ? 1 : 0; }
                else if (op(">=")) { r = binary(level + 1); l = l >= r ? 1 : 0; }
                else if (op("<", "<")) { r = binary(level + 1); l = l < r ? 1 : 0; }
                else if (op(">", ">")) { r = binary(level + 1); l = l > r ? 1 : 0; }
                break;
            case 7:
                if (op("<<")) { r = binary(level + 1); l = (double)((long long)l << (long long)r); }
                else if (op(">>")) { r = binary(level + 1); l = (double)((long long)l >> (long long)r); }
                break;
            case 8:
                if (op("+")) { r = binary(level + 1); l = l + r; }
                else if (op("-")) { r = binary(level + 1); l = l - r; }
                break;
            case 9:
                if (op("*")) { r = binary(level + 1); l = l * r; }
                else if (op("/")) { r = binary(level + 1); l = r == 0 ? 0 : l / r; }
                else if (op("%")) { r = binary(level + 1); l = r == 0 ? 0 : std::fmod(l, r); }
                break;
            }
            if (!matched) return l;
        }
    }
    double ternary() {
        double c = binary(0);
        if (take("?")) {
            double a = ternary();
            if (!take(":")) err = "missing : in ?:";
            double b = ternary();
            return c != 0 ? a : b;
        }
        return c;
    }
};

// defined(X) and defined X become 1 or 0, before anything else expands.
std::string resolveDefined(const std::string &s, const MacroTable &macros) {
    std::string out;
    size_t i = 0;
    while (i < s.size()) {
        if (startsNumber(s, i)) {
            size_t n = numberLength(s, i);
            out += s.substr(i, n);
            i += n;
            continue;
        }
        if (!identStart(s[i])) {
            out += s[i++];
            continue;
        }
        size_t j = i;
        while (j < s.size() && identChar(s[j])) ++j;
        std::string w = s.substr(i, j - i);
        if (w != "defined") {
            out += w;
            i = j;
            continue;
        }
        size_t k = j;
        while (k < s.size() && std::isspace((unsigned char)s[k])) ++k;
        bool paren = k < s.size() && s[k] == '(';
        if (paren) ++k;
        while (k < s.size() && std::isspace((unsigned char)s[k])) ++k;
        size_t a = k;
        while (k < s.size() && identChar(s[k])) ++k;
        std::string name = s.substr(a, k - a);
        if (paren) {
            while (k < s.size() && s[k] != ')') ++k;
            if (k < s.size()) ++k;
        }
        out += macros.count(name) ? " 1 " : " 0 ";
        i = k;
    }
    return out;
}

} // namespace

void defineMacro(MacroTable &table, const std::string &name, const std::string &value) {
    Macro m;
    m.body = value;
    table[name] = m;
}

bool evalCondition(const std::string &expr, const MacroTable &macros, double &value, std::string &err) {
    std::set<std::string> disabled;
    std::string e = expand(resolveDefined(expr, macros), macros, disabled, 0);
    Eval ev(e);
    value = ev.ternary();
    ev.ws();
    if (ev.err.empty() && ev.i < e.size())
        ev.err = "trailing text '" + e.substr(ev.i) + "'";
    err = ev.err;
    return err.empty();
}

bool preprocess(const std::string &src, MacroTable &macros, std::string &out, std::vector<std::string> &errors) {
    std::string text = stripComments(src);
    // Logical lines, with continuations joined and blank lines put back after.
    std::vector<std::string> lines;
    {
        std::stringstream ss(text);
        std::string line, pending;
        int extra = 0;
        while (std::getline(ss, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty() && line.back() == '\\') {
                pending += line.substr(0, line.size() - 1) + " ";
                ++extra;
                continue;
            }
            lines.push_back(pending + line);
            pending.clear();
            for (; extra > 0; --extra) lines.push_back("");
        }
        if (!pending.empty()) lines.push_back(pending);
    }

    struct Cond {
        bool parent, active, taken;
    };
    std::vector<Cond> stack;
    auto active = [&]() { return stack.empty() || stack.back().active; };
    std::ostringstream o;
    int lineno = 0;
    for (auto &raw : lines) {
        ++lineno;
        std::string t = trim(raw);
        if (t.empty() || t[0] != '#') {
            if (active() && !t.empty()) {
                std::set<std::string> disabled;
                o << expand(raw, macros, disabled, 0);
            }
            o << "\n";
            continue;
        }
        std::string d = trim(t.substr(1));
        size_t k = 0;
        while (k < d.size() && identChar(d[k])) ++k;
        std::string dir = d.substr(0, k);
        std::string rest = trim(d.substr(k));
        auto err = [&](const std::string &m) { errors.push_back("line " + std::to_string(lineno) + ": " + m); };
        auto evalHere = [&](const std::string &e) {
            double v = 0;
            std::string e2;
            if (!evalCondition(e, macros, v, e2)) err("#" + dir + " " + e + ": " + e2);
            return v != 0;
        };
        if (dir == "ifdef" || dir == "ifndef") {
            size_t n = 0;
            while (n < rest.size() && identChar(rest[n])) ++n;
            bool def = macros.count(rest.substr(0, n)) > 0;
            bool cond = dir == "ifdef" ? def : !def;
            bool parent = active();
            stack.push_back({parent, parent && cond, cond});
        } else if (dir == "if") {
            bool parent = active();
            bool cond = parent ? evalHere(rest) : false;
            stack.push_back({parent, parent && cond, cond});
        } else if (dir == "elif") {
            if (stack.empty()) {
                err("#elif without #if");
            } else {
                Cond &c = stack.back();
                if (c.taken || !c.parent) {
                    c.active = false;
                } else {
                    bool cond = evalHere(rest);
                    c.active = cond;
                    c.taken = cond;
                }
            }
        } else if (dir == "else") {
            if (stack.empty()) {
                err("#else without #if");
            } else {
                Cond &c = stack.back();
                c.active = c.parent && !c.taken;
                c.taken = true;
            }
        } else if (dir == "endif") {
            if (stack.empty())
                err("#endif without #if");
            else
                stack.pop_back();
        } else if (!active()) {
            // anything else inside a skipped group is ignored
        } else if (dir == "define") {
            size_t n = 0;
            while (n < rest.size() && identChar(rest[n])) ++n;
            std::string name = rest.substr(0, n);
            if (name.empty()) {
                err("#define without a name");
            } else {
                Macro m;
                size_t b = n;
                if (b < rest.size() && rest[b] == '(') {
                    m.function = true;
                    size_t close = rest.find(')', b);
                    if (close == std::string::npos) {
                        err("unclosed macro parameter list");
                        close = rest.size();
                    }
                    std::stringstream ps(rest.substr(b + 1, close - b - 1));
                    std::string p;
                    while (std::getline(ps, p, ','))
                        if (!trim(p).empty()) m.params.push_back(trim(p));
                    b = close + 1;
                }
                m.body = b < rest.size() ? trim(rest.substr(b)) : "";
                macros[name] = m;
            }
        } else if (dir == "undef") {
            size_t n = 0;
            while (n < rest.size() && identChar(rest[n])) ++n;
            macros.erase(rest.substr(0, n));
        } else if (dir == "error") {
            err("#error " + rest);
        } else if (dir == "include") {
            err("#include left unresolved: " + rest);
        }
        // #version, #extension, #pragma and #line are dropped
        o << "\n";
    }
    if (!stack.empty())
        errors.push_back("unterminated #if at end of source");
    out = o.str();
    return errors.empty();
}

} // namespace iris
} // namespace goanna
