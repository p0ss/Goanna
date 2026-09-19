// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_radial_form.h"

#include "goanna_mesh_flags.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <tuple>

// Defined here rather than in the transplanted mesher, unlike g_goanna_bevel:
// this is Goanna's own state and there is no reason to put it in upstream code.
const goanna::FormDamage *g_goanna_carve = nullptr;
// Legacy environment value: positive enables carving, zero disables it.
float g_goanna_carve_depth = 0.12f;
int g_goanna_carve_demo = 0;
int g_goanna_carve_demo_z = 0;

namespace goanna {

namespace {

constexpr float kR3 = 0.57735026918962576451f; // 1 / sqrt(3)
constexpr float kR2 = 0.70710678118654752440f; // 1 / sqrt(2)

// Native control order, matching `radial_form.lua`'s `M.PLANES` wire order
// exactly: six faces, THEN eight corners, THEN twelve edges. See the header
// comment on `FORM_PLANE_COUNT` for why this order is load bearing.
const float kControlDir[FORM_PLANE_COUNT][3] = {
    {-1.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f},
    {0.0f, -1.0f, 0.0f}, {0.0f, 1.0f, 0.0f},
    {0.0f, 0.0f, -1.0f}, {0.0f, 0.0f, 1.0f},
    {-kR3, -kR3, -kR3}, {-kR3, -kR3, kR3}, {-kR3, kR3, -kR3}, {-kR3, kR3, kR3},
    {kR3, -kR3, -kR3}, {kR3, -kR3, kR3}, {kR3, kR3, -kR3}, {kR3, kR3, kR3},
    {-kR2, -kR2, 0.0f}, {-kR2, kR2, 0.0f}, {kR2, -kR2, 0.0f}, {kR2, kR2, 0.0f},
    {-kR2, 0.0f, -kR2}, {-kR2, 0.0f, kR2}, {kR2, 0.0f, -kR2}, {kR2, 0.0f, kR2},
    {0.0f, -kR2, -kR2}, {0.0f, -kR2, kR2}, {0.0f, kR2, -kR2}, {0.0f, kR2, kR2},
};

const char *const kControlKeyTable[FORM_PLANE_COUNT] = {
    "xn", "xp", "yn", "yp", "zn", "zp",
    "nnn", "nnp", "npn", "npp", "pnn", "pnp", "ppn", "ppp",
    "xnyn", "xnyp", "xpyn", "xpyp", "xnzn", "xnzp", "xpzn", "xpzp",
    "ynzn", "ynzp", "ypzn", "ypzp",
};

// Which pair of face controls, dug through, opens a bore along that axis.
constexpr int kBorePairLo[3] = {0, 2, 4};
constexpr int kBorePairHi[3] = {1, 3, 5};

constexpr float kR3b = 0.57735026918962576451f;
const float kBoreAxis[FORM_BORE_COUNT][3] = {
    {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f},
    {kR2, kR2, 0.0f}, {kR2, -kR2, 0.0f},
    {kR2, 0.0f, kR2}, {kR2, 0.0f, -kR2},
    {0.0f, kR2, kR2}, {0.0f, kR2, -kR2},
    {kR3b, kR3b, kR3b}, {kR3b, kR3b, -kR3b},
    {kR3b, -kR3b, kR3b}, {kR3b, -kR3b, -kR3b},
};

// How far the node's own boundary is from the origin along u: the support
// distance. It is what makes an offset of 1 mean "touches the node and cuts
// nothing", and what each carve slice is seeded at. Matches
// `radial_form.lua`'s `support` exactly.
float support(const float origin[3], float ux, float uy, float uz) {
    auto axis = [](float u, float o) {
        const float a = u * (0.5f - o);
        const float b = u * (-0.5f - o);
        return a > b ? a : b;
    };
    return axis(ux, origin[0]) + axis(uy, origin[1]) + axis(uz, origin[2]);
}

// How fast each axis's constraint relaxes off its own direction: `r / dot^POWER`.
// Matches the Lua's `POWER` and `DAMAGE_POWER` (the same value; see the Lua's
// own comment on why they were unified).
constexpr int kPower = 12;

bool insideBox(const RadialForm &form, float vx, float vy, float vz) {
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (form.box[i] >= 1.0f) { continue; }
        const float wall = form.box[i] * support(form.origin, kControlDir[i][0],
                kControlDir[i][1], kControlDir[i][2]);
        if (vx * kControlDir[i][0] + vy * kControlDir[i][1] + vz * kControlDir[i][2]
                > wall + 1e-9f) {
            return false;
        }
    }
    return true;
}

float radiusAt(const RadialForm &form, float dx, float dy, float dz) {
    float best = 1e30f;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const float dot = dx * kControlDir[i][0] + dy * kControlDir[i][1] + dz * kControlDir[i][2];
        if (dot <= 1e-6f) { continue; }
        const float reach = form.box[i] * support(form.origin, kControlDir[i][0],
                kControlDir[i][1], kControlDir[i][2]);
        const float r = (form.extents[i] >= 0.0f) ? form.extents[i] : reach;
        float w = dot;
        for (int p = 1; p < kPower; ++p) { w *= dot; }
        const float bound = r / w;
        if (bound < best) { best = bound; }
    }
    return best;
}

float clamp01(float v) {
    if (v < 0.0f) { return 0.0f; }
    if (v > 1.0f) { return 1.0f; }
    return v;
}

// Shared march-and-bisect for one control direction, generic over any
// solidity predicate. Matches `radial_form.lua`'s `M.baseline` march exactly:
// steps of a tenth outward from the centre, capped at the node's own physical
// cube, then twenty two bisections (better than 1e-6 of a node).
float marchAndBisect(const std::function<bool(float, float, float)> &solid,
        float cx, float cy, float cz, float dx, float dy, float dz) {
    auto withinCube = [](float px, float py, float pz) {
        return px >= -0.5f - 1e-9f && px <= 0.5f + 1e-9f
            && py >= -0.5f - 1e-9f && py <= 0.5f + 1e-9f
            && pz >= -0.5f - 1e-9f && pz <= 0.5f + 1e-9f;
    };
    auto solidAt = [&](float t) {
        const float px = cx + dx * t, py = cy + dy * t, pz = cz + dz * t;
        return withinCube(px, py, pz) && solid(px, py, pz);
    };
    float hi = 0.0f;
    while (hi < 1.6f && solidAt(hi)) { hi += 0.1f; }
    float lo = hi - 0.1f;
    if (lo < 0.0f) { lo = 0.0f; }
    for (int i = 0; i < 22; ++i) {
        const float mid = (lo + hi) * 0.5f;
        if (solidAt(mid)) { lo = mid; } else { hi = mid; }
    }
    return lo;
}

// Centroid plus present position for an arbitrary base shape. Matches
// `radial_form.lua`'s `M.centroid` (resolution 16 grid average) and the
// general branch of `M.baseline`.
FormBaseline computeBaseline(const std::function<bool(float, float, float)> &solid) {
    constexpr int n = 16;
    double sx = 0, sy = 0, sz = 0;
    int count = 0;
    for (int k = 0; k < n; ++k) {
        const float pz = (static_cast<float>(k) + 0.5f) / n - 0.5f;
        for (int j = 0; j < n; ++j) {
            const float py = (static_cast<float>(j) + 0.5f) / n - 0.5f;
            for (int i = 0; i < n; ++i) {
                const float px = (static_cast<float>(i) + 0.5f) / n - 0.5f;
                if (solid(px, py, pz)) {
                    sx += px; sy += py; sz += pz;
                    ++count;
                }
            }
        }
    }
    FormBaseline out;
    if (count > 0) {
        out.centre[0] = static_cast<float>(sx / count);
        out.centre[1] = static_cast<float>(sy / count);
        out.centre[2] = static_cast<float>(sz / count);
    }
    for (int c = 0; c < FORM_PLANE_COUNT; ++c) {
        out.present[c] = marchAndBisect(solid, out.centre[0], out.centre[1], out.centre[2],
                kControlDir[c][0], kControlDir[c][1], kControlDir[c][2]);
    }
    return out;
}

// Is this point inside a crater centred on control `key`'s current surface
// point? Matches `radial_form.lua`'s `in_crater`.
bool inCrater(const FormBaseline &baseline, const FormDamage &damage, int key,
        FormMetric metric, float px, float py, float pz) {
    const float radius = damage.crater[key];
    if (radius <= 0.0f) { return false; }
    const float r = baseline.present[key] * (1.0f - damage.delta[key]);
    const float cx = baseline.centre[0] + kControlDir[key][0] * r;
    const float cy = baseline.centre[1] + kControlDir[key][1] * r;
    const float cz = baseline.centre[2] + kControlDir[key][2] * r;
    const float dx = px - cx, dy = py - cy, dz = pz - cz;
    if (metric == FormMetric::Cube) {
        return std::max({std::fabs(dx), std::fabs(dy), std::fabs(dz)}) <= radius;
    }
    return dx * dx + dy * dy + dz * dz <= radius * radius;
}

// The current radius toward a unit direction, given present position and
// stored delta: the same tightest-wins blend `radiusAt` uses for an authored
// carve, over `present * (1 - delta)`. A saturated control is floored, not
// zeroed (see `radial_form.lua`'s comment on `damaged_radius`): at r = 0 the
// bound `0 / dot^POWER` is zero for every direction with dot > 0, which
// poisons the whole hemisphere the control faces instead of a narrow cone.
float damagedRadius(const FormBaseline &baseline, const FormDamage &damage,
        float dx, float dy, float dz) {
    float best = 1e30f;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const float dot = dx * kControlDir[i][0] + dy * kControlDir[i][1] + dz * kControlDir[i][2];
        if (dot <= 1e-6f) { continue; }
        float r = baseline.present[i] * (1.0f - damage.delta[i]);
        if (r < 1e-4f) { r = 1e-4f; }
        float w = dot;
        for (int p = 1; p < kPower; ++p) { w *= dot; }
        const float bound = r / w;
        if (bound < best) { best = bound; }
    }
    return best;
}

uint8_t resolutionCode(int resolution) {
    switch (resolution) {
        case 2: return 0;
        case 4: return 1;
        case 16: return 3;
        default: return 2; // 8, and anything unrecognised
    }
}

int resolutionFromCode(uint8_t code) {
    switch (code & 0x3) {
        case 0: return 2;
        case 1: return 4;
        case 3: return 16;
        default: return 8;
    }
}

} // namespace

const int kFaceControl[6] = {0, 1, 2, 3, 4, 5};

const char *controlKey(int index) {
    if (index < 0 || index >= FORM_PLANE_COUNT) { return ""; }
    return kControlKeyTable[index];
}

int controlIndexForKey(const std::string &key) {
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (key == kControlKeyTable[i]) { return i; }
    }
    return -1;
}

bool pointInBoxes(const std::vector<FormBox> &boxes, float px, float py, float pz) {
    for (const FormBox &b : boxes) {
        if (px >= b.x1 - 1e-7f && px <= b.x2 + 1e-7f
                && py >= b.y1 - 1e-7f && py <= b.y2 + 1e-7f
                && pz >= b.z1 - 1e-7f && pz <= b.z2 + 1e-7f) {
            return true;
        }
    }
    return false;
}

bool formSolid(const RadialForm &form, float px, float py, float pz) {
    const float vx = px - form.origin[0];
    const float vy = py - form.origin[1];
    const float vz = pz - form.origin[2];

    // Bored out along any axis and the point is gone, whatever the box and
    // radius decided. First, before the origin short circuit below: the
    // origin lies on every bore axis, so it is the one point every hole
    // certainly removes.
    for (int a = 0; a < FORM_BORE_COUNT; ++a) {
        const float r = form.bore[a];
        if (r <= 0.0f) { continue; }
        const float along = vx * kBoreAxis[a][0] + vy * kBoreAxis[a][1] + vz * kBoreAxis[a][2];
        const float qx = vx - along * kBoreAxis[a][0];
        const float qy = vy - along * kBoreAxis[a][1];
        const float qz = vz - along * kBoreAxis[a][2];
        if (qx * qx + qy * qy + qz * qz <= r * r + 1e-9f) { return false; }
    }

    if (!insideBox(form, vx, vy, vz)) { return false; }

    const float len = std::sqrt(vx * vx + vy * vy + vz * vz);
    if (len < 1e-9f) { return true; }
    return len <= radiusAt(form, vx / len, vy / len, vz / len) + 1e-9f;
}

std::vector<bool> formGrid(const RadialForm &form, int resolution) {
    const int n = resolution > 0 ? resolution : 8;
    std::vector<bool> g(static_cast<size_t>(n) * n * n, false);
    for (int k = 0; k < n; ++k) {
        const float pz = (static_cast<float>(k) + 0.5f) / n - 0.5f;
        for (int j = 0; j < n; ++j) {
            const float py = (static_cast<float>(j) + 0.5f) / n - 0.5f;
            for (int i = 0; i < n; ++i) {
                const float px = (static_cast<float>(i) + 0.5f) / n - 0.5f;
                g[static_cast<size_t>(k) * n * n + static_cast<size_t>(j) * n + i]
                    = formSolid(form, px, py, pz);
            }
        }
    }
    return g;
}

float formVolume(const RadialForm &form, int resolution) {
    const std::vector<bool> g = formGrid(form, resolution);
    size_t solid = 0;
    for (bool v : g) { if (v) { ++solid; } }
    return g.empty() ? 0.0f : static_cast<float>(solid) / static_cast<float>(g.size());
}

std::vector<FormBox> formBoxes(const RadialForm &form, int resolution) {
    const int n = resolution > 0 ? resolution : 8;
    const std::vector<bool> g = formGrid(form, n);
    std::vector<bool> used(g.size(), false);

    auto index = [n](int i, int j, int k) {
        return static_cast<size_t>(k) * n * n + static_cast<size_t>(j) * n + i;
    };
    auto free = [&](int i, int j, int k) {
        if (i < 0 || j < 0 || k < 0 || i >= n || j >= n || k >= n) { return false; }
        const size_t at = index(i, j, k);
        return g[at] && !used[at];
    };

    std::vector<FormBox> out;
    for (int k = 0; k < n; ++k) {
        for (int j = 0; j < n; ++j) {
            for (int i = 0; i < n; ++i) {
                if (!free(i, j, k)) { continue; }
                int i2 = i;
                while (free(i2 + 1, j, k)) { ++i2; }
                int j2 = j;
                for (;;) {
                    bool ok = true;
                    for (int x = i; x <= i2 && ok; ++x) {
                        if (!free(x, j2 + 1, k)) { ok = false; }
                    }
                    if (!ok) { break; }
                    ++j2;
                }
                int k2 = k;
                for (;;) {
                    bool ok = true;
                    for (int y = j; y <= j2 && ok; ++y) {
                        for (int x = i; x <= i2 && ok; ++x) {
                            if (!free(x, y, k2 + 1)) { ok = false; }
                        }
                    }
                    if (!ok) { break; }
                    ++k2;
                }
                for (int z = k; z <= k2; ++z) {
                    for (int y = j; y <= j2; ++y) {
                        for (int x = i; x <= i2; ++x) { used[index(x, y, z)] = true; }
                    }
                }
                FormBox b;
                b.x1 = static_cast<float>(i) / n - 0.5f;
                b.y1 = static_cast<float>(j) / n - 0.5f;
                b.z1 = static_cast<float>(k) / n - 0.5f;
                b.x2 = static_cast<float>(i2 + 1) / n - 0.5f;
                b.y2 = static_cast<float>(j2 + 1) / n - 0.5f;
                b.z2 = static_cast<float>(k2 + 1) / n - 0.5f;
                out.push_back(b);
            }
        }
    }
    return out;
}

FormBaseline formBaseline(const RadialForm &form) {
    bool full = true;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (form.box[i] < 1.0f || form.extents[i] >= 0.0f) { full = false; break; }
    }
    bool noBore = true;
    if (full) {
        for (int a = 0; a < FORM_BORE_COUNT; ++a) {
            if (form.bore[a] > 0.0f) { noBore = false; break; }
        }
    }
    if (full && noBore) {
        // Closed form: centred at the origin, a face is a half node away, an
        // edge 1/sqrt(2) of a half, a corner 1/sqrt(3) of a half: exactly
        // `support` at the origin.
        FormBaseline out;
        out.centre[0] = form.origin[0];
        out.centre[1] = form.origin[1];
        out.centre[2] = form.origin[2];
        for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
            out.present[i] = support(form.origin, kControlDir[i][0], kControlDir[i][1], kControlDir[i][2]);
        }
        return out;
    }
    return computeBaseline([&form](float x, float y, float z) { return formSolid(form, x, y, z); });
}

FormBaseline formBaselineFromBoxes(const std::vector<FormBox> &boxes) {
    return computeBaseline([&boxes](float x, float y, float z) { return pointInBoxes(boxes, x, y, z); });
}

FormBaseline formBaselineForCube() {
    FormBaseline out;
    const float origin[3] = {0.0f, 0.0f, 0.0f};
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        out.present[i] = support(origin, kControlDir[i][0], kControlDir[i][1], kControlDir[i][2]);
    }
    return out;
}

float formReferencePresent(const FormBaseline &baseline, float nx, float ny, float nz) {
    float best = 0.0f, bestDot = -1e30f;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const float dot = nx * kControlDir[i][0] + ny * kControlDir[i][1] + nz * kControlDir[i][2];
        if (dot > bestDot) {
            bestDot = dot;
            best = baseline.present[i];
        }
    }
    return best;
}

FormDamage formStrike(const FormBaseline &baseline, FormDamage damage,
        float px, float py, float pz, float depth, float nx, float ny, float nz) {
    if (!(depth > 0.0f) || !std::isfinite(depth)) { return damage; }
    if (!std::isfinite(px) || !std::isfinite(py) || !std::isfinite(pz)) { return damage; }

    const float vx = px - baseline.centre[0];
    const float vy = py - baseline.centre[1];
    const float vz = pz - baseline.centre[2];
    const float len = std::sqrt(vx * vx + vy * vy + vz * vz);
    if (len < 1e-9f) { return damage; }
    const float hx = vx / len, hy = vy / len, hz = vz / len;

    float nxx = nx, nyy = ny, nzz = nz;
    if (!std::isfinite(nxx) || !std::isfinite(nyy) || !std::isfinite(nzz)
            || (nxx == 0.0f && nyy == 0.0f && nzz == 0.0f)) {
        nxx = hx; nyy = hy; nzz = hz;
    }

    const bool cubeMetric = damage.metric == FormMetric::Cube;
    const int poolCount = cubeMetric ? 6 : FORM_PLANE_COUNT;

    struct Candidate { int key; float d2; float dot; };
    std::vector<Candidate> candidates;
    candidates.reserve(poolCount);
    for (int p = 0; p < poolCount; ++p) {
        const int key = cubeMetric ? kFaceControl[p] : p;
        const float dot = nxx * kControlDir[key][0] + nyy * kControlDir[key][1] + nzz * kControlDir[key][2];
        const float quadrant = hx * kControlDir[key][0] + hy * kControlDir[key][1] + hz * kControlDir[key][2];
        const float pr = baseline.present[key];
        const bool spent = damage.delta[key] >= 0.999f && damage.crater[key] >= kCraterMax - 1e-6f;
        if (dot > 1e-6f && quadrant > 0.3f && pr > 1e-9f && !spent) {
            const float r = pr * (1.0f - damage.delta[key]);
            const float cx = baseline.centre[0] + kControlDir[key][0] * r - px;
            const float cy = baseline.centre[1] + kControlDir[key][1] * r - py;
            const float cz = baseline.centre[2] + kControlDir[key][2] * r - pz;
            candidates.push_back({key, cx * cx + cy * cy + cz * cz, dot});
        }
    }
    if (candidates.empty()) { return damage; }

    std::sort(candidates.begin(), candidates.end(),
            [](const Candidate &a, const Candidate &b) { return a.d2 < b.d2; });
    const size_t k = std::min<size_t>(4, candidates.size());

    // The control the hit is most about never loses its seat: the one most
    // aligned with the struck normal, whatever the distance ranking says (see
    // the header comment on `formStrike`, "dead centre rule").
    size_t primary = 0;
    for (size_t i = 1; i < candidates.size(); ++i) {
        if (candidates[i].dot > candidates[primary].dot) { primary = i; }
    }

    std::vector<size_t> selected(k);
    bool hasPrimary = false;
    for (size_t i = 0; i < k; ++i) {
        selected[i] = i;
        if (i == primary) { hasPrimary = true; }
    }
    if (!hasPrimary) {
        selected[selected.empty() ? 0 : selected.size() - 1] = primary;
    }

    float weights[FORM_PLANE_COUNT] = {};
    float wsum = 0.0f;
    for (size_t idx : selected) {
        const float w = 1.0f / (candidates[idx].d2 + 1e-6f);
        weights[candidates[idx].key] = w;
        wsum += w;
    }
    if (wsum <= 0.0f) { return damage; }

    constexpr float kCraterShare = 0.5f;
    for (size_t idx : selected) {
        const int key = candidates[idx].key;
        const float share = weights[key] / wsum;
        const float deltaInc = share * depth / baseline.present[key];
        const float craterInc = share * depth;
        damage.delta[key] = std::min(1.0f, damage.delta[key] + deltaInc * (1.0f - kCraterShare));
        damage.crater[key] = std::min(kCraterMax, damage.crater[key] + craterInc * kCraterShare);
    }
    return damage;
}

bool formDamageSolid(const FormBaseline &baseline, const FormDamage &damage,
        float px, float py, float pz) {
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (damage.crater[i] > 0.0f && inCrater(baseline, damage, i, damage.metric, px, py, pz)) {
            return false;
        }
    }
    const float vx = px - baseline.centre[0];
    const float vy = py - baseline.centre[1];
    const float vz = pz - baseline.centre[2];
    if (damage.metric == FormMetric::Cube) {
        auto lim = [&](int key, float sign) {
            const float p = baseline.present[key];
            if (p <= 0.0f) { return 1e30f; }
            return p * (1.0f - damage.delta[key]) * sign;
        };
        return vx >= lim(kFaceControl[0], -1.0f) && vx <= lim(kFaceControl[1], 1.0f)
            && vy >= lim(kFaceControl[2], -1.0f) && vy <= lim(kFaceControl[3], 1.0f)
            && vz >= lim(kFaceControl[4], -1.0f) && vz <= lim(kFaceControl[5], 1.0f);
    }
    const float len = std::sqrt(vx * vx + vy * vy + vz * vz);
    if (len < 1e-9f) { return true; }
    return len <= damagedRadius(baseline, damage, vx / len, vy / len, vz / len) + 1e-9f;
}

namespace {
int cellIndex(float v, int n) {
    int i = static_cast<int>(std::floor((v + 0.5f) * n));
    if (i < 0) { i = 0; }
    if (i > n - 1) { i = n - 1; }
    return i;
}
} // namespace

std::vector<bool> formConnected(const std::vector<bool> &grid, int n,
        float anchor_x, float anchor_y, float anchor_z) {
    if (n <= 0 || grid.size() != static_cast<size_t>(n) * n * n) { return grid; }
    auto solidAt = [&](int i, int j, int k) {
        return grid[static_cast<size_t>(k) * n * n + static_cast<size_t>(j) * n + i];
    };
    int ai = cellIndex(anchor_x, n), aj = cellIndex(anchor_y, n), ak = cellIndex(anchor_z, n);
    if (!solidAt(ai, aj, ak)) {
        int bestD2 = -1, bi = -1, bj = -1, bk = -1;
        for (int k = 0; k < n; ++k) {
            for (int j = 0; j < n; ++j) {
                for (int i = 0; i < n; ++i) {
                    if (!solidAt(i, j, k)) { continue; }
                    const int d2 = (i - ai) * (i - ai) + (j - aj) * (j - aj) + (k - ak) * (k - ak);
                    if (bestD2 < 0 || d2 < bestD2) { bestD2 = d2; bi = i; bj = j; bk = k; }
                }
            }
        }
        if (bi < 0) { return grid; } // nothing solid anywhere; nothing to connect
        ai = bi; aj = bj; ak = bk;
    }
    std::vector<bool> visited(grid.size(), false);
    auto key = [n](int i, int j, int k) { return (static_cast<size_t>(k) * n + j) * n + i; };
    std::vector<std::array<int, 3>> queue;
    queue.push_back({ai, aj, ak});
    visited[key(ai, aj, ak)] = true;
    static const int kNeighbours[6][3] = {
        {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
    };
    for (size_t qi = 0; qi < queue.size(); ++qi) {
        const int i = queue[qi][0], j = queue[qi][1], k = queue[qi][2];
        for (const auto &d : kNeighbours) {
            const int ni = i + d[0], nj = j + d[1], nk = k + d[2];
            if (ni < 0 || ni >= n || nj < 0 || nj >= n || nk < 0 || nk >= n) { continue; }
            const size_t kk = key(ni, nj, nk);
            if (!visited[kk] && solidAt(ni, nj, nk)) {
                visited[kk] = true;
                queue.push_back({ni, nj, nk});
            }
        }
    }
    return visited;
}

std::vector<bool> formGridDamaged(const std::function<bool(float, float, float)> &baseSolid,
        const FormBaseline &baseline, const FormDamage &damage, int n) {
    std::vector<bool> g(static_cast<size_t>(n) * n * n, false);
    for (int k = 0; k < n; ++k) {
        const float pz = (static_cast<float>(k) + 0.5f) / n - 0.5f;
        for (int j = 0; j < n; ++j) {
            const float py = (static_cast<float>(j) + 0.5f) / n - 0.5f;
            for (int i = 0; i < n; ++i) {
                const float px = (static_cast<float>(i) + 0.5f) / n - 0.5f;
                g[static_cast<size_t>(k) * n * n + static_cast<size_t>(j) * n + i]
                    = baseSolid(px, py, pz) && formDamageSolid(baseline, damage, px, py, pz);
            }
        }
    }
    return formConnected(g, n, baseline.centre[0], baseline.centre[1], baseline.centre[2]);
}

float formVolumeDamaged(const std::function<bool(float, float, float)> &baseSolid,
        const FormBaseline &baseline, const FormDamage &damage, int n) {
    const std::vector<bool> g = formGridDamaged(baseSolid, baseline, damage, n);
    size_t solid = 0;
    for (bool v : g) { if (v) { ++solid; } }
    return g.empty() ? 0.0f : static_cast<float>(solid) / static_cast<float>(g.size());
}

float formProgress(float pristineVolume, float connectedVolume) {
    if (pristineVolume <= 1e-9f) { return 0.0f; }
    float left = connectedVolume / pristineVolume;
    if (left > 1.0f) { left = 1.0f; }
    float done = (1.0f - left) / (1.0f - kFormRemains);
    return clamp01(done);
}

int formStage(bool hasDamage, float pristineVolume, float connectedVolume) {
    if (!hasDamage) { return 0; }
    const float done = formProgress(pristineVolume, connectedVolume);
    int stage = 1 + static_cast<int>(std::floor(done * (kCrackFrames - 1)));
    if (stage > kCrackFrames - 1) { stage = kCrackFrames - 1; }
    return stage;
}

std::string encodeForm(const FormDamage &damage) {
    uint32_t mask = 0;
    std::string body;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const bool hasDelta = damage.delta[i] > 0.0f;
        const bool hasCrater = damage.crater[i] > 0.0f;
        if (!hasDelta && !hasCrater) { continue; }
        mask |= (1u << i);
        uint8_t field = static_cast<uint8_t>((hasDelta ? 1 : 0) | (hasCrater ? 2 : 0));
        body.push_back(static_cast<char>(field));
        if (hasDelta) {
            const float q = std::min(1.0f, damage.delta[i]);
            body.push_back(static_cast<char>(static_cast<int>(q * 255.0f + 0.5f)));
        }
        if (hasCrater) {
            const float q = std::min(1.0f, damage.crater[i]);
            body.push_back(static_cast<char>(static_cast<int>(q * 255.0f + 0.5f)));
        }
    }
    if (mask == 0) { return std::string(); }
    std::string out;
    out.push_back(static_cast<char>(3)); // ENCODE_VERSION
    const uint8_t header = static_cast<uint8_t>(resolutionCode(damage.resolution)
            + 4 * (damage.metric == FormMetric::Cube ? 1 : 0));
    out.push_back(static_cast<char>(header));
    for (int b = 0; b < 4; ++b) {
        out.push_back(static_cast<char>((mask >> (8 * b)) & 0xff));
    }
    return out + body;
}

FormDamage decodeForm(const std::string &bytes) {
    FormDamage out;
    if (bytes.size() < 7 || static_cast<uint8_t>(bytes[0]) != 3) { return out; }
    const uint8_t header = static_cast<uint8_t>(bytes[1]);
    out.resolution = resolutionFromCode(header);
    out.metric = ((header / 4) % 2 == 1) ? FormMetric::Cube : FormMetric::Sphere;
    uint32_t mask = 0;
    for (int b = 0; b < 4; ++b) {
        mask |= static_cast<uint32_t>(static_cast<uint8_t>(bytes[2 + b])) << (8 * b);
    }
    size_t at = 6;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (!(mask & (1u << i))) { continue; }
        if (at >= bytes.size()) { break; }
        const uint8_t field = static_cast<uint8_t>(bytes[at++]);
        if (field & 1) {
            if (at >= bytes.size()) { break; }
            out.delta[i] = static_cast<uint8_t>(bytes[at++]) / 255.0f;
        }
        if (field & 2) {
            if (at >= bytes.size()) { break; }
            out.crater[i] = static_cast<uint8_t>(bytes[at++]) / 255.0f;
        }
    }
    return out;
}

namespace {
std::mutex g_carve_store_lock;
std::map<std::tuple<int, int, int>, FormDamage> g_carve_store;
} // namespace

thread_local const CarveSnapshot *g_goanna_carve_block = nullptr;

void carveStoreSet(int x, int y, int z, const FormDamage &damage) {
    std::lock_guard<std::mutex> lock(g_carve_store_lock);
    g_carve_store[std::make_tuple(x, y, z)] = damage;
}

void carveStoreClear(int x, int y, int z) {
    std::lock_guard<std::mutex> lock(g_carve_store_lock);
    g_carve_store.erase(std::make_tuple(x, y, z));
}

bool carveStoreGet(int x, int y, int z, FormDamage &out) {
    std::lock_guard<std::mutex> lock(g_carve_store_lock);
    const auto it = g_carve_store.find(std::make_tuple(x, y, z));
    if (it == g_carve_store.end()) { return false; }
    out = it->second;
    return true;
}

bool carveStoreEmpty() {
    std::lock_guard<std::mutex> lock(g_carve_store_lock);
    return g_carve_store.empty();
}

void carveSnapshot(int block_x, int block_y, int block_z, CarveSnapshot &out) {
    out.entries.clear();
    std::lock_guard<std::mutex> lock(g_carve_store_lock);
    if (g_carve_store.empty()) { return; }
    // MAP_BLOCKSIZE is 16, and the range reaches one node past the block on
    // every side: a node decides whether to draw its boundary face by asking
    // whether its neighbour is a whole cube, and a neighbour one node outside
    // this block is exactly as able to be carved as one inside it.
    const auto lo = g_carve_store.lower_bound(std::make_tuple(block_x - 1, block_y - 1, block_z - 1));
    const auto hi = g_carve_store.upper_bound(std::make_tuple(block_x + 16, block_y + 16, block_z + 16));
    for (auto it = lo; it != hi; ++it) {
        const int x = std::get<0>(it->first);
        const int y = std::get<1>(it->first);
        const int z = std::get<2>(it->first);
        if (x < block_x - 1 || x > block_x + 16) { continue; }
        if (y < block_y - 1 || y > block_y + 16) { continue; }
        if (z < block_z - 1 || z > block_z + 16) { continue; }
        CarveSnapshot::Entry e;
        e.x = static_cast<int16_t>(x - block_x);
        e.y = static_cast<int16_t>(y - block_y);
        e.z = static_cast<int16_t>(z - block_z);
        e.damage = it->second;
        out.entries.push_back(e);
    }
}

void FormDig::beginCube() {
    baseline = formBaselineForCube();
    base_solid_ = [](float, float, float) { return true; };
    pristine_volume = 1.0f;
    applied_progress = 0.0f;
    initial_cells = -1;
    remaining_volume = 1.0f;
}

void FormDig::beginBoxes(const std::vector<FormBox> &boxes, int resolution) {
    baseline = formBaselineFromBoxes(boxes);
    base_solid_ = [boxes](float x, float y, float z) { return pointInBoxes(boxes, x, y, z); };
    if (damage.empty()) { damage.resolution = resolution > 0 ? resolution : 8; }
    const int n = damage.resolution;
    size_t solid = 0;
    for (int k = 0; k < n; ++k) {
        const float pz = (static_cast<float>(k) + 0.5f) / n - 0.5f;
        for (int j = 0; j < n; ++j) {
            const float py = (static_cast<float>(j) + 0.5f) / n - 0.5f;
            for (int i = 0; i < n; ++i) {
                const float px = (static_cast<float>(i) + 0.5f) / n - 0.5f;
                if (pointInBoxes(boxes, px, py, pz)) { ++solid; }
            }
        }
    }
    pristine_volume = static_cast<float>(solid) / static_cast<float>(n) / n / n;
    applied_progress = 0.0f;
    initial_cells = -1;
    remaining_volume = 1.0f;
}

bool FormDig::advance(float progress, float px, float py, float pz,
        float nx, float ny, float nz) {
    if (!std::isfinite(progress) || !std::isfinite(px) || !std::isfinite(py) || !std::isfinite(pz)) {
        return false;
    }
    const float next = clamp01(progress);
    if (next <= applied_progress) { return false; }
    if (!base_solid_) { return false; }

    const int n = damage.resolution > 0 ? damage.resolution : 8;
    auto countCells = [&](const FormDamage &d) {
        const auto grid = formGridDamaged(base_solid_, baseline, d, n);
        return static_cast<int>(std::count(grid.begin(), grid.end(), true));
    };
    if (initial_cells < 0) { initial_cells = countCells(damage); }
    const int target = static_cast<int>(std::round(initial_cells * (1.0f - next)));

    auto cellsAt = [&](float depth) {
        const FormDamage trial = formStrike(baseline, damage, px, py, pz, depth, nx, ny, nz);
        return countCells(trial);
    };

    // Depth is a plain node length; present positions are at most sqrt(3)/2
    // and craters cap at kCraterMax (0.9), so 4 node units is comfortably
    // more depth than one blow could ever need to exhaust every reachable
    // control.
    float lo = 0.0f, hi = 4.0f;
    for (int i = 0; i < 22; ++i) {
        const float mid = (lo + hi) * 0.5f;
        if (cellsAt(mid) > target) { lo = mid; } else { hi = mid; }
    }
    const float amount = std::abs(cellsAt(lo) - target) < std::abs(cellsAt(hi) - target) ? lo : hi;
    damage = formStrike(baseline, damage, px, py, pz, amount, nx, ny, nz);
    remaining_volume = static_cast<float>(countCells(damage)) / static_cast<float>(n) / n / n;
    applied_progress = next;
    return true;
}

std::vector<FormSurface> formSurfaces(const std::vector<bool> &grid, int n,
        uint8_t visible_boundary, uint8_t backing_boundary) {
    std::vector<FormSurface> out;
    if (n <= 0 || grid.size() != static_cast<size_t>(n) * n * n) { return out; }
    auto solid = [&](const int p[3]) {
        return grid[p[2] * n * n + p[1] * n + p[0]];
    };
    const int axes[6] = {1, 1, 0, 0, 2, 2};
    for (int face = 0; face < 6; ++face) {
        const int axis = axes[face], u = (axis + 1) % 3, v = (axis + 2) % 3;
        const int sign = (face & 1) ? -1 : 1;
        for (int layer = 0; layer < n; ++layer) {
            const bool boundary = layer + sign < 0 || layer + sign >= n;
            std::vector<uint8_t> mask(n * n, 0);
            for (int j = 0; j < n; ++j) {
                for (int i = 0; i < n; ++i) {
                    int p[3]; p[axis] = layer; p[u] = i; p[v] = j;
                    const bool here = solid(p);
                    if (boundary) {
                        if (here && (visible_boundary & (1 << face))) { mask[j * n + i] = 1; }
                        if (!here && (backing_boundary & (1 << face))) { mask[j * n + i] = 2; }
                    } else if (here) {
                        p[axis] += sign;
                        if (!solid(p)) { mask[j * n + i] = 1; }
                    }
                }
            }
            for (int j = 0; j < n; ++j) {
                for (int i = 0; i < n; ++i) {
                    const uint8_t kind = mask[j * n + i];
                    if (!kind) { continue; }
                    int width = 1, height = 1;
                    while (i + width < n && mask[j * n + i + width] == kind) { ++width; }
                    for (; j + height < n; ++height) {
                        bool same = true;
                        for (int k = 0; k < width; ++k) {
                            if (mask[(j + height) * n + i + k] != kind) { same = false; break; }
                        }
                        if (!same) { break; }
                    }
                    float lo[3], hi[3];
                    lo[axis] = hi[axis] = static_cast<float>(layer + (sign > 0 ? 1 : 0)) / n - 0.5f;
                    lo[u] = static_cast<float>(i) / n - 0.5f; hi[u] = static_cast<float>(i + width) / n - 0.5f;
                    lo[v] = static_cast<float>(j) / n - 0.5f; hi[v] = static_cast<float>(j + height) / n - 0.5f;
                    out.push_back({{lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]},
                            kind == 2 ? face ^ 1 : face, kind == 2 ? face : -1});
                    for (int y = j; y < j + height; ++y) {
                        for (int x = i; x < i + width; ++x) { mask[y * n + x] = 0; }
                    }
                }
            }
        }
    }
    return out;
}

} // namespace goanna
