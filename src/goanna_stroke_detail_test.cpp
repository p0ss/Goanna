// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Melee strokes by distance from the camera (goanna_stroke_detail.h), on
// the stroke fixtures with no Godot runtime. Built and run by `cmake
// --build build --target check`.
//
// Usage: goanna_stroke_detail_test [fixture dir], default
// tools/test/strokes, read from the repository root.
//
// Checked:
// - the tiers by distance and on screen, and their hysteresis;
// - the fade in and out of Clip takes STROKE_DETAIL_BLEND and moves a
//   little each step, and a body that appears far off starts faded;
// - the Reduced tier's interpolated pose stays close to a full evaluation
//   all through a stroke, at several angles, on both fixture bodies, with
//   about STROKE_REDUCED_RATE evaluations a second;
// - the ground is asked for every step near, STROKE_REDUCED_RATE times a
//   second further out, never in Clip.
// Then a crowd of 10, 30 and 60 stroking bodies at mixed distances, timed
// with every body evaluated every step (as before the tiers) and with the
// tiers.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <json/json.h>
#include <quaternion.h>
#include <vector3d.h>

#include "goanna_stroke_detail.h"
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
            std::cerr << "goanna_stroke_detail_test: " << message << "\n";
    }
}

bool readJson(const std::string &path, Json::Value &root) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::ostringstream s;
    s << f.rdbuf();
    const std::string text = s.str();
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    std::string errors;
    return reader->parse(text.data(), text.data() + text.size(), &root, &errors);
}

// Degrees between two rotations given as the evaluator's Euler radians,
// both read as the animator reads them.
double angleBetween(const float a[3], const float b[3]) {
    core::quaternion qa(core::vector3df(a[0], a[1], a[2])), qb(core::vector3df(b[0], b[1], b[2]));
    const double d = std::fabs(qa.dotProduct(qb));
    return 2 * std::acos(std::min(1.0, d)) * 180 / M_PI;
}

constexpr float kStep = 1.0f / 60.0f;

void checkTiers() {
    using D = StrokeDetail;
    expect(chooseStrokeDetail(5, true, D::Clip) == D::Full, "5 nodes on screen is not Full");
    expect(chooseStrokeDetail(5, false, D::Full) == D::Reduced, "5 nodes off screen is not Reduced");
    expect(chooseStrokeDetail(17, true, D::Full) == D::Full, "Full is not held 1 node past its edge");
    expect(chooseStrokeDetail(17, true, D::Reduced) == D::Reduced, "Reduced at 17 nodes became Full");
    expect(chooseStrokeDetail(19, true, D::Full) == D::Reduced, "Full is held 3 nodes past its edge");
    expect(chooseStrokeDetail(49, true, D::Reduced) == D::Reduced, "Reduced is not held 1 node past its edge");
    expect(chooseStrokeDetail(49, true, D::Clip) == D::Clip, "Clip at 49 nodes became Reduced");
    expect(chooseStrokeDetail(47, true, D::Clip) == D::Reduced, "47 nodes is not Reduced");
    expect(chooseStrokeDetail(51, true, D::Reduced) == D::Clip, "51 nodes is not Clip");
    expect(chooseStrokeDetail(200, false, D::Full) == D::Clip, "200 nodes off screen is not Clip");
}

void checkFade() {
    StrokeLod lod;
    lod.step(kStep, StrokeDetail::Full);
    expect(lod.weight() == 1.0f, "a near body does not start at full weight");
    float last = lod.weight(), most = 0;
    int steps = 0;
    while (lod.weight() > 0.0f && steps < 1000) {
        lod.step(kStep, StrokeDetail::Clip);
        most = std::max(most, std::fabs(lod.weight() - last));
        expect(lod.weight() <= last, "the fade out went up");
        last = lod.weight();
        ++steps;
    }
    const float seconds = steps * kStep;
    expect(std::fabs(seconds - STROKE_DETAIL_BLEND) < 2 * kStep, "the fade out took " + std::to_string(seconds) + " s");
    // Smoothstep's steepest is 1.5 times the linear rate.
    expect(most <= 1.5f * kStep / STROKE_DETAIL_BLEND + 1e-4f, "the fade out jumped " + std::to_string(most));
    for (int i = 0; i < 30; ++i)
        lod.step(kStep, StrokeDetail::Reduced);
    expect(lod.weight() == 1.0f, "the fade in did not finish in half a second");
    StrokeLod far;
    far.step(kStep, StrokeDetail::Clip);
    expect(far.weight() == 0.0f, "a body that appears far off does not start faded");
}

void checkGround() {
    StrokeLod lod;
    auto count = [&](StrokeDetail d) {
        lod.step(kStep, d);
        int due = lod.groundDue(kStep) ? 1 : 0;
        for (int i = 1; i < 60; ++i) {
            lod.step(kStep, d);
            due += lod.groundDue(kStep) ? 1 : 0;
        }
        return due;
    };
    expect(count(StrokeDetail::Full) == 60, "Full does not ask for the ground every step");
    const int reduced = count(StrokeDetail::Reduced);
    expect(reduced >= 14 && reduced <= 16, "Reduced asked for the ground " + std::to_string(reduced) + " times a second");
    expect(count(StrokeDetail::Clip) == 0, "Clip asked for the ground");
}

// The Reduced tier against a full evaluation each step, all through a
// stroke at several angles. The full evaluation itself is not smooth
// everywhere: where it turns a bone a long way in one step (a flip), the
// interpolation cuts the corner, so the error is reported as a high
// percentile over every bone and step, with the worst and the flips beside
// it.
void checkInterpolation(const std::string &name, const StrokeEvaluator &evaluator) {
    std::vector<double> errors_p, errors_r;
    double worst_flip = 0;
    int flips = 0;
    uint64_t evaluations = 0;
    int strokes = 0;
    std::vector<StrokeBonePose> full, reduced, previous;
    for (float angle = 0; angle < 360; angle += 37.5f) {
        StrokeLod lod;
        bool restart = true;
        previous.clear();
        for (float t = 0; t <= evaluator.length(); t += kStep) {
            lod.step(kStep, StrokeDetail::Reduced);
            lod.pose(evaluator, angle, t, restart, reduced);
            restart = false;
            evaluator.evaluate(angle, t, full);
            expect(full.size() == reduced.size(), name + ": interpolated pose has other bones");
            for (size_t i = 0; i < std::min(full.size(), reduced.size()); ++i) {
                double p = 0;
                for (int k = 0; k < 3; ++k)
                    p = std::max(p, double(std::fabs(full[i].p[k] - reduced[i].p[k])));
                errors_p.push_back(p);
                errors_r.push_back(angleBetween(full[i].r, reduced[i].r));
            }
            if (previous.size() == full.size())
                for (size_t i = 0; i < full.size(); ++i) {
                    const double turn = angleBetween(previous[i].r, full[i].r);
                    worst_flip = std::max(worst_flip, turn);
                    flips += turn > 30 ? 1 : 0;
                }
            previous = full;
        }
        evaluations += lod.evaluations();
        ++strokes;
    }
    auto percentile = [](std::vector<double> v, double q) {
        std::sort(v.begin(), v.end());
        return v.empty() ? 0.0 : v[std::min(v.size() - 1, size_t(q * v.size()))];
    };
    const double per_second = evaluations / (strokes * double(evaluator.length()));
    const double p99 = percentile(errors_p, 0.99), r99 = percentile(errors_r, 0.99);
    std::printf("%s: Reduced against full evaluation over %zu bone steps: 99th percentile %.4f nodes, %.2f "
                "degrees; worst %.4f nodes, %.2f degrees; %.1f evaluations a second\n",
            name.c_str(), errors_p.size(), p99, r99, percentile(errors_p, 1.0), percentile(errors_r, 1.0),
            per_second);
    std::printf("%s: full evaluation turned a bone more than 30 degrees in one step %d times, at most %.1f "
                "degrees\n",
            name.c_str(), flips, worst_flip);
    expect(per_second <= STROKE_REDUCED_RATE + 2, name + ": too many evaluations in Reduced");
    // Loose bounds: the error is what Reduced trades for its cost, and is
    // printed above for the record.
    expect(p99 < 0.05, name + ": interpolated position 99th percentile " + std::to_string(p99));
    expect(r99 < 10, name + ": interpolated rotation 99th percentile " + std::to_string(r99));
}

struct Body {
    const StrokeEvaluator *evaluator;
    float distance, angle, offset;
    bool on_screen;
    StrokeLod lod;
    float last_t = 1e9f;
    std::vector<StrokeBonePose> out;
};

struct CrowdResult {
    double us_per_step = 0;
    double evaluations_per_step = 0;
    double ground_per_step = 0;
    int tiers[3] = {};
};

// A crowd stroking over and over, each body with its own angle and start,
// for `steps` steps at 60 a second. With tiers off, every body is Full, as
// every body was evaluated before the tiers. The best of three runs.
CrowdResult runCrowd(const std::vector<const StrokeEvaluator *> &evaluators, int n, bool tiers, int steps) {
    CrowdResult best;
    for (int run = 0; run < 3; ++run) {
        std::vector<Body> bodies(n);
        for (int i = 0; i < n; ++i) {
            Body &b = bodies[i];
            b.evaluator = evaluators[i % evaluators.size()];
            b.distance = 2.0f + 78.0f * (i + 0.5f) / n; // 2 to 80 nodes
            b.on_screen = i % 5 != 4;
            b.angle = std::fmod(47.0f * i, 360.0f);
            b.offset = 0.37f * i;
        }
        CrowdResult r;
        uint64_t ground = 0;
        const auto start = std::chrono::steady_clock::now();
        for (int s = 0; s < steps; ++s) {
            for (Body &b : bodies) {
                const StrokeDetail d = tiers ? chooseStrokeDetail(b.distance, b.on_screen, b.lod.detail())
                                             : StrokeDetail::Full;
                b.lod.step(kStep, d);
                if (b.lod.groundDue(kStep))
                    ++ground;
                const float t = std::fmod(s * kStep + b.offset, b.evaluator->length());
                const bool restart = t < b.last_t;
                b.last_t = t;
                if (b.lod.weight() > 0.0f)
                    b.lod.pose(*b.evaluator, b.angle, t, restart, b.out);
                if (s == steps - 1)
                    ++r.tiers[(int)d];
            }
        }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        uint64_t evaluations = 0;
        for (const Body &b : bodies)
            evaluations += b.lod.evaluations();
        r.us_per_step = seconds * 1e6 / steps;
        r.evaluations_per_step = double(evaluations) / steps;
        r.ground_per_step = double(ground) / steps;
        if (run == 0 || r.us_per_step < best.us_per_step)
            best = r;
    }
    return best;
}

} // namespace

int main(int argc, char **argv) {
    const std::string dir = argc > 1 ? argv[1] : "tools/test/strokes";
    Json::Value family_json, reference, tentacle;
    if (!readJson(dir + "/family.json", family_json) || !readJson(dir + "/reference.json", reference)
            || !readJson(dir + "/tentacle_arms.json", tentacle)) {
        std::cerr << "goanna_stroke_detail_test: cannot read the fixtures in " << dir
                  << " (run from the repository root)\n";
        return 1;
    }
    auto family = std::make_shared<StrokeFamily>();
    StrokePlan reference_plan, tentacle_plan;
    expect(parseStrokeFamily(family_json, *family), "family does not parse");
    expect(parseStrokePlan(reference["plan"], reference_plan), "reference plan does not parse");
    expect(parseStrokePlan(tentacle["plan"], tentacle_plan), "tentacle plan does not parse");
    StrokeEvaluator two_bone(reference_plan, family), tentacles(tentacle_plan, family);
    expect(two_bone.valid() && tentacles.valid(), "an evaluator is not valid");
    if (g_failures) {
        std::cerr << "goanna_stroke_detail_test: fixtures did not load\n";
        return 1;
    }

    checkTiers();
    checkFade();
    checkGround();
    checkInterpolation("reference", two_bone);
    checkInterpolation("tentacle_arms", tentacles);

    // The crowd: half two-bone arms, half tentacle arms, 2 to 80 nodes
    // away, every fifth off screen, four seconds at 60 steps a second.
    const std::vector<const StrokeEvaluator *> evaluators{&two_bone, &tentacles};
    std::printf("crowd, bodies 2 to 80 nodes away, every fifth off screen, 240 steps, best of 3:\n");
    for (int n : {10, 30, 60}) {
        const CrowdResult before = runCrowd(evaluators, n, false, 240);
        const CrowdResult after = runCrowd(evaluators, n, true, 240);
        std::printf("  %2d bodies: every body full %7.0f us a step (%5.1f evaluations, %4.1f ground asks); "
                    "tiers %d/%d/%d %6.0f us a step (%5.1f evaluations, %4.1f ground asks)\n",
                n, before.us_per_step, before.evaluations_per_step, before.ground_per_step, after.tiers[0],
                after.tiers[1], after.tiers[2], after.us_per_step, after.evaluations_per_step,
                after.ground_per_step);
        expect(after.evaluations_per_step < before.evaluations_per_step, "tiers did not save evaluations");
    }

    if (g_failures) {
        std::cerr << "goanna_stroke_detail_test: " << g_failures << " of " << g_checks << " checks failed\n";
        return 1;
    }
    std::printf("goanna_stroke_detail_test: all %d checks passed\n", g_checks);
    return 0;
}
