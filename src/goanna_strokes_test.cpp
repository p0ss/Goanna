// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The stroke evaluator (goanna_strokes.h) against reference evaluations
// from DorfCraft's Lua evaluator (strokes/fixture.lua), with no Godot
// runtime. Built and run by `cmake --build build --target check`.
//
// Usage: goanna_strokes_test [fixture dir], default tools/test/strokes,
// read from the repository root. The directory holds family.json and one
// JSON file a body: {plan, cases: [{angle, t, overrides: {bone: {p, r}}}]}.
//
// Checked:
// - the family and each body's plan parse, and the evaluator is valid;
// - every case gives exactly the fixture's bones, each position within
//   1e-3 nodes and each rotation within 0.05 degrees, compared as
//   quaternions so Euler aliasing cannot hide or invent a difference;
// - a plan missing a role bone, or with no family, is invalid and
//   evaluates to nothing.

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <json/json.h>

#include "goanna_strokes.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        if (g_failures <= 40)
            std::cerr << "goanna_strokes_test: " << message << "\n";
    }
}

bool readFile(const std::string &path, std::string &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::ostringstream s;
    s << f.rdbuf();
    out = s.str();
    return true;
}

bool readJson(const std::string &path, Json::Value &root) {
    std::string text;
    if (!readFile(path, text))
        return false;
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    std::string errors;
    return reader->parse(text.data(), text.data() + text.size(), &root, &errors);
}

// R = Rz Ry Rx, as Luanti applies a bone override's Euler angles.
std::array<double, 4> quatOf(const double r[3]) {
    double cx = std::cos(r[0] / 2), sx = std::sin(r[0] / 2);
    double cy = std::cos(r[1] / 2), sy = std::sin(r[1] / 2);
    double cz = std::cos(r[2] / 2), sz = std::sin(r[2] / 2);
    return {sx * cy * cz - cx * sy * sz, cx * sy * cz + sx * cy * sz, cx * cy * sz - sx * sy * cz,
            cx * cy * cz + sx * sy * sz};
}

double angleBetween(const double a[3], const double b[3]) {
    std::array<double, 4> x = quatOf(a), y = quatOf(b);
    double d = std::fabs(x[0] * y[0] + x[1] * y[1] + x[2] * y[2] + x[3] * y[3]);
    return 2 * std::acos(std::min(1.0, d)) * 180 / M_PI;
}

void checkBody(const std::string &path, std::shared_ptr<const StrokeFamily> family) {
    Json::Value root;
    if (!readJson(path, root)) {
        expect(false, "cannot read " + path);
        return;
    }
    StrokePlan plan;
    expect(parseStrokePlan(root["plan"], plan), path + ": plan does not parse");
    StrokeEvaluator evaluator(plan, family);
    expect(evaluator.valid(), path + ": evaluator not valid");
    if (!evaluator.valid())
        return;

    const Json::Value &cases = root["cases"];
    double worst_p = 0, worst_r = 0;
    std::string worst_p_at, worst_r_at;
    std::vector<StrokeBonePose> out;
    auto start = std::chrono::steady_clock::now();
    int evaluations = 0;
    for (const Json::Value &c : cases) {
        double angle = c["angle"].asDouble(), t = c["t"].asDouble();
        evaluator.evaluate(float(angle), float(t), out);
        ++evaluations;
        char where[64];
        std::snprintf(where, sizeof where, "angle %g t %g", angle, t);
        const Json::Value &want = c["overrides"];
        std::map<std::string, const StrokeBonePose *> got;
        for (const StrokeBonePose &o : out)
            got[o.bone] = &o;
        expect(got.size() == want.size(),
                path + " " + where + ": " + std::to_string(got.size()) + " bones, fixture has " +
                        std::to_string(want.size()));
        for (const std::string &bone : want.getMemberNames()) {
            auto it = got.find(bone);
            expect(it != got.end(), path + " " + where + ": no " + bone);
            if (it == got.end())
                continue;
            const Json::Value &w = want[bone];
            double wp[3], wr[3], gr[3], dp = 0;
            for (int i = 0; i < 3; ++i) {
                wp[i] = w["p"][i].asDouble();
                wr[i] = w["r"][i].asDouble();
                gr[i] = it->second->r[i];
                dp = std::max(dp, std::fabs(wp[i] - it->second->p[i]));
            }
            double dr = angleBetween(wr, gr);
            if (dp > worst_p) {
                worst_p = dp;
                worst_p_at = std::string(where) + " " + bone;
            }
            if (dr > worst_r) {
                worst_r = dr;
                worst_r_at = std::string(where) + " " + bone;
            }
            char message[160];
            std::snprintf(message, sizeof message, ": %s position off by %.6f nodes", bone.c_str(), dp);
            expect(dp <= 1e-3, path + " " + where + message);
            std::snprintf(message, sizeof message, ": %s rotation off by %.4f degrees", bone.c_str(), dr);
            expect(dr <= 0.05, path + " " + where + message);
        }
    }
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("%s: %d cases, worst position %.2e nodes (%s), worst rotation %.2e degrees (%s)\n",
            path.c_str(), evaluations, worst_p, worst_p_at.c_str(), worst_r, worst_r_at.c_str());

    // Time apart from the checks: the same cases again, evaluation only.
    start = std::chrono::steady_clock::now();
    const int rounds = 5;
    for (int k = 0; k < rounds; ++k)
        for (const Json::Value &c : cases)
            evaluator.evaluate(float(c["angle"].asDouble()), float(c["t"].asDouble()), out);
    seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("%s: %.1f microseconds an evaluation\n", path.c_str(),
            seconds * 1e6 / (rounds * double(cases.size())));

    // A plan missing a role bone is refused, and evaluates to nothing.
    StrokePlan broken = plan;
    for (StrokePlanBone &b : broken.bones)
        if (b.name == "sword")
            b.name = "sword_renamed";
    StrokeEvaluator refused(broken, family);
    expect(!refused.valid(), path + ": a plan without a sword bone is valid");
    expect(refused.evaluate(0, .5f).empty(), path + ": an invalid evaluator gave a pose");
    StrokeEvaluator orphan(plan, nullptr);
    expect(!orphan.valid(), path + ": an evaluator with no family is valid");
}

} // namespace

int main(int argc, char **argv) {
    std::string dir = argc > 1 ? argv[1] : "tools/test/strokes";
    std::string text;
    if (!readFile(dir + "/family.json", text)) {
        std::cerr << "goanna_strokes_test: cannot read " << dir << "/family.json (run from the repository root)\n";
        return 1;
    }
    auto family = std::make_shared<StrokeFamily>();
    expect(parseStrokeFamily(text, *family), "family does not parse");
    expect(family->strokes.size() == 8, "family should have 8 strokes");
    expect(std::fabs(family->length - 1.85) < 1e-9, "family length should be 1.85 s");
    StrokeFamily empty;
    expect(!parseStrokeFamily(std::string("{}"), empty), "an empty object parsed as a family");

    checkBody(dir + "/reference.json", family);
    checkBody(dir + "/tentacle_arms.json", family);

    if (g_failures) {
        std::cerr << "goanna_strokes_test: " << g_failures << " of " << g_checks << " checks failed\n";
        return 1;
    }
    std::printf("goanna_strokes_test: all %d checks passed\n", g_checks);
    return 0;
}
