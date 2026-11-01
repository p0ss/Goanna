// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Round branch rods from a node's arms. See goanna_branch_rods.h.

#include "goanna_branch_rods.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace goanna {

thread_local const BranchSnapshot *g_goanna_branch_block = nullptr;

namespace {

// Kythen's M.PLANES order: six faces, eight corners, twelve edges.
const BranchOffset kArm[kBranchArmCount] = {
    {-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1},
    {-1, -1, -1}, {-1, -1, 1}, {-1, 1, -1}, {-1, 1, 1},
    {1, -1, -1}, {1, -1, 1}, {1, 1, -1}, {1, 1, 1},
    {-1, -1, 0}, {-1, 1, 0}, {1, -1, 0}, {1, 1, 0},
    {-1, 0, -1}, {-1, 0, 1}, {1, 0, -1}, {1, 0, 1},
    {0, -1, -1}, {0, -1, 1}, {0, 1, -1}, {0, 1, 1},
};

constexpr float kPi = 3.14159265358979f;

struct V3 {
    float x, y, z;
};
V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 operator*(V3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
float dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
V3 normalise(V3 a) {
    const float l = std::sqrt(dot(a, a));
    return l > 0.0f ? a * (1.0f / l) : a;
}

struct Builder {
    RodMesh &mesh;
    uint16_t vertex(V3 p, V3 n, float u, float v) {
        mesh.vertices.push_back({{p.x, p.y, p.z}, {n.x, n.y, n.z}, {u, v}});
        return (uint16_t)(mesh.vertices.size() - 1);
    }
    // One triangle, wound so its face normal agrees with its vertices'
    // normals, which point out of the surface. Degenerate ones (a ball's
    // pole) are dropped.
    void triangle(uint16_t a, uint16_t b, uint16_t c) {
        const auto P = [this](uint16_t i) {
            const float *p = mesh.vertices[i].pos;
            return V3{p[0], p[1], p[2]};
        };
        const auto N = [this](uint16_t i) {
            const float *n = mesh.vertices[i].normal;
            return V3{n[0], n[1], n[2]};
        };
        const V3 face = cross(P(b) - P(a), P(c) - P(a));
        if (dot(face, face) < 1e-14f)
            return;
        const bool flip = dot(face, N(a) + N(b) + N(c)) < 0.0f;
        mesh.indices.push_back(a);
        mesh.indices.push_back(flip ? c : b);
        mesh.indices.push_back(flip ? b : c);
    }
};

} // namespace

BranchOffset branchArmOffset(int arm) {
    return kArm[arm];
}

int branchArmOpposite(int arm) {
    const BranchOffset o = kArm[arm];
    for (int i = 0; i < kBranchArmCount; ++i)
        if (kArm[i].x == -o.x && kArm[i].y == -o.y && kArm[i].z == -o.z)
            return i;
    return arm;
}

uint32_t parseBranchArms(const std::string &value) {
    if (value.empty())
        return 0;
    errno = 0;
    char *end = nullptr;
    const long long n = std::strtoll(value.c_str(), &end, 10);
    if (errno != 0 || end == value.c_str() || *end != '\0' || n <= 0)
        return 0;
    return (uint32_t)((unsigned long long)n & kBranchArmsMask);
}

RodMesh branchRodMesh(uint32_t arms, float r, uint32_t capped) {
    RodMesh mesh;
    Builder b{mesh};
    arms &= kBranchArmsMask;
    const float around = 2.0f * kPi * r; // texture units once round a rod
    bool opposed = false;
    for (int i = 0; i < kBranchArmCount; ++i) {
        if (!(arms & (1u << i)))
            continue;
        if (arms & (1u << branchArmOpposite(i)))
            opposed = true;
        const BranchOffset o = kArm[i];
        const V3 d = normalise(V3{(float)o.x, (float)o.y, (float)o.z});
        // To the node's boundary along d: half a node times the offset's
        // length, so a face arm ends at the face centre, an edge arm at the
        // edge midpoint and a corner arm at the corner.
        const float length = 0.5f * std::sqrt((float)(o.x * o.x + o.y * o.y + o.z * o.z));
        // One frame for d and -d alike, so a rod and the neighbour's rod
        // coming back along the same line put their rims on the same
        // points, and the texture runs on across the seam.
        const bool positive = o.x > 0 || (o.x == 0 && (o.y > 0 || (o.y == 0 && o.z > 0)));
        const V3 axis = positive ? d : d * -1.0f;
        const V3 ref = std::fabs(axis.y) < 0.9f ? V3{0, 1, 0} : V3{1, 0, 0};
        const V3 u = normalise(cross(axis, ref));
        const V3 w = cross(axis, u);
        const V3 end = d * length;
        uint16_t first = 0;
        for (int k = 0; k <= kRodSides; ++k) {
            const float a = 2.0f * kPi * (float)k / kRodSides;
            const V3 n = u * std::cos(a) + w * std::sin(a);
            const float tu = around * (float)k / kRodSides;
            const uint16_t inner = b.vertex(n * r, n, tu, 0.0f);
            b.vertex(end + n * r, n, tu, length);
            if (k == 0)
                first = inner;
        }
        for (int k = 0; k < kRodSides; ++k) {
            const uint16_t i0 = first + 2 * k, o0 = i0 + 1;
            const uint16_t i1 = i0 + 2, o1 = i1 + 1;
            b.triangle(i0, o0, o1);
            b.triangle(i0, o1, i1);
        }
        if (capped & (1u << i)) {
            const uint16_t centre = b.vertex(end, d, 0.5f, 0.5f);
            const uint16_t rim = (uint16_t)mesh.vertices.size();
            for (int k = 0; k < kRodSides; ++k) {
                const float a = 2.0f * kPi * (float)k / kRodSides;
                const V3 n = u * std::cos(a) + w * std::sin(a);
                b.vertex(end + n * r, d, 0.5f + r * std::cos(a), 0.5f + r * std::sin(a));
            }
            for (int k = 0; k < kRodSides; ++k)
                b.triangle(centre, rim + k, rim + (k + 1) % kRodSides);
        }
    }
    if (!opposed) {
        // The joint: a ball, kRodSides round and half that from pole to pole.
        const int rings = kRodSides / 2;
        const uint16_t first = (uint16_t)mesh.vertices.size();
        for (int j = 0; j <= rings; ++j) {
            const float polar = kPi * (float)j / rings;
            for (int k = 0; k <= kRodSides; ++k) {
                const float a = 2.0f * kPi * (float)k / kRodSides;
                const V3 n{std::sin(polar) * std::cos(a), std::cos(polar),
                        std::sin(polar) * std::sin(a)};
                b.vertex(n * r, n, around * (float)k / kRodSides, r * polar);
            }
        }
        const int row = kRodSides + 1;
        for (int j = 0; j < rings; ++j)
            for (int k = 0; k < kRodSides; ++k) {
                const uint16_t a = first + j * row + k, c = a + row;
                b.triangle(a, c, c + 1);
                b.triangle(a, c + 1, a + 1);
            }
    }
    return mesh;
}

} // namespace goanna
