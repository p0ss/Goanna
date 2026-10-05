// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_upright_sprite.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace goanna {

static int wrapCell(int i, int n) {
    n = std::max(1, n);
    return ((i % n) + n) % n;
}

UprightSprite buildUprightSprite(float size_x, float size_y, bool is_player,
        int col, int row, int div_x, int div_y) {
    // GenericCAO::addToScene, in nodes rather than BS units.
    const float dx = size_x / 2.0f, dy = size_y / 2.0f;
    const float lift = is_player ? dy : 0.0f;
    // updateTexturePos: the cell's corners in the order of the vertices.
    const float tx = 1.0f / std::max(1, div_x), ty = 1.0f / std::max(1, div_y);
    const float c = (float)wrapCell(col, div_x), r = (float)wrapCell(row, div_y);
    const float u0 = c * tx, u1 = (c + 1.0f) * tx, v0 = r * ty, v1 = (r + 1.0f) * ty;
    struct Corner {
        float x, y, u, v;
    } corners[4] = {
        {-dx, -dy + lift, u1, v1},
        {dx, -dy + lift, u0, v1},
        {dx, dy + lift, u0, v0},
        {-dx, dy + lift, u1, v0},
    };
    UprightSprite out;
    for (int face : {0, 1}) {
        // Upstream turns the front into the back by negating the normal and
        // swapping the positions of vertices 0 and 1, and 2 and 3, keeping
        // each vertex's texture coordinates: the back is the front's mirror,
        // so the image reads the right way round from behind too.
        if (face == 1)
            for (int i : {0, 2})
                std::swap(corners[i].x, corners[i + 1].x);
        UprightSpriteQuad &q = out.side[face];
        // Irrlicht's normal is +Z for the front, -Z for the back; Z mirrors.
        const float nz = face == 0 ? -1.0f : 1.0f;
        for (int i = 0; i < 4; ++i) {
            q.v[i] = UprightSpriteVertex{{corners[i].x, corners[i].y, 0.0f}, {0.0f, 0.0f, nz},
                    {corners[i].u, corners[i].v}};
        }
        const int idx[6] = {0, 1, 2, 2, 3, 0};
        std::copy(idx, idx + 6, q.index);
        q.rect[0] = u0;
        q.rect[1] = v0;
        q.rect[2] = u1;
        q.rect[3] = v1;
    }
    return out;
}

WallPlane wallPlane(const float normal[3], const float centre[3]) {
    WallPlane w;
    if (std::fabs(normal[1]) > 0.01f)
        return w;
    for (int a : {0, 2}) {
        if (std::fabs(normal[a]) < 0.9999f)
            continue;
        const float face = std::round(centre[a] - 0.5f) + 0.5f;
        if (std::fabs(centre[a] - face) > kWallPlateGap)
            return w;
        w.ok = true;
        w.axis = a;
        w.face = face;
        w.side = normal[a] > 0.0f ? 1 : -1;
    }
    return w;
}

std::vector<float> nodeCuts(float from, float to) {
    std::vector<float> out;
    const float lo = std::min(from, to), hi = std::max(from, to);
    if (hi - lo < 1e-6f)
        return out;
    for (float b = std::floor(lo - 0.5f) + 1.5f; b < hi; b += 1.0f) {
        const float t = (b - from) / (to - from);
        if (t > 1e-4f && t < 1.0f - 1e-4f)
            out.push_back(t);
    }
    std::sort(out.begin(), out.end());
    return out;
}

UprightSpriteGrid subdivideQuad(const UprightSpriteQuad &q, const std::vector<float> &us,
        const std::vector<float> &vs) {
    std::vector<float> u{0.0f}, v{0.0f};
    u.insert(u.end(), us.begin(), us.end());
    v.insert(v.end(), vs.begin(), vs.end());
    u.push_back(1.0f);
    v.push_back(1.0f);
    // Bilinear over the corners: 0 at (0, 0), 1 at (1, 0), 2 at (1, 1),
    // 3 at (0, 1), the order buildUprightSprite gives them.
    auto lerp = [&](const float *c0, const float *c1, const float *c2, const float *c3,
                        float s, float t, int n, float *out) {
        for (int i = 0; i < n; ++i)
            out[i] = (c0[i] * (1 - s) + c1[i] * s) * (1 - t) + (c3[i] * (1 - s) + c2[i] * s) * t;
    };
    UprightSpriteGrid g;
    const int nu = (int)u.size(), nv = (int)v.size();
    for (int j = 0; j < nv; ++j)
        for (int i = 0; i < nu; ++i) {
            UprightSpriteVertex x{};
            lerp(q.v[0].pos, q.v[1].pos, q.v[2].pos, q.v[3].pos, u[i], v[j], 3, x.pos);
            lerp(q.v[0].normal, q.v[1].normal, q.v[2].normal, q.v[3].normal, u[i], v[j], 3,
                    x.normal);
            lerp(q.v[0].uv, q.v[1].uv, q.v[2].uv, q.v[3].uv, u[i], v[j], 2, x.uv);
            g.v.push_back(x);
        }
    for (int j = 0; j + 1 < nv; ++j)
        for (int i = 0; i + 1 < nu; ++i) {
            const int a = j * nu + i, b = a + 1, c = b + nu, d = a + nu;
            // The quad's own {0, 1, 2, 2, 3, 0}.
            for (int k : {a, b, c, c, d, a})
                g.index.push_back(k);
        }
    return g;
}

std::string uprightSpriteTexture(const std::vector<std::string> &textures, int side) {
    if (side == 1 && textures.size() >= 2)
        return textures[1];
    if (!textures.empty())
        return textures[0];
    return "no_texture.png";
}

} // namespace goanna
