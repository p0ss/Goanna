// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The upright sprite's geometry (goanna_upright_sprite.h) against what
// GenericCAO::addToScene, updateTextures and updateTexturePos build in the
// vanilla client, and against what a camera on either side should see:
// one quad drawn from each side, not mirrored, with its own texture, and
// neither turning with the camera. Pure arithmetic, so it links nothing:
//   cmake --build build --target goanna_upright_sprite_test
//   ./build/goanna_upright_sprite_test

#include "goanna_upright_sprite.h"

#include <cmath>
#include <cstdio>
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

bool near(float a, float b) {
    return std::fabs(a - b) < 1e-5f;
}

// Twice the signed area of a triangle as a camera on the given side of the
// sprite's plane sees it, screen Y up: positive is counter-clockwise. A
// camera at Godot -Z looking along +Z has screen X along world -X; one at
// +Z looking along -Z has it along world +X.
float screenArea(const UprightSpriteQuad &q, int tri, bool from_minus_z) {
    float sx[3], sy[3];
    for (int i = 0; i < 3; ++i) {
        const UprightSpriteVertex &v = q.v[q.index[tri * 3 + i]];
        sx[i] = from_minus_z ? -v.pos[0] : v.pos[0];
        sy[i] = v.pos[1];
    }
    return (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
}

// Godot draws clockwise triangles as front faces and culls the rest under
// cull_back.
bool drawnFrom(const UprightSpriteQuad &q, bool from_minus_z) {
    return screenArea(q, 0, from_minus_z) < 0.0f && screenArea(q, 1, from_minus_z) < 0.0f;
}

// The vertex at the screen's left and at its right, for the side seen.
void leftRight(const UprightSpriteQuad &q, bool from_minus_z, const UprightSpriteVertex **l,
        const UprightSpriteVertex **r) {
    *l = *r = &q.v[0];
    for (const UprightSpriteVertex &v : q.v) {
        const float sx = from_minus_z ? -v.pos[0] : v.pos[0];
        const float lx = from_minus_z ? -(*l)->pos[0] : (*l)->pos[0];
        const float rx = from_minus_z ? -(*r)->pos[0] : (*r)->pos[0];
        if (sx < lx)
            *l = &v;
        if (sx > rx)
            *r = &v;
    }
}

void testUpstreamTable() {
    // content_cao.cpp, OBJECTVISUAL_UPRIGHT_SPRITE, BS units with
    // visual_size {2, 1}: dx = BS, dy = BS / 2. In nodes, mirrored in Z.
    const float up[4][5] = {
        {-1.0f, -0.5f, 0, 1, 1},
        {1.0f, -0.5f, 0, 0, 1},
        {1.0f, 0.5f, 0, 0, 0},
        {-1.0f, 0.5f, 0, 1, 0},
    };
    const UprightSprite s = buildUprightSprite(2.0f, 1.0f, false, 0, 0, 1, 1);
    bool front_ok = true, back_ok = true;
    for (int i = 0; i < 4; ++i) {
        const UprightSpriteVertex &f = s.side[0].v[i];
        front_ok = front_ok && near(f.pos[0], up[i][0]) && near(f.pos[1], up[i][1]) &&
                near(f.pos[2], 0) && near(f.uv[0], up[i][3]) && near(f.uv[1], up[i][4]) &&
                near(f.normal[2], -1.0f);
        // The back: positions of 0 and 1, 2 and 3 swapped, coordinates kept.
        const int j = i ^ 1;
        const UprightSpriteVertex &b = s.side[1].v[i];
        back_ok = back_ok && near(b.pos[0], up[j][0]) && near(b.pos[1], up[j][1]) &&
                near(b.uv[0], up[i][3]) && near(b.uv[1], up[i][4]) && near(b.normal[2], 1.0f);
    }
    check(front_ok, "the front quad is upstream's vertices, Z mirrored");
    check(back_ok, "the back quad is upstream's, positions swapped in pairs");
    const int idx[6] = {0, 1, 2, 2, 3, 0};
    bool idx_ok = true;
    for (int side : {0, 1})
        for (int i = 0; i < 6; ++i)
            idx_ok = idx_ok && s.side[side].index[i] == idx[i];
    check(idx_ok, "both quads keep upstream's index order");
}

void testSides() {
    const UprightSprite s = buildUprightSprite(1.0f, 1.0f, false, 0, 0, 1, 1);
    // Upstream's front normal is +Z in Luanti, -Z in Godot: the camera on
    // the Godot -Z side sees the front, the one on +Z the back, and each
    // sees only one quad (each buffer is backface culled upstream).
    check(drawnFrom(s.side[0], true), "the front is drawn from the side it faces");
    check(!drawnFrom(s.side[0], false), "the front is culled from behind");
    check(drawnFrom(s.side[1], false), "the back is drawn from behind");
    check(!drawnFrom(s.side[1], true), "the back is culled from the front");
    // Neither side shows the image mirrored: u runs 0 to 1 from the screen's
    // left to its right whichever side the camera is on.
    for (int side : {0, 1}) {
        const bool from_minus_z = side == 0;
        const UprightSpriteVertex *l, *r;
        leftRight(s.side[side], from_minus_z, &l, &r);
        check(near(l->uv[0], 0.0f) && near(r->uv[0], 1.0f),
                std::string(side ? "the back" : "the front") + " reads left to right");
        // And v runs down the screen, image row 0 at the top.
        float top_v = -1.0f, bottom_v = -1.0f;
        for (const UprightSpriteVertex &v : s.side[side].v) {
            if (v.pos[1] > 0)
                top_v = v.uv[1];
            else
                bottom_v = v.uv[1];
        }
        check(near(top_v, 0.0f) && near(bottom_v, 1.0f),
                std::string(side ? "the back" : "the front") + " is the right way up");
        // The normal points at the camera that draws the quad.
        check(s.side[side].v[0].normal[2] * (from_minus_z ? -1.0f : 1.0f) > 0.0f,
                std::string(side ? "the back" : "the front") + "'s normal faces its viewer");
    }
}

void testSizeAndPlayer() {
    // The fishing bobber's {0.5, 0.5}; a decorated pot face's default {1, 1}.
    const UprightSprite s = buildUprightSprite(0.5f, 0.5f, false, 0, 0, 1, 1);
    float minx = 9, maxx = -9, miny = 9, maxy = -9;
    for (const UprightSpriteVertex &v : s.side[0].v) {
        minx = std::fmin(minx, v.pos[0]);
        maxx = std::fmax(maxx, v.pos[0]);
        miny = std::fmin(miny, v.pos[1]);
        maxy = std::fmax(maxy, v.pos[1]);
    }
    check(near(minx, -0.25f) && near(maxx, 0.25f) && near(miny, -0.25f) && near(maxy, 0.25f),
            "visual_size {0.5, 0.5} is half a node square, centred");
    const UprightSprite p = buildUprightSprite(1.0f, 2.0f, true, 0, 0, 1, 1);
    float pmin = 9, pmax = -9;
    for (int side : {0, 1})
        for (const UprightSpriteVertex &v : p.side[side].v) {
            pmin = std::fmin(pmin, v.pos[1]);
            pmax = std::fmax(pmax, v.pos[1]);
        }
    check(near(pmin, 0.0f) && near(pmax, 2.0f), "a player's sprite stands on its feet");
}

void testSheet() {
    // mcl_burning's fire: spritediv {1, 8}, frame 3 down the rows.
    const UprightSprite s = buildUprightSprite(1.0f, 1.0f, false, 0, 3, 1, 8);
    for (int side : {0, 1}) {
        const float *r = s.side[side].rect;
        check(near(r[0], 0) && near(r[1], 3.0f / 8) && near(r[2], 1) && near(r[3], 4.0f / 8),
                "both quads' rectangle is the frame's cell");
        bool inside = true;
        for (const UprightSpriteVertex &v : s.side[side].v)
            inside = inside && v.uv[0] >= r[0] - 1e-5f && v.uv[0] <= r[2] + 1e-5f &&
                    v.uv[1] >= r[1] - 1e-5f && v.uv[1] <= r[3] + 1e-5f;
        check(inside, "every coordinate lies in the frame's cell");
    }
    // A row past the sheet wraps, as a repeating texture would draw it.
    const UprightSprite w = buildUprightSprite(1.0f, 1.0f, false, 2, 9, 2, 8);
    check(near(w.side[0].rect[0], 0) && near(w.side[0].rect[1], 1.0f / 8),
            "cells past the sheet wrap");
}

void testTextures() {
    check(uprightSpriteTexture({"pot_face.png"}, 0) == "pot_face.png", "one texture: the front");
    check(uprightSpriteTexture({"pot_face.png"}, 1) == "pot_face.png",
            "one texture: the back shows it too");
    check(uprightSpriteTexture({"a.png", "b.png"}, 0) == "a.png", "two textures: front is the first");
    check(uprightSpriteTexture({"a.png", "b.png"}, 1) == "b.png", "two textures: back is the second");
    check(uprightSpriteTexture({}, 0) == "no_texture.png" && uprightSpriteTexture({}, 1) == "no_texture.png",
            "no textures: no_texture.png both sides");
}

} // namespace

int main() {
    testUpstreamTable();
    testSides();
    testSizeAndPlayer();
    testSheet();
    testTextures();
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
