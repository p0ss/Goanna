// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_occlusion.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

// Tracing budget. Chosen from the sweep goanna_light_test.cpp prints, not by
// eye: with grid traversal the error is flat in step size, so only the ray
// count and the radius are left to choose.
// This runs once per emitted terrain vertex while blocks and LOD regions are
// produced. Twenty-four grid-traversed rays dominated streaming frames for a
// difference largely covered by the separate four-cell corner term below.
// Eight retains broad valley/pit shading without making terrain production a
// CPU ray tracer.
int g_rays = 8;
int g_steps = 1; // unused by the traversal, kept so the setter stays stable
float g_radius = 6.0f;

struct Dirs {
    std::vector<v3f> d; // cosine weighted over the +Y hemisphere
    int rays = 0;
};

// Fibonacci hemisphere, cosine weighted: z = sqrt(1 - u) puts more rays near
// the pole, which is where the cosine term says the light comes from.
const Dirs &directions() {
    static Dirs cached;
    if (cached.rays == g_rays)
        return cached;
    cached.d.clear();
    const float golden = 2.399963229728653f; // pi * (3 - sqrt(5))
    for (int i = 0; i < g_rays; ++i) {
        float u = (i + 0.5f) / (float)g_rays;
        float y = std::sqrt(1.0f - u); // cosine weighted
        float r = std::sqrt(std::max(0.0f, 1.0f - y * y));
        float a = golden * i;
        cached.d.push_back(v3f(r * std::cos(a), y, r * std::sin(a)));
    }
    cached.rays = g_rays;
    return cached;
}

// An orthonormal frame with `n` as its up axis. Axis aligned normals are the
// common case by far, so the branch is worth it.
void frameFor(const v3f &n, v3f &t, v3f &b) {
    v3f up = std::fabs(n.Y) < 0.9f ? v3f(0, 1, 0) : v3f(1, 0, 0);
    t = up.crossProduct(n);
    float len = t.getLength();
    if (len < 1e-4f) {
        t = v3f(1, 0, 0);
        len = 1.0f;
    }
    t /= len;
    b = n.crossProduct(t);
}

} // namespace

// ---------------------------------------------------------------------------

void OccupancyField::reset(v3s16 origin_nodes, int cell_nodes, int cells_x, int cells_y, int cells_z) {
    origin = origin_nodes;
    cell = std::max(1, cell_nodes);
    nx = cells_x;
    ny = cells_y;
    nz = cells_z;
    bits.assign(((size_t)nx * ny * nz + 63) / 64, 0);
}

bool OccupancyField::solidAt(float x, float y, float z) const {
    int cx = (int)std::floor((x - origin.X) / cell);
    int cy = (int)std::floor((y - origin.Y) / cell);
    int cz = (int)std::floor((z - origin.Z) / cell);
    return cellSolid(cx, cy, cz);
}

float traceOcclusion(const OccupancyField &f, const v3f &p, const v3f &n, float radius) {
    v3f nn = n;
    float nl = nn.getLength();
    if (nl < 1e-4f)
        return 1.0f;
    nn /= nl;
    v3f t, b;
    frameFor(nn, t, b);
    const Dirs &dirs = directions();
    // Start just off the surface, or the first cell tested is the one the face
    // belongs to and everything reads as fully occluded.
    const v3f base = p + nn * 0.5f;
    const float cell = (float)f.cell;
    // Fractional cell coordinates of the start point.
    const float fx = (base.X - f.origin.X) / cell;
    const float fy = (base.Y - f.origin.Y) / cell;
    const float fz = (base.Z - f.origin.Z) / cell;
    float blocked = 0.0f;
    for (const v3f &d : dirs.d) {
        const v3f w = t * d.X + nn * d.Y + b * d.Z;
        // Grid traversal, cell by cell, rather than sampling at fixed
        // distances. Point sampling tunnels: a ray leaving a pit at a shallow
        // angle steps straight over the one node rim without ever landing
        // inside it, and the error that produces does not fall with more rays,
        // only with a finer step. Measured in goanna_light_test.cpp: fixed
        // steps left a 1 deep pit 0.17 too bright at every ray count from 8 to
        // 48, and only a quarter node step fixed it, at four times the cost.
        // Visiting every cell the ray crosses cannot miss one and is cheaper.
        int cx = (int)std::floor(fx), cy = (int)std::floor(fy), cz = (int)std::floor(fz);
        const int sx = w.X > 0 ? 1 : -1, sy = w.Y > 0 ? 1 : -1, sz = w.Z > 0 ? 1 : -1;
        const float kFar = 1e30f;
        const float ax = std::fabs(w.X), ay = std::fabs(w.Y), az = std::fabs(w.Z);
        // Distance along the ray, in nodes, to the next boundary on each axis,
        // and the distance between boundaries after that.
        float tmx = ax < 1e-6f ? kFar : ((w.X > 0 ? std::floor(fx) + 1.0f : std::floor(fx)) - fx) * cell / w.X;
        float tmy = ay < 1e-6f ? kFar : ((w.Y > 0 ? std::floor(fy) + 1.0f : std::floor(fy)) - fy) * cell / w.Y;
        float tmz = az < 1e-6f ? kFar : ((w.Z > 0 ? std::floor(fz) + 1.0f : std::floor(fz)) - fz) * cell / w.Z;
        const float tdx = ax < 1e-6f ? kFar : cell / ax;
        const float tdy = ay < 1e-6f ? kFar : cell / ay;
        const float tdz = az < 1e-6f ? kFar : cell / az;
        for (;;) {
            float dist;
            if (tmx < tmy && tmx < tmz) {
                dist = tmx;
                cx += sx;
                tmx += tdx;
            } else if (tmy < tmz) {
                dist = tmy;
                cy += sy;
                tmy += tdy;
            } else {
                dist = tmz;
                cz += sz;
                tmz += tdz;
            }
            if (dist > radius)
                break;
            if (f.cellSolid(cx, cy, cz)) {
                // A near occluder darkens more than a far one, and the falloff
                // is what stops a distant wall flattening a whole field.
                blocked += 1.0f - dist / radius;
                break;
            }
        }
    }
    float ao = 1.0f - blocked / (float)dirs.d.size();
    return std::clamp(ao, 0.0f, 1.0f);
}

void setOcclusionQuality(int rays, int steps, float radius) {
    g_rays = std::clamp(rays, 1, 64);
    g_steps = std::clamp(steps, 1, 32);
    g_radius = std::clamp(radius, 1.0f, 64.0f);
}

int occlusionRays() { return g_rays; }
int occlusionSteps() { return g_steps; }
float occlusionRadius() { return g_radius; }

} // namespace goanna
