// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Checks the ambient occlusion tracer in goanna_light.cpp against a dense
// reference integral over the same occupancy, on shapes whose answer is known
// by inspection: open ground is 1.0, the floor of a deep shaft is nearly 0,
// a corner is about half a wall.
//
// It is here because "the cone trace looks about right" is not a measurement,
// and because the far field version in docs/far-rendering.md traces a coarser
// field with the same code, where the error is larger and matters more.
//
// Build and run:
//   cmake --build build --target goanna_light_test && ./build/goanna_light_test

#include "goanna_occlusion.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace goanna;

namespace {

// Chosen from the sweep this program prints; see docs/mesh-attributes.md.
constexpr int kRaysDefault = 24;
constexpr int kStepsDefault = 1;

// Reference: many rays, fine steps, same falloff, so any difference is the
// sampling rate rather than a different definition of the quantity.
float reference(const OccupancyField &f, const v3f &p, const v3f &n, float radius) {
    const int kRays = 2048;
    const int kSteps = 1536;
    v3f nn = n;
    nn /= nn.getLength();
    v3f up = std::fabs(nn.Y) < 0.9f ? v3f(0, 1, 0) : v3f(1, 0, 0);
    v3f t = up.crossProduct(nn);
    t /= t.getLength();
    v3f b = nn.crossProduct(t);
    const float golden = 2.399963229728653f;
    const v3f base = p + nn * 0.5f;
    float blocked = 0.0f;
    for (int i = 0; i < kRays; ++i) {
        float u = (i + 0.5f) / (float)kRays;
        float y = std::sqrt(1.0f - u);
        float r = std::sqrt(1.0f - y * y);
        float a = golden * i;
        v3f d(r * std::cos(a), y, r * std::sin(a));
        v3f w = t * d.X + nn * d.Y + b * d.Z;
        for (int s = 1; s <= kSteps; ++s) {
            float dist = radius * s / (float)kSteps;
            v3f q = base + w * dist;
            if (f.solidAt(q.X, q.Y, q.Z)) {
                blocked += 1.0f - dist / radius;
                break;
            }
        }
    }
    return 1.0f - blocked / (float)kRays;
}

struct Scene {
    std::string name;
    OccupancyField f;
    v3f p, n;
};

// A 64 cube of cells, filled by a predicate, sampled at one point.
Scene make(const std::string &name, const v3f &p, const v3f &n, bool (*solid)(int, int, int)) {
    Scene s;
    s.name = name;
    s.p = p;
    s.n = n;
    const int side = 64;
    s.f.reset(v3s16(-32, -32, -32), 1, side, side, side);
    for (int z = 0; z < side; ++z)
        for (int y = 0; y < side; ++y)
            for (int x = 0; x < side; ++x)
                if (solid(x - 32, y - 32, z - 32))
                    s.f.setCell(x, y, z);
    return s;
}

bool ground(int, int y, int) { return y < 0; }
bool pit1(int x, int y, int z) { return y < 0 && !(y >= -1 && x == 0 && z == 0); }
bool pit5(int x, int y, int z) { return y < 0 && !(y >= -5 && x == 0 && z == 0); }
bool shaft(int x, int y, int z) { return !(x == 0 && z == 0) || y < -8; }
bool corner(int x, int y, int z) { return y < 0 || x < 0 || z < 0; }
bool overhang(int x, int y, int z) { return y < 0 || (y == 3 && x > -8 && z > -8); }
bool wall(int x, int, int) { return x < 0; }

} // namespace

int main() {
    struct Case {
        const char *name;
        v3f p, n;
        bool (*solid)(int, int, int);
    };
    const Case cases[] = {
        {"open ground", v3f(0.5f, 0.0f, 0.5f), v3f(0, 1, 0), ground},
        {"floor of a 1 deep pit", v3f(0.5f, -1.0f, 0.5f), v3f(0, 1, 0), pit1},
        {"floor of a 5 deep pit", v3f(0.5f, -5.0f, 0.5f), v3f(0, 1, 0), pit5},
        {"floor of a shaft", v3f(0.5f, -8.0f, 0.5f), v3f(0, 1, 0), shaft},
        {"inside corner", v3f(0.5f, 0.0f, 0.5f), v3f(0, 1, 0), corner},
        {"under an overhang", v3f(0.5f, 0.0f, 0.5f), v3f(0, 1, 0), overhang},
        {"vertical wall face", v3f(0.0f, 4.5f, 0.5f), v3f(1, 0, 0), wall},
    };
    // Sweep first: the default budget should be chosen from the error curve,
    // not from taste. Timing is per sample, which is what mesh time pays.
    printf("%6s %6s %10s %10s %12s\n", "rays", "steps", "worst err", "mean err", "us/sample");
    for (int rays : {8, 12, 16, 24, 32, 48}) {
        for (int steps : {1}) {
            setOcclusionQuality(rays, steps, 6.0f);
            float worst_s = 0.0f, sum_s = 0.0f;
            int n = 0;
            double us = 0.0;
            for (const Case &c : cases) {
                Scene s = make(c.name, c.p, c.n, c.solid);
                float want = reference(s.f, s.p, s.n, 6.0f);
                auto t0 = std::chrono::steady_clock::now();
                float got = 0.0f;
                const int reps = 2000;
                for (int i = 0; i < reps; ++i)
                    got = traceOcclusion(s.f, s.p, s.n, 6.0f);
                us += std::chrono::duration<double, std::micro>(
                              std::chrono::steady_clock::now() - t0).count() / reps;
                float e = std::fabs(got - want);
                worst_s = std::max(worst_s, e);
                sum_s += e;
                ++n;
            }
            printf("%6d %6d %10.3f %10.3f %12.3f\n", rays, steps, worst_s, sum_s / n, us / n);
        }
    }
    printf("\n");
    setOcclusionQuality(kRaysDefault, kStepsDefault, 6.0f);
    printf("%-26s %8s %8s %8s\n", "case", "traced", "dense", "error");
    float worst = 0.0f;
    for (const Case &c : cases) {
        Scene s = make(c.name, c.p, c.n, c.solid);
        float got = traceOcclusion(s.f, s.p, s.n, occlusionRadius());
        float want = reference(s.f, s.p, s.n, occlusionRadius());
        float err = std::fabs(got - want);
        worst = std::max(worst, err);
        printf("%-26s %8.3f %8.3f %8.3f\n", c.name, got, want, err);
    }
    printf("\nrays %d, radius %.1f nodes, worst error %.3f\n",
            occlusionRays(), occlusionRadius(), worst);
    // Ordering is the property that actually matters: a deeper hole must be
    // darker. An absolute error of a few per cent is invisible; an inversion
    // is not.
    Scene open = make("a", v3f(0.5f, 0.0f, 0.5f), v3f(0, 1, 0), ground);
    Scene p1 = make("b", v3f(0.5f, -1.0f, 0.5f), v3f(0, 1, 0), pit1);
    Scene p5 = make("c", v3f(0.5f, -5.0f, 0.5f), v3f(0, 1, 0), pit5);
    float ao_open = traceOcclusion(open.f, open.p, open.n, occlusionRadius());
    float ao_p1 = traceOcclusion(p1.f, p1.p, p1.n, occlusionRadius());
    float ao_p5 = traceOcclusion(p5.f, p5.p, p5.n, occlusionRadius());
    bool ordered = ao_open > ao_p1 && ao_p1 > ao_p5;
    printf("ordering open %.3f > pit1 %.3f > pit5 %.3f: %s\n", ao_open, ao_p1, ao_p5,
            ordered ? "ok" : "FAILED");
    if (!ordered || worst > 0.12f) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
