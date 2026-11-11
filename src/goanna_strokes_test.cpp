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
//   evaluates to nothing;
// - the state's scale Z reads back as format and weapon family (a sword
//   stroke 1, family 1's 9, a task 2), and a family with its own weapon
//   (a longer tip, an edge) parses with that weapon.

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
        evaluator.evaluate(float(angle), float(t), out, float(c.get("pitch", 0.0).asDouble()));
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

// The own body's stroke ahead of the server (StrokePreview): a frame a
// 60th of a second, a sword family committing at 0.5 s of 1.85.
StrokePreviewInput frame(bool dig, float yaw = 0) {
    StrokePreviewInput in;
    in.dt = 1.0f / 60;
    in.armed = true;
    in.open = true;
    in.dig = dig;
    in.commit = 0.5f;
    in.length = 1.85f;
    in.yaw = yaw;
    return in;
}

StrokeServerState server(int serial, int phase, float told = 0, float t = 0) {
    StrokeServerState s;
    s.present = true;
    s.serial = serial;
    s.phase = phase;
    s.format = 1;
    s.told = told;
    s.t = t;
    s.length = 1.85f;
    return s;
}

void checkPreview() {
    {
        StrokePreview p;
        auto in = frame(true);
        in.armed = false;
        expect(!p.step(in).shown, "an ordinary server never anticipates");
    }
    {
        StrokePreview p;
        p.step(frame(false));
        auto out = p.step(frame(true));
        expect(out.shown && out.phase == 3 && out.serial == StrokePreview::DRAW_SERIAL,
                "a press on a marked weapon draws in the same frame");
        for (int i = 0; i < 60; ++i)
            out = p.step(frame(true, i * -0.002f));
        expect(out.shown && out.phase == 3 && out.angle < 1, "a long hold keeps drawing, pulled right");
        out = p.step(frame(false, -0.12f));
        expect(out.shown && out.serial == StrokePreview::STRIKE_SERIAL && out.phase == 2,
                "the release strikes at once, from the full draw's commit");
        expect(std::fabs(out.t - 0.5f) < 1e-4f && out.since == 0, "the strike starts at the drawn point");
        for (int i = 0; i < 6; ++i)
            out = p.step(frame(false));
        expect(out.shown && std::fabs(out.since - 0.1f) < 1e-4f, "and runs on the client's clock");
        // The server's answer: its angle on the client's clock, not restarted.
        auto in = frame(false);
        in.server = server(7, 2, 30, 0.55f);
        out = p.step(in);
        expect(out.shown && out.serial == StrokePreview::STRIKE_SERIAL && out.angle == 30
                && std::fabs(out.t - 0.5f) < 1e-4f, "the answer is shown on the client's clock");
        for (int i = 0; i < 120; ++i)
            out = p.step(in);
        expect(out.shown && out.t + out.since > 1.85f, "a stroke played through stays over");
        out = p.step(in);
        expect(out.shown, "and is not replayed while the server's own clock runs on");
        auto press = frame(true);
        press.server = in.server;
        out = p.step(press);
        expect(out.shown && out.phase == 3, "a press after the local end draws again");
    }
    {
        StrokePreview p;
        p.step(frame(false));
        p.step(frame(true));
        auto out = p.step(frame(false));
        auto in = frame(false);
        in.server = server(4, 1);
        in.server.format = 5;
        out = p.step(in);
        expect(!out.shown && !p.active(), "a confirmed recovery replaces the prediction");
    }
    {
        StrokePreview p;
        p.step(frame(false));
        p.step(frame(true));
        auto in = frame(true);
        in.server = server(0, 3, 0, 0.1f);
        p.step(in);
        p.step(frame(false));
        in = frame(false);
        in.server = server(0, 0, 0, 0);
        auto out = p.step(in);
        expect(!out.shown && !p.active(), "a draw put down on the server ends the predicted strike");
    }
    {
        StrokePreview p;
        auto idle = frame(false);
        idle.server = server(3, 2, 0, 0.6f);
        p.step(idle);
        auto in = frame(true);
        in.server = idle.server;
        expect(!p.step(in).shown, "no draw while the server's stroke plays");
        // Resent unchanged (every override is resent when any is set):
        // the same state, still ageing.
        for (int i = 0; i < 80; ++i)
            p.step(idle);
        expect(p.step(in).shown, "a draw once it is over by its clock, through resends");
        auto other = frame(false);
        other.server = idle.server;
        auto out = p.step(other);
        expect(out.shown && out.phase == 1 && std::fabs(out.t) < 0.03f,
                "a short tap strikes from near the start, the stale stroke not taken as the answer");
        other.server = server(4, 1, 0, 0.0f);
        other.server.family = 2;
        out = p.step(other);
        expect(!out.shown, "an answer of another family (a thrust) is the server's");
    }
    {
        StrokePreview p;
        p.step(frame(false));
        p.step(frame(true));
        auto in = frame(true);
        in.place = true;
        expect(!p.step(in).shown, "the guard cancels the local draw");
        p.step(frame(false));
        in = frame(true);
        in.open = false;
        expect(!p.step(in).shown, "a press on a node is a dig, not a draw");
        p.step(frame(false));
        p.step(frame(true));
        in = frame(true);
        in.digging = true;
        expect(!p.step(in).shown, "the client digging ends the draw");
    }
    {
        // The server never saw the first hold: its first strike answers
        // the second, and a third press after that stroke's length draws.
        StrokePreview p;
        auto at = [&](bool dig, const StrokeServerState &s, int frames) {
            StrokePreview::Out o;
            for (int i = 0; i < frames; ++i) {
                auto in = frame(dig);
                in.server = s;
                o = p.step(in);
            }
            return o;
        };
        StrokeServerState none;
        at(true, none, 30);
        at(false, none, 150);
        at(true, none, 20);
        at(true, server(0, 3, 0, 0.1f), 10);
        at(false, server(0, 3, 0, 0.1f), 60);
        auto out = at(false, server(1, 1, 0, 0.3f), 60);
        expect(out.shown && p.answered && p.answer == 1, "its strike is taken as the second press's answer");
        out = at(true, server(1, 1, 0, 0.3f), 1);
        expect(out.shown && out.phase == 3, "a press after a missed hold's successor draws");
    }
    {
        // A slow client: the renderer caps its step at 0.1 s of frames
        // 0.17 s long. The server's clock and the gate keep real time.
        StrokePreview p;
        auto slow = [](bool dig, const StrokeServerState &s) {
            auto in = frame(dig);
            in.dt = 0.1f;
            in.real_dt = 0.17f;
            in.server = s;
            return in;
        };
        StrokeServerState none;
        p.step(slow(false, none));
        for (int i = 0; i < 3; ++i)
            p.step(slow(true, none));
        auto out = p.step(slow(false, none));
        expect(out.shown && std::fabs(out.t - 0.51f * 0.5f / 0.8f) < 1e-3f, "the strike starts from the real draw");
        for (int i = 0; i < 12; ++i)
            out = p.step(slow(false, server(1, 1, 0, 0.3f)));
        out = p.step(slow(true, server(1, 1, 0, 0.3f)));
        expect(out.shown && out.phase == 3, "a press 2.2 s after the release draws on a slow client");
    }
    {
        StrokePreview p;
        p.step(frame(false));
        p.step(frame(true));
        auto out = p.step(frame(false));
        for (int i = 0; i < 300; ++i)
            out = p.step(frame(false));
        expect(!out.shown && !p.active(), "an unanswered stroke is let go");
    }
}

int main(int argc, char **argv) {
    checkPreview();
    if (argc > 2 && std::string(argv[1]) == "--response-only") {
        Json::Value cases;
        expect(readJson(argv[2], cases), "Lua response fixture parses");
        for (const auto &c : cases) {
            const float t = strokeResponseTime(c["phase"].asInt(), c["contact"].asFloat(),
                    c["age"].asFloat(), c["length"].asFloat());
            expect(std::fabs(t - c["value"].asFloat()) < 1e-6f, "native recovery agrees with Lua");
        }
        std::printf("goanna_strokes_test: %d response/anticipation checks, %d failures\n", g_checks, g_failures);
        return g_failures ? 1 : 0;
    }
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

    // The state's format and weapon family (DorfCraft's strike.lua).
    expect(decodeStrokeFormat(1.0f).format == 1 && decodeStrokeFormat(1.0f).family == 0, "z 1 is a sword stroke");
    expect(decodeStrokeFormat(9.0f).format == 1 && decodeStrokeFormat(9.0f).family == 1,
            "z 9 is a stroke of family 1");
    expect(decodeStrokeFormat(17.0f).family == 2, "z 17 is family 2");
    expect(decodeStrokeFormat(2.0f).format == 2 && decodeStrokeFormat(2.0f).family == 0, "z 2 is a task");
    expect(decodeStrokeFormat(4.0f).format == 4, "z 4 is a flier");
    expect(decodeStrokeFormat(0.0f).format == 0, "z 0 is nothing");
    // A weapon family: the same strokes with its own weapon.
    {
        Json::Value root;
        Json::CharReaderBuilder builder;
        std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
        std::string errors;
        expect(reader->parse(text.data(), text.data() + text.size(), &root, &errors), "family JSON parses");
        root["weapon"]["tip"][1] = 17;
        root["weapon"]["edge"]["from"] = Json::Value(Json::arrayValue);
        for (double v : {0.0, 12.0, 0.0})
            root["weapon"]["edge"]["from"].append(v);
        StrokeFamily axe;
        expect(parseStrokeFamily(root, axe), "a family with its own weapon parses");
        expect(std::fabs(axe.tip[1] - 17) < 1e-9 && std::fabs(axe.hilt[1] - family->hilt[1]) < 1e-9,
                "the family's own weapon is read");
    }

    checkBody(dir + "/reference.json", family);
    if (argc < 3 || std::string(argv[2]) != "--reference-only")
        checkBody(dir + "/tentacle_arms.json", family);

    if (g_failures) {
        std::cerr << "goanna_strokes_test: " << g_failures << " of " << g_checks << " checks failed\n";
        return 1;
    }
    std::printf("goanna_strokes_test: all %d checks passed\n", g_checks);
    return 0;
}
