// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The horizon bake's marcher, checked on its own. A live sky cannot judge
// it: the benchmark session measured a same-state screenshot floor 26
// times larger than the bake toggle's signal. What matters here is not
// visible in any screenshot anyway: the azimuth convention matches what
// the sky shader samples (u = fract(atan(dir.x, -dir.z) / tau), theta 0
// facing Godot -Z, which is Luanti +Z), the elevation rows land where the
// sine says, a near ridge hides a farther lower one and only the part of
// a farther taller one that clears it is painted, and a leaked floating
// stale box cannot paint a slab across the sky.

#include "goanna_horizon.h"

#include <cmath>
#include <cstdio>

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

HorizonSnapshot baseSnapshot() {
    HorizonSnapshot s;
    s.origin_x = 0.0f;
    s.origin_y = 0.0f;
    s.origin_z = 0.0f;
    s.r0 = 256.0f;
    s.r1 = 2048.0f;
    return s;
}

// A wall of columns along Luanti X near 500 nodes, wide in Z so despiking
// leaves it alone.
void addWall(HorizonSnapshot &s, int bx, int16_t top, uint32_t colour) {
    for (int bz = -6; bz <= 6; ++bz)
        for (int dx = 0; dx < 2; ++dx)
            s.columns[HorizonSnapshot::key(bx + dx, bz)] = {top, colour};
}

float sinAt(float top, float r) { return top / std::sqrt(r * r + top * top); }

int rowFor(const HorizonSnapshot &s, float sine) {
    return (int)std::floor((sine - s.y_min) / (s.y_max - s.y_min) * (float)s.height);
}

// The wall at Luanti +X is Godot +X, so the shader's theta is
// atan(1, 0) = pi/2 and u = 0.25: the wall must paint at width / 4 and
// nowhere near u = 0 or u = 0.5.
void testAzimuthMatchesShader() {
    HorizonSnapshot s = baseSnapshot();
    addWall(s, 31, 100, 0xff8040);
    HorizonResult r = buildHorizonPanorama(s);
    auto alpha = [&](int col, int row) {
        return r.albedo[((size_t)row * r.width + col) * 4 + 3];
    };
    const int mid = rowFor(s, sinAt(101.0f, 500.0f) * 0.5f); // well inside
    check(alpha(r.width / 4, mid) == 255, "the +X wall paints at u = 0.25");
    check(alpha(0, mid) == 0, "nothing paints at u = 0 (Godot -Z)");
    check(alpha(r.width / 2, mid) == 0, "nothing paints at u = 0.5 (Godot +Z)");
    const size_t px = ((size_t)mid * r.width + r.width / 4);
    check(r.albedo[px * 4 + 0] == 0xff && r.albedo[px * 4 + 1] == 0x80,
            "the wall keeps its colour");
    check(std::fabs(r.distance[px] - 500.0f) < 64.0f,
            "the wall's distance is about its range");
}

// The silhouette top edge lands on the row the sine says, within the
// march's one-step slack.
void testElevationRows() {
    HorizonSnapshot s = baseSnapshot();
    addWall(s, 31, 100, 0xffffff);
    HorizonResult r = buildHorizonPanorama(s);
    const int col = r.width / 4;
    int top_row = -1;
    for (int row = r.height - 1; row >= 0; --row)
        if (r.albedo[((size_t)row * r.width + col) * 4 + 3] == 255) {
            top_row = row;
            break;
        }
    const int expect = rowFor(s, sinAt(101.0f, 496.0f));
    check(top_row >= 0, "the wall painted at all");
    check(std::abs(top_row - expect) <= 4, "the silhouette lands on its sine row");
}

// A near ridge hides a farther, angularly lower one; a farther, taller one
// paints only above the near silhouette, and those rows carry the far
// distance.
void testOcclusion() {
    HorizonSnapshot s = baseSnapshot();
    addWall(s, 31, 100, 0x00ff00);  // near, ~500 nodes, sine ~0.196
    addWall(s, 62, 120, 0xff0000);  // far, ~1000 nodes, sine ~0.119: hidden
    addWall(s, 93, 500, 0x0000ff);  // far, ~1500 nodes, sine ~0.316: crown shows
    HorizonResult r = buildHorizonPanorama(s);
    const int col = r.width / 4;
    bool saw_red = false;
    for (int row = 0; row < r.height; ++row) {
        const size_t px = (size_t)row * r.width + col;
        if (r.albedo[px * 4 + 3] == 255 && r.albedo[px * 4 + 0] == 0xff &&
                r.albedo[px * 4 + 1] == 0)
            saw_red = true;
    }
    check(!saw_red, "an angularly lower far ridge is hidden by the near one");
    const int low = rowFor(s, 0.10f);
    const int high = rowFor(s, 0.28f);
    const size_t plow = (size_t)low * r.width + col;
    const size_t phigh = (size_t)high * r.width + col;
    check(r.albedo[plow * 4 + 1] == 0xff, "below the near crest the near ridge shows");
    check(r.albedo[phigh * 4 + 2] == 0xff, "above it the tall far ridge shows");
    check(r.distance[phigh] > 1200.0f, "the crown rows carry the far distance");
    check(r.distance[plow] < 700.0f, "the lower rows carry the near distance");
}

// Nothing inside r0 paints, so the panorama cannot double what the live
// field draws close in.
void testInnerRadiusRespected() {
    HorizonSnapshot s = baseSnapshot();
    addWall(s, 8, 200, 0xffffff); // ~130 nodes, inside r0 = 256
    HorizonResult r = buildHorizonPanorama(s);
    for (size_t i = 3; i < r.albedo.size(); i += 4)
        check(r.albedo[i] == 0, "a column inside r0 must not paint");
}

// The stale box defences: a column with no neighbours at all is dropped,
// and a one-column spire is clamped to its neighbours plus the grace, so
// neither can slab the sky. A wide mesa keeps its height.
void testDespiking() {
    HorizonSnapshot s = baseSnapshot();
    s.columns[HorizonSnapshot::key(31, 0)] = {250, 0xffffff}; // lonely box
    HorizonResult r = buildHorizonPanorama(s);
    for (size_t i = 3; i < r.albedo.size(); i += 4)
        check(r.albedo[i] == 0, "a neighbourless column is dropped");

    HorizonSnapshot s2 = baseSnapshot();
    addWall(s2, 31, 40, 0xffffff);
    s2.columns[HorizonSnapshot::key(31, 0)] = {400, 0xffffff}; // spire in a plain
    HorizonResult r2 = buildHorizonPanorama(s2);
    const int col = r2.width / 4;
    const int spire_row = rowFor(s2, sinAt(400.0f, 500.0f));
    check(r2.albedo[((size_t)spire_row * r2.width + col) * 4 + 3] == 0,
            "a lone spire is clamped and cannot slab the sky");
    const int plain_row = rowFor(s2, sinAt(41.0f, 500.0f) * 0.5f);
    check(r2.albedo[((size_t)plain_row * r2.width + col) * 4 + 3] == 255,
            "the plain around the spire still paints");
}

} // namespace

int main() {
    testAzimuthMatchesShader();
    testElevationRows();
    testOcclusion();
    testInnerRadiusRespected();
    testDespiking();
    if (g_failures == 0) {
        std::printf("goanna_horizon_test: all checks passed\n");
        return 0;
    }
    std::printf("goanna_horizon_test: %d failures\n", g_failures);
    return 1;
}
