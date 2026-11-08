// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Client-side wounds (goanna_body_damage.h) against DorfCraft's server
// mesh. The fixtures come from DorfCraft's
// tools/kindred_creatures/kit/damage/client_fixture.lua: for the carried
// round shield and the sapiens adult, the wire form, the wire state after
// runs of real blows on the kit's damage controller, and the glTF the
// server's runtime mesh (kit/damage/mesh.lua) builds for each state. No
// Godot.
//
// Usage: goanna_body_damage_test FIXTURE_DIR DORFCRAFT_ROOT
//
// Checks, per case and step:
// - the form and the state parse, and the cells the state names as lost
//   are exactly the runs it carries;
// - the generated buffer is byte for byte the server's (every position,
//   normal, texture coordinate, joint, weight and index);
// - the primitives, the appended accessors and buffer views match;
// - the binary glTF for the loader has the base and generated buffers in
//   one chunk, the generated views moved past the base.
// And reports the client's cost per build.

#include "goanna_body_damage.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>

using namespace goanna;

static int g_checks = 0, g_failed = 0;
static void expect(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        ++g_failed;
        std::cerr << "FAIL " << what << "\n";
    }
}

static bool readFile(const std::string &path, std::string &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::ostringstream s;
    s << f.rdbuf();
    out = s.str();
    return true;
}

static bool parse(const std::string &text, Json::Value &v) {
    Json::CharReaderBuilder b;
    std::string errs;
    std::unique_ptr<Json::CharReader> r(b.newCharReader());
    return r->parse(text.data(), text.data() + text.size(), &v, &errs);
}

static bool empty(const Json::Value &v) {
    return v.isNull() || ((v.isObject() || v.isArray()) && v.empty());
}

// Structural equality, numbers as doubles, an empty table the same as
// null (the server's JSON writes an empty table as null).
static bool same(const Json::Value &a, const Json::Value &b, std::string &where) {
    if (empty(a) && empty(b))
        return true;
    if (a.isNumeric() && b.isNumeric()) {
        double x = a.asDouble(), y = b.asDouble();
        if (x == y || std::fabs(x - y) <= 1e-12 * std::max(1.0, std::fabs(x)))
            return true;
        where += ": " + std::to_string(x) + " v " + std::to_string(y);
        return false;
    }
    if (a.type() != b.type() && !(a.isBool() && b.isBool())) {
        where += ": type";
        return false;
    }
    if (a.isArray()) {
        if (a.size() != b.size()) {
            where += ": length " + std::to_string(a.size()) + " v " + std::to_string(b.size());
            return false;
        }
        for (Json::ArrayIndex i = 0; i < a.size(); ++i) {
            std::string w = where + "[" + std::to_string(i) + "]";
            if (!same(a[i], b[i], w)) {
                where = w;
                return false;
            }
        }
        return true;
    }
    if (a.isObject()) {
        std::set<std::string> keys;
        for (const auto &k : a.getMemberNames())
            keys.insert(k);
        for (const auto &k : b.getMemberNames())
            keys.insert(k);
        for (const auto &k : keys) {
            std::string w = where + "." + k;
            if (!same(a.isMember(k) ? a[k] : Json::Value(), b.isMember(k) ? b[k] : Json::Value(), w)) {
                where = w;
                return false;
            }
        }
        return true;
    }
    if (a == b)
        return true;
    where += ": value";
    return false;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: goanna_body_damage_test FIXTURE_DIR DORFCRAFT_ROOT\n";
        return 2;
    }
    const std::string dir = argv[1], root = argv[2];
    for (const char *name : {"shield", "sapiens"}) {
        const std::string here = dir + "/" + name;
        {
            std::ifstream probe(here + "/form.json");
            if (!probe) {
                std::cout << name << ": no fixture, skipped\n";
                continue;
            }
        }
        std::string text, model_path;
        expect(readFile(here + "/form.json", text), std::string(name) + ": form.json reads");
        Json::Value fv;
        expect(parse(text, fv), std::string(name) + ": form parses");
        DamageForm form;
        std::string err;
        expect(parseDamageForm(fv, form, &err), std::string(name) + ": form loads " + err);
        size_t form_bytes = text.size();
        readFile(here + "/model.txt", model_path);
        while (!model_path.empty() && (model_path.back() == '\n' || model_path.back() == '\r'))
            model_path.pop_back();
        std::string base_text;
        // The DorfCraft path, else the model's own name beside the fixture.
        bool have_base = readFile(root + "/" + model_path, base_text) ||
                readFile(here + "/" + model_path.substr(model_path.rfind('/') + 1), base_text);
        expect(have_base, std::string(name) + ": base model reads");
        auto t0 = std::chrono::steady_clock::now();
        DamageBase base;
        expect(loadDamageBase(base_text, base, &err), std::string(name) + ": base loads " + err);
        double base_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::string steps_text;
        readFile(here + "/steps.txt", steps_text);
        int steps = std::atoi(steps_text.c_str());
        expect(steps > 0, std::string(name) + ": has steps");
        double most_ms = 0, total_ms = 0, glb_ms = 0;
        size_t glb_bytes = 0, state_bytes = 0;
        for (int n = 1; n <= steps; ++n) {
            char file[32];
            const std::string tag = std::string(name) + " step " + std::to_string(n);
            std::snprintf(file, sizeof(file), "/state_%02d.json", n);
            std::string st;
            readFile(here + file, st);
            state_bytes += st.size();
            Json::Value sv;
            expect(parse(st, sv), tag + ": state parses");
            DamageState state;
            expect(applyDamageParts(form, sv["parts"], true, state, &err), tag + ": state applies " + err);
            // The lost cells are exactly the runs.
            for (const auto &id : sv["parts"].getMemberNames()) {
                const Json::Value &p = sv["parts"][id];
                if (p["s"].asInt() == 1) {
                    expect(state.parts[id].severed, tag + ": " + id + " severed");
                    continue;
                }
                size_t want = 0, got = 0;
                for (Json::ArrayIndex i = 1; i < p["x"].size(); i += 2)
                    want += p["x"][i].asUInt();
                for (uint8_t r : state.parts[id].removed)
                    got += r;
                expect(want == got, tag + ": " + id + " lost cells " + std::to_string(got) + " of " +
                        std::to_string(want));
            }
            auto b0 = std::chrono::steady_clock::now();
            DamageMesh mesh;
            bool built = buildDamageMesh(form, base, state, mesh, &err);
            double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - b0).count();
            expect(built, tag + ": builds " + err);
            auto g0 = std::chrono::steady_clock::now();
            std::string glb = damageGlb(base, mesh);
            double gms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - g0).count();
            most_ms = std::max(most_ms, ms + gms);
            total_ms += ms;
            glb_ms += gms;
            glb_bytes = glb.size();
            std::snprintf(file, sizeof(file), "/expected_%02d.json", n);
            std::string ex;
            readFile(here + file, ex);
            Json::Value ev;
            expect(parse(ex, ev), tag + ": expected parses");
            std::string server_bin = damageBase64Decode(ev["bin"].asString());
            expect(server_bin == mesh.generated, tag + ": generated buffer is the server's, " +
                    std::to_string(mesh.generated.size()) + " bytes v " + std::to_string(server_bin.size()));
            std::string where = "primitives";
            expect(same(ev["primitives"], mesh.primitives, where), tag + ": " + where);
            // The accessors and views past the base model's.
            expect(ev["base_accessors"].asUInt() == base.accessor_count &&
                            ev["base_views"].asUInt() == base.view_count,
                    tag + ": base accessors and views agree");
            where = "accessors";
            expect(same(ev["accessors"], mesh.accessors, where), tag + ": " + where);
            where = "bufferViews";
            expect(same(ev["bufferViews"], mesh.views, where), tag + ": " + where);
            // The binary glTF: header, JSON chunk, one BIN chunk.
            expect(glb.size() > 28 && glb.compare(0, 4, "glTF") == 0, tag + ": GLB header");
            {
                // Its JSON chunk parses and has the build's primitives.
                uint32_t jl = (uint8_t)glb[12] | (uint8_t)glb[13] << 8 | (uint8_t)glb[14] << 16 |
                        (uint32_t)(uint8_t)glb[15] << 24;
                Json::Value g;
                bool ok = jl + 20 <= glb.size() && parse(glb.substr(20, jl), g);
                where = "glb";
                expect(ok && g["buffers"].size() == 1 &&
                                g["accessors"].size() == base.accessor_count + mesh.accessors.size() &&
                                same(g["meshes"][0]["primitives"], mesh.primitives, where),
                        tag + ": GLB JSON " + where);
            }
            if (n == steps)
                std::cout << name << " step " << n << ": " << mesh.generated_triangles << " generated triangles, "
                          << mesh.layer_quads << " layer quads, " << mesh.damaged << " damaged, " << mesh.severed
                          << " severed, " << mesh.intact << " intact parts\n";
        }
        std::printf("%s: form %zu bytes JSON, %zu cells; base read %.1f ms; build %.2f ms mean, GLB %.2f ms mean,"
                    " most %.2f ms; GLB %zu bytes; %zu state bytes over %d steps\n",
                name, form_bytes, form.cells, base_ms, total_ms / steps, glb_ms / steps, most_ms, glb_bytes,
                state_bytes, steps);
    }
    std::cout << g_checks - g_failed << " of " << g_checks << " checks passed\n";
    return g_failed ? 1 : 0;
}
