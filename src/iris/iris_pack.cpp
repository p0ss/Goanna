// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "iris_pack.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
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

    // shaders.properties: key=value, # comments, backslash continuation.
    std::string props;
    if (readFile((fs::path(m_shaders) / "shaders.properties").string(), props)) {
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
            m_props[trim(t.substr(0, eq))] = trim(t.substr(eq + 1));
        }
    }

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
    // consts from every source, comments included
    for (auto &n : m_programs) {
        for (const char *ext : {".vsh", ".fsh"}) {
            std::string path = findProgramFile(n, ext);
            if (path.empty()) continue;
            std::string e2, src = readResolved(path, 0, e2);
            scanConsts(src, m_consts);
        }
    }
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
        out += line + "\n";
    }
    return out;
}

bool Pack::program(const std::string &name, Program &out, std::string &err) const {
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
    return err.empty();
}

std::vector<std::string> Pack::compositeChain() const {
    std::vector<std::string> chain;
    auto addSeries = [&](const char *base) {
        if (hasProgram(base)) chain.push_back(base);
        for (int i = 1; i < 100; ++i) {
            std::string n = std::string(base) + std::to_string(i);
            if (hasProgram(n)) chain.push_back(n);
        }
    };
    addSeries("deferred");
    addSeries("composite");
    if (hasProgram("final")) chain.push_back("final");
    return chain;
}

} // namespace iris
} // namespace goanna
