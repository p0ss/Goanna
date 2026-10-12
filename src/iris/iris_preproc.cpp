// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The shader pack preprocessor. See iris_preproc.h.

#include "iris_preproc.h"

#include "iris_glsl.h"

#include <algorithm>
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

// Whether a line calls a function-like macro whose argument list it does
// not close, so the call goes on over the next lines (Photon writes
// clamp01(, a line of arguments, then the closing parenthesis, that way).
// Comments are already stripped.
bool openMacroCall(const std::string &s, const MacroTable &macros) {
    for (size_t i = 0; i < s.size();) {
        if (!identStart(s[i])) {
            i += startsNumber(s, i) ? std::max<size_t>(numberLength(s, i), 1) : 1;
            continue;
        }
        size_t j = i;
        while (j < s.size() && identChar(s[j])) ++j;
        auto m = macros.find(s.substr(i, j - i));
        i = j;
        if (m == macros.end() || !m->second.function) continue;
        while (j < s.size() && std::isspace((unsigned char)s[j])) ++j;
        if (j >= s.size() || s[j] != '(') continue;
        int depth = 0;
        for (; j < s.size(); ++j) {
            if (s[j] == '(') ++depth;
            else if (s[j] == ')' && --depth == 0) break;
        }
        if (depth > 0) return true;
        i = j;
    }
    return false;
}

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


namespace {

// The directive engine both entry points share. In full mode (the gbuffers
// translator's) comments are removed first, every # line is a directive,
// and live text has its macros expanded. In conditional mode (the pack
// loader's, for shaders.properties and for program sources glslang will
// preprocess again) the text is left as written: comments stay, a directive
// inside a block comment is commented out and ignored, a # line that is not
// a directive is text (properties files use # for comments), and #define
// and #undef lines may be kept.
void runDirectives(const std::string &src, MacroTable &macros, bool full, bool keep_defines, std::string &out,
        std::vector<std::string> &errors) {
    std::string text = full ? stripComments(src) : src;
    // Logical lines. In full mode continuations are joined and blank lines
    // put back after; conditional mode leaves lines as they are.
    std::vector<std::string> lines;
    {
        std::stringstream ss(text);
        std::string line, pending;
        int extra = 0;
        while (std::getline(ss, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (full && !line.empty() && line.back() == '\\') {
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
    // Conditional mode only: whether a /* comment is open at a line's start.
    bool in_comment = false;
    auto advanceComments = [&](const std::string &l) {
        for (size_t i = 0; i + 1 < l.size(); ++i) {
            if (in_comment) {
                if (l[i] == '*' && l[i + 1] == '/') {
                    in_comment = false;
                    ++i;
                }
            } else if (l[i] == '/' && l[i + 1] == '/') {
                return;
            } else if (l[i] == '/' && l[i + 1] == '*') {
                in_comment = true;
                ++i;
            }
        }
    };
    std::ostringstream o;
    int lineno = 0;
    for (size_t li = 0; li < lines.size(); ++li) {
        std::string &raw = lines[li];
        ++lineno;
        std::string t = trim(raw);
        bool commented = false;
        if (!full) {
            commented = in_comment;
            advanceComments(raw);
        }
        if (t.empty() || t[0] != '#' || commented) {
            if (active() && (!t.empty() || !full)) {
                if (full) {
                    // A macro call left open takes the following plain lines
                    // with it, and each one taken leaves a blank line so the
                    // line numbers still match the pack's.
                    std::string joined = raw;
                    int taken = 0;
                    while (openMacroCall(joined, macros) && li + 1 < lines.size() &&
                            trim(lines[li + 1]).compare(0, 1, "#") != 0 && taken < 64) {
                        joined += " " + lines[++li];
                        ++taken;
                    }
                    std::set<std::string> disabled;
                    o << expand(joined, macros, disabled, 0);
                    for (; taken > 0; --taken) {
                        o << "\n";
                        ++lineno;
                    }
                } else {
                    o << raw;
                }
            }
            o << "\n";
            continue;
        }
        // A directive continued with a backslash (Photon's long #if lines):
        // full mode joined the lines above; conditional mode joins them
        // here, so the condition is read whole and the continuation lines
        // are not left behind as text. Each line taken is put back as a
        // blank one, or as itself in a kept #define, so line numbers hold.
        std::vector<std::string> cont;
        if (!full) {
            while (!t.empty() && t.back() == '\\' && li + 1 < lines.size()) {
                cont.push_back(lines[++li]);
                t = trim(t.substr(0, t.size() - 1) + " " + cont.back());
            }
        }
        std::string d = trim(t.substr(1));
        size_t k = 0;
        while (k < d.size() && identChar(d[k])) ++k;
        std::string dir = d.substr(0, k);
        std::string rest = trim(d.substr(k));
        if (!full) {
            // a trailing // comment is not part of a directive
            size_t cm = rest.find("//");
            if (cm != std::string::npos) rest = trim(rest.substr(0, cm));
        }
        auto err = [&](const std::string &m) { errors.push_back("line " + std::to_string(lineno) + ": " + m); };
        auto evalHere = [&](const std::string &e) {
            double v = 0;
            std::string e2;
            if (!evalCondition(e, macros, v, e2)) err("#" + dir + " " + e + ": " + e2);
            return v != 0;
        };
        bool keep = false;
        if (dir == "ifdef" || dir == "ifndef") {
            size_t n = 0;
            while (n < rest.size() && identChar(rest[n])) ++n;
            bool def = macros.count(rest.substr(0, n)) > 0;
            bool cond = dir == "ifdef" ? def : !def;
            bool parent = active();
            stack.push_back({parent, parent && cond, parent && cond});
        } else if (dir == "if") {
            bool parent = active();
            bool cond = parent ? evalHere(rest) : false;
            stack.push_back({parent, parent && cond, parent && cond});
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
            keep = keep_defines;
        } else if (dir == "undef") {
            size_t n = 0;
            while (n < rest.size() && identChar(rest[n])) ++n;
            macros.erase(rest.substr(0, n));
            keep = keep_defines;
        } else if (!full) {
            // not a directive: a comment line, kept for the caller to skip
            keep = true;
        } else if (dir == "error") {
            err("#error " + rest);
        } else if (dir == "include") {
            err("#include left unresolved: " + rest);
        }
        // in full mode #version, #extension, #pragma and #line are dropped
        if (keep) o << raw;
        o << "\n";
        for (auto &c : cont) {
            ++lineno;
            if (keep) o << c;
            o << "\n";
        }
    }
    if (!stack.empty())
        errors.push_back("unterminated #if at end of source");
    out = o.str();
}

MacroTable tableOf(const std::map<std::string, std::string> &macros) {
    MacroTable t;
    for (auto &kv : macros) defineMacro(t, kv.first, kv.second);
    return t;
}

} // namespace

bool preprocess(const std::string &src, MacroTable &macros, std::string &out, std::vector<std::string> &errors) {
    size_t before = errors.size();
    runDirectives(src, macros, true, false, out, errors);
    return errors.size() == before;
}

const std::map<std::string, std::string> &standardMacros() {
    static const std::map<std::string, std::string> m = {
        {"MC_VERSION", "12101"}, {"MC_GL_VERSION", "460"}, {"MC_GLSL_VERSION", "460"}, {"MC_OS_LINUX", ""},
        {"MC_GL_VENDOR_OTHER", ""}, {"MC_GL_RENDERER_OTHER", ""}, {"MC_RENDER_QUALITY", "1.0"},
        {"MC_SHADOW_QUALITY", "1.0"}, {"MC_HAND_DEPTH", "0.125"}, {"IS_IRIS", ""}, {"IRIS_VERSION", "10800"},
        {"GOANNA", "1"},
    };
    return m;
}

bool conditionHolds(const std::string &expr, const std::map<std::string, std::string> &macros, std::string &err) {
    double v = 0;
    if (!evalCondition(expr, tableOf(macros), v, err)) return false;
    return v != 0;
}

std::string runConditionals(const std::string &text, std::map<std::string, std::string> &macros,
        std::vector<std::string> *errors, bool keep_defines) {
    MacroTable t = tableOf(macros);
    std::vector<std::string> errs;
    std::string out;
    runDirectives(text, t, false, keep_defines, out, errs);
    if (errors) errors->insert(errors->end(), errs.begin(), errs.end());
    // Back to name -> value. A function-like macro keeps its name, which is
    // what #ifdef tests, with no value.
    macros.clear();
    for (auto &kv : t) macros[kv.first] = kv.second.function ? "" : kv.second.body;
    return out;
}

} // namespace iris
} // namespace goanna
