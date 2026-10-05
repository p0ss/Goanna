// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_upright_sprite.h"

#include <algorithm>
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

std::string uprightSpriteTexture(const std::vector<std::string> &textures, int side) {
    if (side == 1 && textures.size() >= 2)
        return textures[1];
    if (!textures.empty())
        return textures[0];
    return "no_texture.png";
}

} // namespace goanna
