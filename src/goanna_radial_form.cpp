// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_radial_form.h"

#include "goanna_mesh_flags.h"

#include <cmath>
#include <algorithm>

// Defined here rather than in the transplanted mesher, unlike g_goanna_bevel:
// this is Goanna's own state and there is no reason to put it in upstream code.
const goanna::RadialForm *g_goanna_carve = nullptr;
// Legacy environment value is depth per fifth of a completed dig.
float g_goanna_carve_depth = 0.12f;
int g_goanna_carve_demo = 0;
int g_goanna_carve_demo_z = 0;

namespace goanna {

namespace {

constexpr float kR3 = 0.57735026918962576451f; // 1 / sqrt(3)
constexpr float kR2b = 0.70710678118654752440f; // 1 / sqrt(2)

// The twenty six plane directions, in the Lua's order: six faces, twelve edge
// midpoints, eight corners. Both ends index this, so it must not be reordered.
const float kPlane[FORM_PLANE_COUNT][3] = {
    {-1.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f},
    {0.0f, -1.0f, 0.0f}, {0.0f, 1.0f, 0.0f},
    {0.0f, 0.0f, -1.0f}, {0.0f, 0.0f, 1.0f},
    {-kR2b, -kR2b, 0.0f}, {-kR2b, kR2b, 0.0f}, {kR2b, -kR2b, 0.0f}, {kR2b, kR2b, 0.0f},
    {-kR2b, 0.0f, -kR2b}, {-kR2b, 0.0f, kR2b}, {kR2b, 0.0f, -kR2b}, {kR2b, 0.0f, kR2b},
    {0.0f, -kR2b, -kR2b}, {0.0f, -kR2b, kR2b}, {0.0f, kR2b, -kR2b}, {0.0f, kR2b, kR2b},
    {-kR3, -kR3, -kR3}, {-kR3, -kR3, kR3}, {-kR3, kR3, -kR3}, {-kR3, kR3, kR3},
    {kR3, -kR3, -kR3}, {kR3, -kR3, kR3}, {kR3, kR3, -kR3}, {kR3, kR3, kR3},
};

// How far the node's own boundary is from the origin along u: the support
// distance. It is what makes an offset of 1 mean "touches the node and cuts
// nothing", and what each carve slice is seeded at.
float support(const float origin[3], float ux, float uy, float uz) {
    auto axis = [](float u, float o) {
        const float a = u * (0.5f - o);
        const float b = u * (-0.5f - o);
        return a > b ? a : b;
    };
    return axis(ux, origin[0]) + axis(uy, origin[1]) + axis(uz, origin[2]);
}

// How far a fully dug face pulls its slice in, in node units. Must equal the
// Lua's DIG_DEPTH.
constexpr float kDigDepth = 0.35f;

// Preserve the authored radial field used by Kythen. Live impacts use local
// subtraction vectors, so increasing sharpness is no longer a digging knob.
constexpr int kPower = 12;

constexpr int kDamageSteps = 3;

// Half width of the hole a fully dug pair of faces opens.
constexpr float kDerivedBore = 0.25f;

constexpr float kR2 = 0.70710678118654752440f; // 1 / sqrt(2)

const float kBoreAxis[FORM_BORE_COUNT][3] = {
    {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f},
    {kR2, kR2, 0.0f}, {kR2, -kR2, 0.0f},
    {kR2, 0.0f, kR2}, {kR2, 0.0f, -kR2},
    {0.0f, kR2, kR2}, {0.0f, kR2, -kR2},
    {kR3, kR3, kR3}, {kR3, kR3, -kR3},
    {kR3, -kR3, kR3}, {kR3, -kR3, -kR3},
};

// Which pair of faces, dug through, opens which bore.
const FormAxis kBorePair[3][2] = {
    {AXIS_XN, AXIS_XP}, {AXIS_YN, AXIS_YP}, {AXIS_ZN, AXIS_ZP},
};

float clamp01(float v) {
    if (v < 0.0f) { return 0.0f; }
    if (v > 1.0f) { return 1.0f; }
    return v;
}

float radiusAt(const RadialForm &form, float dx, float dy, float dz) {
    float best = 1e30f;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const float dot = dx * kPlane[i][0] + dy * kPlane[i][1] + dz * kPlane[i][2];
        if (dot <= 1e-6f) { continue; }
        const float reach = form.box[i] * support(form.origin, kPlane[i][0],
                                                  kPlane[i][1], kPlane[i][2]);
        const float r = (form.extents[i] >= 0.0f) ? form.extents[i] : reach;
        float w = dot;
        for (int p = 1; p < kPower; ++p) { w *= dot; }
        const float bound = r / w;
        if (bound < best) { best = bound; }
    }
    return best;
}

bool insideBox(const RadialForm &form, float vx, float vy, float vz) {
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        if (form.box[i] >= 1.0f) { continue; }
        const float wall = form.box[i] * support(form.origin, kPlane[i][0],
                                                 kPlane[i][1], kPlane[i][2]);
        if (vx * kPlane[i][0] + vy * kPlane[i][1] + vz * kPlane[i][2] > wall + 1e-9f) {
            return false;
        }
    }
    return true;
}

} // namespace

RadialForm formFromWord(uint16_t word) {
    RadialForm form;
    int damage[FORM_FACE_COUNT];
    for (int i = 0; i < FORM_FACE_COUNT; ++i) {
        damage[i] = (word >> (2 * i)) & 0x3;
    }
    // Bores are derived and cost no bits: both faces of an axis dug all the way
    // IS "dug through from both sides". A bored pair then hands its damage over
    // and its slices read untouched, because a crater that has broken through
    // IS the hole and not a hole plus the two craters that made it.
    for (int a = 0; a < 3; ++a) {
        const FormAxis lo = kBorePair[a][0];
        const FormAxis hi = kBorePair[a][1];
        if (damage[lo] >= kDamageSteps && damage[hi] >= kDamageSteps) {
            form.bore[a] = kDerivedBore;
            damage[lo] = 0;
            damage[hi] = 0;
        }
    }
    for (int i = 0; i < FORM_FACE_COUNT; ++i) {
        if (damage[i] > 0) {
            const float reach = support(form.origin, kPlane[i][0], kPlane[i][1],
                                        kPlane[i][2]);
            form.extents[i] = reach - static_cast<float>(damage[i])
                            / static_cast<float>(kDamageSteps) * kDigDepth;
        }
    }
    return form;
}

RadialForm strike(const RadialForm &form, float px, float py, float pz, float depth) {
    RadialForm out = form;
    if (!(depth > 0.0f) || !std::isfinite(depth))
        return out;
    const float v[3] = {px - form.origin[0], py - form.origin[1], pz - form.origin[2]};
    int slot = 0;
    float best = -1e30f;
    for (int i = 0; i < FORM_PLANE_COUNT; ++i) {
        const float dot = v[0]*kPlane[i][0] + v[1]*kPlane[i][1] + v[2]*kPlane[i][2];
        if (dot > best) { best = dot; slot = i; }
    }
    FormCut &cut = out.carve[slot];
    if (cut.radius <= 0) {
        cut = {px, py, pz, depth};
    } else {
        // Enclose the existing bite and a small new bite at the impact. Unlike
        // moving an old dent to the latest hit, this can only remove material.
        const float dx = px-cut.x, dy = py-cut.y, dz = pz-cut.z;
        const float distance = std::sqrt(dx*dx + dy*dy + dz*dz);
        const float radius = std::max(cut.radius + depth,
                (distance + cut.radius + depth) * 0.5f);
        const float shift = std::min(radius-cut.radius, distance);
        if (distance > 1e-9f) {
            cut.x += dx * shift / distance;
            cut.y += dy * shift / distance;
            cut.z += dz * shift / distance;
        }
        cut.radius = radius;
    }
    return out;
}

bool FormDig::advance(float progress, float px, float py, float pz, float total_depth) {
    const int next = std::min(16, static_cast<int>(clamp01(progress) * 16.0f + 1e-5f));
    if (next <= step || !(total_depth > 0))
        return false;
    form = strike(form, px, py, pz, total_depth * (next-step) / 16.0f);
    step = next;
    return true;
}

uint16_t wordFromParams(uint8_t param1, uint8_t param2) {
    return static_cast<uint16_t>(param1)
         | static_cast<uint16_t>(static_cast<uint16_t>(param2) << 8);
}

uint16_t digWord(uint16_t base, FormAxis face, float progress) {
    if (face < 0 || face >= FORM_FACE_COUNT) { return base; }
    const float p = clamp01(progress);
    int steps = static_cast<int>(p * static_cast<float>(kDamageSteps) + 0.5f);
    if (steps > kDamageSteps) { steps = kDamageSteps; }

    const int shift = 2 * static_cast<int>(face);
    const int was = (base >> shift) & 0x3;
    // Dig damage adds to whatever the server already stored, and saturates.
    // A step that wrapped would put geometry on screen that no server could
    // ever agree with, which on a stored form would then be written back.
    int now = was + steps;
    if (now > kDamageSteps) { now = kDamageSteps; }
    return static_cast<uint16_t>((base & ~(0x3 << shift)) | (now << shift));
}

bool formSolid(const RadialForm &form, float px, float py, float pz) {
    for (const FormCut &cut : form.carve) {
        if (cut.radius <= 0) continue;
        const float dx = px-cut.x, dy = py-cut.y, dz = pz-cut.z;
        if (dx*dx + dy*dy + dz*dz <= cut.radius*cut.radius + 1e-9f)
            return false;
    }
    const float vx = px - form.origin[0];
    const float vy = py - form.origin[1];
    const float vz = pz - form.origin[2];

    // Bored out along any axis and the point is gone. First, before the origin
    // short circuit: the origin lies on every bore axis, so it is the one point
    // every hole certainly removes, and testing it last left a single cube
    // floating in the middle of a shaft drilled clean through.
    for (int a = 0; a < FORM_BORE_COUNT; ++a) {
        const float r = form.bore[a];
        if (r <= 0.0f) { continue; }
        const float along = vx * kBoreAxis[a][0] + vy * kBoreAxis[a][1]
                          + vz * kBoreAxis[a][2];
        const float qx = vx - along * kBoreAxis[a][0];
        const float qy = vy - along * kBoreAxis[a][1];
        const float qz = vz - along * kBoreAxis[a][2];
        if (qx * qx + qy * qy + qz * qz <= r * r + 1e-9f) { return false; }
    }

    if (!insideBox(form, vx, vy, vz)) { return false; }

    const float len = std::sqrt(vx * vx + vy * vy + vz * vz);
    if (len < 1e-9f) { return true; }
    // Plain length against plain length. No normalisation: that is the whole
    // correction, and the reason a dent is a dent.
    return len <= radiusAt(form, vx / len, vy / len, vz / len) + 1e-9f;
}

std::vector<bool> formGrid(const RadialForm &form, int resolution) {
    const int n = resolution > 0 ? resolution : form.resolution;
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

std::vector<FormSurface> formSurfaces(const std::vector<bool> &grid, int n,
        uint8_t visible_boundary, uint8_t backing_boundary) {
    std::vector<FormSurface> out;
    if (n <= 0 || grid.size() != static_cast<size_t>(n)*n*n) return out;
    auto solid = [&](const int p[3]) {
        return grid[p[2]*n*n + p[1]*n + p[0]];
    };
    const int axes[6] = {1, 1, 0, 0, 2, 2};
    for (int face = 0; face < 6; ++face) {
        const int axis = axes[face], u = (axis+1)%3, v = (axis+2)%3;
        const int sign = (face & 1) ? -1 : 1;
        for (int layer = 0; layer < n; ++layer) {
            const bool boundary = layer+sign < 0 || layer+sign >= n;
            // 1 = the carved node, 2 = a newly revealed neighbouring face.
            std::vector<uint8_t> mask(n*n, 0);
            for (int j=0; j<n; ++j) for (int i=0; i<n; ++i) {
                int p[3]; p[axis]=layer; p[u]=i; p[v]=j;
                const bool here = solid(p);
                if (boundary) {
                    if (here && (visible_boundary & (1<<face))) mask[j*n+i]=1;
                    if (!here && (backing_boundary & (1<<face))) mask[j*n+i]=2;
                } else if (here) {
                    p[axis]+=sign;
                    if (!solid(p)) mask[j*n+i]=1;
                }
            }
            for (int j=0; j<n; ++j) for (int i=0; i<n; ++i) {
                const uint8_t kind = mask[j*n+i];
                if (!kind) continue;
                int width=1, height=1;
                while (i+width<n && mask[j*n+i+width]==kind) ++width;
                for (; j+height<n; ++height) {
                    bool same=true;
                    for (int k=0; k<width; ++k)
                        if (mask[(j+height)*n+i+k]!=kind) { same=false; break; }
                    if (!same) break;
                }
                float lo[3], hi[3];
                lo[axis]=hi[axis]=float(layer+(sign>0 ? 1 : 0))/n-.5f;
                lo[u]=float(i)/n-.5f; hi[u]=float(i+width)/n-.5f;
                lo[v]=float(j)/n-.5f; hi[v]=float(j+height)/n-.5f;
                out.push_back({{lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]},
                        kind==2 ? face^1 : face, kind==2 ? face : -1});
                for (int y=j; y<j+height; ++y) for (int x=i; x<i+width; ++x)
                    mask[y*n+x]=0;
            }
        }
    }
    return out;
}

std::vector<FormBox> formBoxes(const RadialForm &form, int resolution) {
    const int n = resolution > 0 ? resolution : form.resolution;
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
                // Run along x, then widen in y while whole rows match, then in
                // z while whole slabs match. The order decides only which of
                // several equally good decompositions you get, and this one is
                // the Lua's, which is what makes the two agree.
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

float formVolume(const RadialForm &form, int resolution) {
    const int n = resolution > 0 ? resolution : form.resolution;
    const std::vector<bool> g = formGrid(form, n);
    size_t solid = 0;
    for (size_t at = 0; at < g.size(); ++at) {
        if (g[at]) { ++solid; }
    }
    return static_cast<float>(solid) / static_cast<float>(g.size());
}

} // namespace goanna
