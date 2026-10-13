// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Reading a shader pack from disk: shaders.properties, the program list,
// options, const directives and #include resolution. See iris_pack.h.

#include "iris_pack.h"

#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <limits>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>

namespace fs = std::filesystem;

namespace goanna {
namespace iris {

static bool readFile(const std::string &path, std::string &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

static std::string trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

// An option line: "#define NAME", "#define NAME value" or "//#define NAME",
// each with an optional trailing comment (where OptiFine lists the allowed
// values). Function like macros and commented out value defines are not
// options.
static bool matchDefine(const std::string &line, bool &commented, std::string &name, std::string &value) {
    if (line.find("#define") == std::string::npos)
        return false;
    static const std::regex re(R"(^\s*(//\s*)?#define\s+([A-Za-z_]\w*)(?:[ \t]+([^/\r\n]*?))?\s*(?://.*)?\r?$)");
    std::smatch m;
    if (!std::regex_match(line, m, re))
        return false;
    commented = m[1].matched;
    name = m[2].str();
    value = m[3].matched ? trim(m[3].str()) : "";
    if (commented && !value.empty())
        return false;
    return true;
}


std::map<std::string, std::string> parseOptionOverrides(const std::string &text) {
    std::map<std::string, std::string> out;
    std::string s = text;
    std::replace(s.begin(), s.end(), ',', ' ');
    std::stringstream ss(s);
    std::string item;
    while (ss >> item) {
        size_t eq = item.find('=');
        if (eq != std::string::npos)
            out[item.substr(0, eq)] = item.substr(eq + 1);
    }
    return out;
}

void Pack::scanOptions(const std::string &src) {
    std::stringstream ss(src);
    std::string line;
    while (std::getline(ss, line)) {
        bool commented;
        std::string name, value;
        if (!matchDefine(line, commented, name, value))
            continue;
        // The first declaration of a name is the option; later ones are the
        // pack redefining it under some condition.
        if (!m_options_seen.insert(name).second)
            continue;
        if (commented)
            m_options_off.insert(name);
        else
            m_options[name] = value;
    }
}

std::vector<std::string> Pack::unknownOverrides() const {
    std::vector<std::string> out;
    for (auto &kv : m_overrides)
        if (!m_options_seen.count(kv.first))
            out.push_back(kv.first);
    return out;
}

void Pack::readProperties() {
    std::string props;
    if (!readFile((fs::path(m_shaders) / "shaders.properties").string(), props))
        return;
    // Conditionals first, against the standard macros and the options as
    // they will be compiled, as OptiFine and Iris do.
    std::map<std::string, std::string> macros = standardMacros();
    for (auto &kv : m_options)
        macros[kv.first] = kv.second;
    std::vector<std::string> errors;
    props = runConditionals(props, macros, &errors);
    for (auto &e : errors)
        m_prop_warnings.push_back("shaders.properties " + e);
    // key=value, # comments, backslash continuation.
    std::string pending;
    std::stringstream ss(props);
    std::string line;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::string t = trim(line);
        if (!pending.empty()) { t = pending + " " + t; pending.clear(); }
        if (t.empty() || t[0] == '#') continue;
        if (t.back() == '\\') { pending = t.substr(0, t.size() - 1); continue; }
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        std::string key = trim(t.substr(0, eq)), value = trim(t.substr(eq + 1));
        m_props[key] = value;
        // uniform.<type>.<name> and variable.<type>.<name>, in file order
        bool uni = key.rfind("uniform.", 0) == 0, var = key.rfind("variable.", 0) == 0;
        if (uni || var) {
            size_t a = key.find('.'), b = key.find('.', a + 1);
            if (b == std::string::npos) continue;
            std::string type = key.substr(a + 1, b - a - 1), name = key.substr(b + 1);
            std::string err;
            if (!m_custom.add(type, name, uni, value, err))
                m_prop_warnings.push_back(key + ": " + err);
        }
    }
}

bool Pack::load(const std::string &dir, std::string &err) {
    std::error_code ec;
    fs::path root(dir);
    if (!fs::is_directory(root, ec)) {
        err = "not a directory: " + dir;
        return false;
    }
    if (fs::is_directory(root / "shaders", ec)) {
        m_root = root.string();
        m_shaders = (root / "shaders").string();
    } else if (root.filename() == "shaders") {
        m_root = root.parent_path().string();
        m_shaders = root.string();
    } else {
        err = "no shaders/ directory in " + dir;
        return false;
    }
    m_name = fs::path(m_root).filename().string();
    // Overworld programs live in shaders/world0/ when a pack has per dimension
    // sets; otherwise at the root.
    if (fs::is_directory(fs::path(m_shaders) / "world0", ec))
        m_world = (fs::path(m_shaders) / "world0").string();

    // Programs: every .fsh at the world dir (if any) and the root. The world
    // dir wins for a name present in both, which findProgramFile also does.
    std::vector<std::string> dirs;
    if (!m_world.empty()) dirs.push_back(m_world);
    dirs.push_back(m_shaders);
    for (auto &d : dirs) {
        std::vector<std::string> names;
        for (auto &e : fs::directory_iterator(d, ec)) {
            if (!e.is_regular_file()) continue;
            auto p = e.path();
            if (p.extension() == ".fsh")
                names.push_back(p.stem().string());
        }
        std::sort(names.begin(), names.end());
        for (auto &n : names)
            if (std::find(m_programs.begin(), m_programs.end(), n) == m_programs.end())
                m_programs.push_back(n);
    }
    if (m_programs.empty()) {
        err = "no programs (*.fsh) in " + m_shaders;
        return false;
    }
    // consts and options from every source, comments included
    for (auto &n : m_programs) {
        for (const char *ext : {".vsh", ".fsh"}) {
            std::string path = findProgramFile(n, ext);
            if (path.empty()) continue;
            std::string e2, src = readResolved(path, 0, e2);
            scanConsts(src, m_consts);
            scanOptions(src);
        }
    }
    readProperties();
    return true;
}

bool Pack::hasProgram(const std::string &name) const {
    return std::find(m_programs.begin(), m_programs.end(), name) != m_programs.end();
}

std::string Pack::findProgramFile(const std::string &name, const char *ext) const {
    std::error_code ec;
    if (!m_world.empty()) {
        fs::path p = fs::path(m_world) / (name + ext);
        if (fs::is_regular_file(p, ec)) return p.string();
    }
    fs::path p = fs::path(m_shaders) / (name + ext);
    if (fs::is_regular_file(p, ec)) return p.string();
    return "";
}

// #include "file" relative to the including file; "/lib/file" relative to the
// shaders/ root. Depth limited, because packs do include themselves by mistake.
std::string Pack::readResolved(const std::string &path, int depth, std::string &err) const {
    std::string src;
    if (!readFile(path, src)) {
        err += "cannot read " + path + "\n";
        return "";
    }
    if (depth > 32) {
        err += "include depth exceeded at " + path + "\n";
        return "";
    }
    std::string out;
    std::stringstream ss(src);
    std::string line;
    fs::path here = fs::path(path).parent_path();
    while (std::getline(ss, line)) {
        std::string t = trim(line);
        if (t.compare(0, 8, "#include") == 0) {
            size_t a = t.find('"'), b = t.rfind('"');
            if (a != std::string::npos && b != std::string::npos && b > a) {
                std::string inc = t.substr(a + 1, b - a - 1);
                fs::path ip = (!inc.empty() && inc[0] == '/') ? fs::path(m_shaders) / inc.substr(1) : here / inc;
                out += readResolved(ip.string(), depth + 1, err);
                out += "\n";
                continue;
            }
        }
        if (!m_overrides.empty()) {
            bool commented;
            std::string name, value;
            if (matchDefine(line, commented, name, value)) {
                auto o = m_overrides.find(name);
                if (o != m_overrides.end()) {
                    // a boolean is switched by commenting; a value is replaced
                    bool boolean = value.empty();
                    if (boolean && (o->second == "false" || o->second == "off"))
                        line = "//#define " + name;
                    else if (boolean)
                        line = "#define " + name;
                    else
                        line = "#define " + name + " " + o->second;
                }
            }
        }
        out += line + "\n";
    }
    return out;
}

bool Pack::program(const std::string &name, Program &out, std::string &err, std::vector<std::string> *warnings) const {
    out = Program();
    out.name = name;
    std::string f = findProgramFile(name, ".fsh");
    if (f.empty()) {
        err = "program " + name + " has no .fsh";
        return false;
    }
    out.fsh = readResolved(f, 0, err);
    std::string v = findProgramFile(name, ".vsh");
    if (!v.empty())
        out.vsh = readResolved(v, 0, err);
    else
        out.vsh = "varying vec2 texcoord;\nvoid main() { gl_Position = ftransform(); texcoord = gl_MultiTexCoord0.xy; }\n";
    // Resolve the conditionals here, per stage, so the translator sees only
    // the live branch. Packs put both stages in one file behind #ifdef VSH
    // and #ifdef FSH (or their own names), and a declaration lifted out of
    // the other stage's branch collides with this one's. The #define lines
    // stay for glslang, which expands them; line numbers keep.
    std::vector<std::string> perrs;
    for (std::string *src : {&out.vsh, &out.fsh}) {
        std::map<std::string, std::string> macros = standardMacros();
        *src = runConditionals(*src, macros, &perrs, true);
    }
    if (warnings)
        for (auto &e : perrs)
            warnings->push_back("#if: " + e);
    return err.empty();
}

std::vector<std::string> Pack::missingFeatures() const {
    std::vector<std::string> out;
    auto it = m_props.find("iris.features.required");
    if (it == m_props.end())
        return out;
    std::string list = it->second;
    std::replace(list.begin(), list.end(), ',', ' ');
    std::stringstream ss(list);
    std::string f;
    while (ss >> f)
        out.push_back(f);
    return out;
}

bool Pack::programEnabled(const std::string &name) const {
    auto it = m_props.end();
    if (!m_world.empty())
        it = m_props.find("program." + fs::path(m_world).filename().string() + "/" + name + ".enabled");
    if (it == m_props.end())
        it = m_props.find("program." + name + ".enabled");
    if (it == m_props.end())
        return true;
    // The value is an expression over option names: a boolean that is on
    // reads 1, and true and false are what they say.
    std::map<std::string, std::string> macros = standardMacros();
    for (auto &kv : m_options)
        macros[kv.first] = kv.second.empty() ? "1" : kv.second;
    macros["true"] = "1";
    macros["false"] = "0";
    std::string err;
    return conditionHolds(it->second, macros, err);
}

static std::vector<std::string> chainNames(const Pack &p) {
    std::vector<std::string> chain;
    auto addSeries = [&](const char *base) {
        if (p.hasProgram(base)) chain.push_back(base);
        for (int i = 1; i < 100; ++i) {
            std::string n = std::string(base) + std::to_string(i);
            if (p.hasProgram(n)) chain.push_back(n);
        }
    };
    addSeries("prepare");
    addSeries("deferred");
    addSeries("composite");
    if (p.hasProgram("final")) chain.push_back("final");
    return chain;
}

std::vector<std::string> Pack::compositeChain() const {
    std::vector<std::string> chain;
    for (auto &n : chainNames(*this))
        if (programEnabled(n)) chain.push_back(n);
    return chain;
}

std::vector<std::string> Pack::disabledPrograms() const {
    std::vector<std::string> off;
    for (auto &n : chainNames(*this))
        if (!programEnabled(n)) off.push_back(n);
    return off;
}

bool Pack::bufferSize(int index, bool &relative, float &x, float &y) const {
    auto s = m_props.find("size.buffer.colortex" + std::to_string(index));
    if (s == m_props.end())
        return false;
    std::istringstream in(s->second);
    std::string w, h;
    std::string extra;
    in >> w >> h;
    char *we = nullptr, *he = nullptr;
    const float fw = std::strtof(w.c_str(), &we), fh = std::strtof(h.c_str(), &he);
    if (w.empty() || h.empty() || *we || *he || (in >> extra) ||
            !std::isfinite(fw) || !std::isfinite(fh) || !(fw > 0.0f) || !(fh > 0.0f) ||
            fw >= (float)std::numeric_limits<int>::max() || fh >= (float)std::numeric_limits<int>::max())
        return false;
    relative = w.find('.') != std::string::npos || h.find('.') != std::string::npos;
    x = fw;
    y = fh;
    return true;
}

} // namespace iris
} // namespace goanna
