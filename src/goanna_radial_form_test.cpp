// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Sub node damage, v3, checked against the other implementation of it.
//
// The reference vectors this file loads are GENERATED, not authored here:
// `tools/dig-review/reference_v3.json` is `luajit
// tools/dig-review/generate_reference.lua > tools/dig-review/reference_v3.json`
// run against Kythen's own `mods/kythen/core/radial_form.lua` at commit
// 809475f (branch form/damage). Regenerate it from Kythen when the Lua
// changes; never hand edit it, and never hand edit the numbers below either.
// A difference here is a block that would change shape depending on which
// implementation drew it, and that is the one failure no screenshot of either
// half would show on its own.

#include "goanna_radial_form.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        std::printf("FAIL: %s\n", what.c_str());
        ++g_failures;
    }
}

bool near(float a, float b, float tol) { return std::fabs(a - b) <= tol; }

// ---------------------------------------------------------------------
// A minimal JSON reader for the one shape `generate_reference.lua` emits:
// numbers, strings, arrays, and objects with string keys. No library is
// linked into this target (see CMakeLists.txt's own comment on why), and a
// hand rolled reader for one fixed, generated shape is a lot less risk than
// vendoring a general one.
// ---------------------------------------------------------------------

struct Json {
    enum class Type { Null, Bool, Number, String, Array, Object } type = Type::Null;
    double num = 0;
    bool boolean = false;
    std::string str;
    std::vector<Json> arr;
    std::vector<std::pair<std::string, Json>> obj;

    const Json *get(const std::string &key) const {
        for (const auto &kv : obj) {
            if (kv.first == key) { return &kv.second; }
        }
        return nullptr;
    }
    double number(double def = 0.0) const { return type == Type::Number ? num : def; }
    // A control's stored value, or 0 if the control is absent (sparse tables
    // in the Lua omit anything at its default).
    float field(const char *key) const {
        const Json *v = get(key);
        return v ? static_cast<float>(v->num) : 0.0f;
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string &s) : s_(s) {}

    Json parse() {
        skipWs();
        Json v = parseValue();
        return v;
    }

private:
    const std::string &s_;
    size_t i_ = 0;

    void skipWs() {
        while (i_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[i_]))) { ++i_; }
    }

    Json parseValue() {
        skipWs();
        if (i_ >= s_.size()) { return Json(); }
        const char c = s_[i_];
        if (c == '{') { return parseObject(); }
        if (c == '[') { return parseArray(); }
        if (c == '"') { return parseString(); }
        if (c == 't') { i_ += 4; Json v; v.type = Json::Type::Bool; v.boolean = true; return v; }
        if (c == 'f') { i_ += 5; Json v; v.type = Json::Type::Bool; v.boolean = false; return v; }
        if (c == 'n') { i_ += 4; return Json(); }
        return parseNumber();
    }

    Json parseObject() {
        Json v; v.type = Json::Type::Object;
        ++i_; // {
        skipWs();
        if (i_ < s_.size() && s_[i_] == '}') { ++i_; return v; }
        for (;;) {
            skipWs();
            Json key = parseString();
            skipWs();
            ++i_; // :
            Json val = parseValue();
            v.obj.emplace_back(key.str, val);
            skipWs();
            if (i_ < s_.size() && s_[i_] == ',') { ++i_; continue; }
            break;
        }
        skipWs();
        if (i_ < s_.size() && s_[i_] == '}') { ++i_; }
        return v;
    }

    Json parseArray() {
        Json v; v.type = Json::Type::Array;
        ++i_; // [
        skipWs();
        if (i_ < s_.size() && s_[i_] == ']') { ++i_; return v; }
        for (;;) {
            Json val = parseValue();
            v.arr.push_back(val);
            skipWs();
            if (i_ < s_.size() && s_[i_] == ',') { ++i_; continue; }
            break;
        }
        skipWs();
        if (i_ < s_.size() && s_[i_] == ']') { ++i_; }
        return v;
    }

    Json parseString() {
        Json v; v.type = Json::Type::String;
        ++i_; // "
        std::string out;
        while (i_ < s_.size() && s_[i_] != '"') {
            if (s_[i_] == '\\' && i_ + 1 < s_.size()) {
                ++i_;
                out.push_back(s_[i_]);
            } else {
                out.push_back(s_[i_]);
            }
            ++i_;
        }
        ++i_; // closing "
        v.str = out;
        return v;
    }

    Json parseNumber() {
        const size_t start = i_;
        if (i_ < s_.size() && (s_[i_] == '-' || s_[i_] == '+')) { ++i_; }
        while (i_ < s_.size() && (std::isdigit(static_cast<unsigned char>(s_[i_])) ||
                s_[i_] == '.' || s_[i_] == 'e' || s_[i_] == 'E' || s_[i_] == '+' || s_[i_] == '-')) {
            ++i_;
        }
        Json v; v.type = Json::Type::Number;
        v.num = std::stod(s_.substr(start, i_ - start));
        return v;
    }
};

std::string readFile(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

std::string toHex(const std::string &bytes) {
    std::string out;
    char buf[3];
    for (unsigned char ch : bytes) {
        std::snprintf(buf, sizeof(buf), "%02x", ch);
        out += buf;
    }
    return out;
}

// ---------------------------------------------------------------------
// The reference driven checks. Each of `radial_form.lua`'s own dependency
// order is checked in the order `generate_reference.lua`'s header states:
// centroid and present position, then strike (both operators), then
// connectivity, then stage, then the wire codec.
// ---------------------------------------------------------------------

void checkCase(const Json &c) {
    const std::string name = c.get("name")->str;
    const std::string metricName = c.get("metric")->str;
    const int resolution = static_cast<int>(c.get("resolution")->number());

    RadialForm form;
    const Json *origin = c.get("origin");
    form.origin[0] = static_cast<float>(origin->arr[0].num);
    form.origin[1] = static_cast<float>(origin->arr[1].num);
    form.origin[2] = static_cast<float>(origin->arr[2].num);
    const Json *box = c.get("box");
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const Json *v = box->get(controlKey(i));
        form.box[i] = v ? static_cast<float>(v->num) : 1.0f;
    }

    const FormBaseline baseline = formBaseline(form);
    const Json *centroid = c.get("centroid");
    char what[256];
    std::snprintf(what, sizeof(what), "%s: centroid.x", name.c_str());
    check(near(baseline.centre[0], static_cast<float>(centroid->arr[0].num), 2e-4f), what);
    std::snprintf(what, sizeof(what), "%s: centroid.y", name.c_str());
    check(near(baseline.centre[1], static_cast<float>(centroid->arr[1].num), 2e-4f), what);
    std::snprintf(what, sizeof(what), "%s: centroid.z", name.c_str());
    check(near(baseline.centre[2], static_cast<float>(centroid->arr[2].num), 2e-4f), what);

    const Json *present = c.get("present");
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const Json *v = present->get(controlKey(i));
        std::snprintf(what, sizeof(what), "%s: present.%s", name.c_str(), controlKey(i));
        check(v != nullptr && near(baseline.present[i], static_cast<float>(v->num), 2e-4f), what);
    }

    const auto baseSolid = [&form](float x, float y, float z) { return formSolid(form, x, y, z); };
    const float pristineVolume = formVolume(form, resolution);

    FormDamage damage;
    damage.resolution = resolution;
    damage.metric = metricName == "cube" ? FormMetric::Cube : FormMetric::Sphere;

    const Json *strikes = c.get("strikes");
    for (size_t s = 0; s < strikes->arr.size(); ++s) {
        const Json &strike = strikes->arr[s];
        const Json *hit = strike.get("hit");
        const Json *normal = strike.get("normal");
        const float depth = static_cast<float>(strike.get("depth")->number());
        damage = formStrike(baseline, damage,
                static_cast<float>(hit->arr[0].num), static_cast<float>(hit->arr[1].num),
                static_cast<float>(hit->arr[2].num), depth,
                static_cast<float>(normal->arr[0].num), static_cast<float>(normal->arr[1].num),
                static_cast<float>(normal->arr[2].num));

        const Json *wantDelta = strike.get("delta");
        const Json *wantCrater = strike.get("crater");
        for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
            const Json *dv = wantDelta->get(controlKey(i));
            const float want = dv ? static_cast<float>(dv->num) : 0.0f;
            std::snprintf(what, sizeof(what), "%s strike %zu: delta.%s", name.c_str(), s, controlKey(i));
            check(near(damage.delta[i], want, 5e-4f), what);
            const Json *cv = wantCrater->get(controlKey(i));
            const float wantC = cv ? static_cast<float>(cv->num) : 0.0f;
            std::snprintf(what, sizeof(what), "%s strike %zu: crater.%s", name.c_str(), s, controlKey(i));
            check(near(damage.crater[i], wantC, 5e-4f), what);
        }

        // Connected occupancy: exact match, cell for cell, in the SAME nested
        // k, j, i order `generate_reference.lua`'s own `grid_cells` walks, so
        // this checks position, not just count.
        const std::vector<bool> grid = formGridDamaged(baseSolid, baseline, damage, resolution);
        std::vector<std::array<int, 3>> gotCells;
        for (int k = 0; k < resolution; ++k) {
            for (int j = 0; j < resolution; ++j) {
                for (int i = 0; i < resolution; ++i) {
                    if (grid[static_cast<size_t>(k) * resolution * resolution
                            + static_cast<size_t>(j) * resolution + i]) {
                        gotCells.push_back({i, j, k});
                    }
                }
            }
        }
        const Json *wantCells = strike.get("cells");
        std::snprintf(what, sizeof(what), "%s strike %zu: cell count", name.c_str(), s);
        check(gotCells.size() == wantCells->arr.size(), what);
        const size_t n = std::min(gotCells.size(), wantCells->arr.size());
        for (size_t ci = 0; ci < n; ++ci) {
            const Json &wc = wantCells->arr[ci];
            const bool match = gotCells[ci][0] == static_cast<int>(wc.arr[0].num)
                    && gotCells[ci][1] == static_cast<int>(wc.arr[1].num)
                    && gotCells[ci][2] == static_cast<int>(wc.arr[2].num);
            std::snprintf(what, sizeof(what), "%s strike %zu: cell #%zu occupancy", name.c_str(), s, ci);
            check(match, what);
        }

        size_t solidCount = 0;
        for (bool v : grid) { if (v) { ++solidCount; } }
        const float volume = static_cast<float>(solidCount) / static_cast<float>(grid.size());
        std::snprintf(what, sizeof(what), "%s strike %zu: volume", name.c_str(), s);
        check(near(volume, static_cast<float>(strike.get("volume")->number()), 1e-4f), what);

        const int stage = formStage(!damage.empty(), pristineVolume, volume);
        std::snprintf(what, sizeof(what), "%s strike %zu: stage", name.c_str(), s);
        check(stage == static_cast<int>(strike.get("stage")->number()), what);

        const std::string encoded = encodeForm(damage);
        const std::string hex = toHex(encoded);
        std::snprintf(what, sizeof(what), "%s strike %zu: encoded length", name.c_str(), s);
        check(static_cast<int>(encoded.size()) == static_cast<int>(strike.get("encoded_length")->number()), what);
        std::snprintf(what, sizeof(what), "%s strike %zu: encoded bytes", name.c_str(), s);
        check(hex == strike.get("encoded_hex")->str, what);
        if (hex != strike.get("encoded_hex")->str) {
            std::printf("      got  %s\n      want %s\n", hex.c_str(), strike.get("encoded_hex")->str.c_str());
        }
    }
}

void testAgainstReference(const std::string &path) {
    const std::string text = readFile(path);
    check(!text.empty(), "reference_v3.json is readable (run from the repository root)");
    if (text.empty()) { return; }
    JsonParser parser(text);
    const Json root = parser.parse();
    check(static_cast<int>(root.get("format")->number()) == 4, "reference is format 4");
    const Json *cases = root.get("cases");
    check(cases != nullptr && !cases->arr.empty(), "reference has cases");
    if (!cases) { return; }
    for (const Json &c : cases->arr) { checkCase(c); }
    std::printf("goanna_radial_form_test: %zu reference cases checked\n", cases->arr.size());
}

// ---------------------------------------------------------------------
// Focused checks the reference vectors do not exercise directly: the
// nodebox base shape path the mesher uses, the wire codec's pristine and
// round trip cases, and that formSurfaces still emits exactly one owner per
// exposed quad on a damaged grid.
// ---------------------------------------------------------------------

void testBoxesBaseline() {
    // A half height slab, floor to mid height: present position straight up
    // is a quarter node from the slab's own centroid, not the node's.
    std::vector<FormBox> boxes = {{-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f}};
    const FormBaseline b = formBaselineFromBoxes(boxes);
    check(near(b.centre[1], -0.25f, 1e-3f), "boxes: slab centroid sits at its own mid height");
    const int yp = controlIndexForKey("yp");
    check(near(b.present[yp], 0.25f, 1e-3f), "boxes: slab's own top is a quarter node from its centroid");
    const int yn = controlIndexForKey("yn");
    check(near(b.present[yn], 0.25f, 1e-3f), "boxes: slab's own floor is a quarter node the other way");
    const int xp = controlIndexForKey("xp");
    check(near(b.present[xp], 0.5f, 1e-3f), "boxes: full width sides reach the node's own wall");
}

void testCubeBaselineMatchesBoxesBaseline() {
    // A plain cube expressed as one full size box must agree with the closed
    // form cube baseline the mesher uses for NDT_NORMAL nodes, since a
    // nodebox that happens to describe a whole cube is exactly that.
    std::vector<FormBox> boxes = {{-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f}};
    const FormBaseline fromBoxes = formBaselineFromBoxes(boxes);
    const FormBaseline cube = formBaselineForCube();
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        char what[128];
        std::snprintf(what, sizeof(what), "cube-as-boxes present.%s matches the closed form", controlKey(i));
        check(near(fromBoxes.present[i], cube.present[i], 2e-3f), what);
    }
}

void testCodecPristineAndRoundTrip() {
    check(encodeForm(FormDamage()).empty(), "a pristine node encodes to nothing");
    check(decodeForm("").empty(), "empty bytes decode as pristine");
    check(decodeForm("rubbish").empty(), "unrecognised bytes decode as pristine, not an error");
    check(decodeForm(std::string(1, '\x01')).empty(), "a v1 string (old version byte) decodes as pristine");

    const FormBaseline baseline = formBaselineForCube();
    FormDamage damage;
    damage.resolution = 8;
    damage.metric = FormMetric::Sphere;
    for (int i = 0; i < 6; ++i) {
        damage = formStrike(baseline, damage, 0.0f, 0.5f, 0.0f, 0.15f, 0.0f, 1.0f, 0.0f);
    }
    check(!damage.empty(), "six blows leave stored damage");
    const std::string bytes = encodeForm(damage);
    const FormDamage back = decodeForm(bytes);
    check(back.resolution == damage.resolution, "round trip keeps resolution");
    check(back.metric == damage.metric, "round trip keeps metric");
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        char what[96];
        std::snprintf(what, sizeof(what), "round trip keeps delta.%s to a byte", controlKey(i));
        check(near(back.delta[i], damage.delta[i], 1.0f / 255.0f + 1e-6f), what);
        std::snprintf(what, sizeof(what), "round trip keeps crater.%s to a byte", controlKey(i));
        check(near(back.crater[i], damage.crater[i], 1.0f / 255.0f + 1e-6f), what);
    }
}

void testSurfaceCoverageOnADamagedCube() {
    // Every emitted rectangle rasterised back onto the oriented unit face
    // lattice must cover each exposed interface exactly once. Unchanged from
    // v1's own check of `formSurfaces`, fed a v3 damaged grid instead of a
    // v1 displacement grid: `formSurfaces` itself never changed.
    constexpr int n = 8;
    const FormBaseline baseline = formBaselineForCube();
    FormDamage damage;
    damage.resolution = n;
    damage.metric = FormMetric::Sphere;
    damage = formStrike(baseline, damage, 0.0f, 0.5f, 0.0f, 0.3f, 0.0f, 1.0f, 0.0f);
    const auto baseSolid = [](float, float, float) { return true; };
    const std::vector<bool> grid = formGridDamaged(baseSolid, baseline, damage, n);

    const int axes[6] = {1, 1, 0, 0, 2, 2};
    for (int mask = 0; mask < 64; ++mask) {
        std::vector<int> expected(6 * (n + 1) * n * n, 0), actual(expected.size(), 0);
        auto idx = [&](int f, int layer, int u, int v) { return ((f * (n + 1) + layer) * n + v) * n + u; };
        auto solid = [&](const int p[3]) { return grid[p[2] * n * n + p[1] * n + p[0]]; };
        for (int f = 0; f < 6; ++f) {
            const int a = axes[f], u = (a + 1) % 3, v = (a + 2) % 3, sign = (f & 1) ? -1 : 1;
            for (int z = 0; z < n; ++z) {
                for (int y = 0; y < n; ++y) {
                    for (int x = 0; x < n; ++x) {
                        int p[3] = {x, y, z};
                        const bool here = solid(p);
                        const int layer = p[a] + (sign > 0 ? 1 : 0), i = p[u], j = p[v];
                        p[a] += sign;
                        const bool boundary = p[a] < 0 || p[a] >= n;
                        if (!boundary) {
                            if (here && !solid(p)) { ++expected[idx(f, layer, i, j)]; }
                        } else if (mask & (1 << f)) {
                            if (here) { ++expected[idx(f, layer, i, j)]; }
                        } else if (!here) {
                            ++expected[idx(f ^ 1, layer, i, j)];
                        }
                    }
                }
            }
        }
        const auto quads = formSurfaces(grid, n, static_cast<uint8_t>(mask), static_cast<uint8_t>(63 ^ mask));
        for (const auto &q : quads) {
            const int a = axes[q.face], u = (a + 1) % 3, v = (a + 2) % 3;
            const float lo[3] = {q.box.x1, q.box.y1, q.box.z1}, hi[3] = {q.box.x2, q.box.y2, q.box.z2};
            check(lo[a] == hi[a], "surface is a plane, not overlapping cuboids");
            const int layer = std::lround((lo[a] + 0.5f) * n);
            for (int j = std::lround((lo[v] + 0.5f) * n); j < std::lround((hi[v] + 0.5f) * n); ++j) {
                for (int i = std::lround((lo[u] + 0.5f) * n); i < std::lround((hi[u] + 0.5f) * n); ++i) {
                    ++actual[idx(q.face, layer, i, j)];
                }
            }
            if (q.backing >= 0) { check(q.face == (q.backing ^ 1), "revealed neighbour faces into the cut"); }
        }
        check(actual == expected, "every surface and neighbour reveal has exactly one owner");
    }
}

} // namespace

int main(int argc, char **argv) {
    const std::string path = argc >= 2 ? argv[1] : "tools/dig-review/reference_v3.json";
    testAgainstReference(path);
    testBoxesBaseline();
    testCubeBaselineMatchesBoxesBaseline();
    testCodecPristineAndRoundTrip();
    testSurfaceCoverageOnADamagedCube();

    std::printf("%d checks, %d failure(s)\n", g_checks, g_failures);
    if (g_failures != 0) { return 1; }
    std::printf("goanna_radial_form_test: all checks passed\n");
    return 0;
}
