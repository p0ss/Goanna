// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The geometry of an "upright_sprite" object visual, as the vanilla client
// builds it in GenericCAO::addToScene, updateTextures and updateTexturePos
// (luanti/src/client/content_cao.cpp), written out in Goanna's space.
//
// It is not a billboard. Upstream makes two quads in the object's own XY
// plane, each its own mesh buffer: the front, facing the object's +Z, with
// textures[0], and the back, facing -Z, with textures[1] (or textures[0]
// when there is no second). Neither turns towards the camera; the object's
// rotation turns both. Each buffer keeps Irrlicht's default backface
// culling, so from either side only the quad facing that way is drawn, and
// the object's backface_culling property is never applied to them. The
// size is BS * visual_size (X and Y; Z is not used), centred on the object,
// except a player's, whose bottom edge sits at its feet. With spritediv,
// both quads show the same cell of the sheet.
//
// Pure arithmetic, so goanna_upright_sprite_test can check it with no Godot.

#include <string>
#include <vector>

namespace goanna {

struct UprightSpriteVertex {
    float pos[3];    // Godot space, nodes: Luanti's Z mirrored
    float normal[3]; // Godot space
    float uv[2];
};

struct UprightSpriteQuad {
    UprightSpriteVertex v[4];
    // Godot's front faces are clockwise, as Irrlicht's are, and the Z mirror
    // with the camera's own Z flip keeps a triangle's winding on screen, so
    // these are upstream's indices unchanged.
    int index[6];
    // The quad's UV rectangle, min then max: the sheet cell it shows. The
    // entity shader's parallax march is clamped to it (CUSTOM0).
    float rect[4];
};

struct UprightSprite {
    UprightSpriteQuad side[2]; // 0 the front, 1 the back
};

// size_x and size_y are visual_size.X and .Y in nodes. col and row are the
// sheet cell (m_tx_basepos plus the animation frame down the rows), div_x
// and div_y the spritediv; both wrap, as upstream's coordinates past 1 wrap
// in a repeating texture.
UprightSprite buildUprightSprite(float size_x, float size_y, bool is_player,
        int col, int row, int div_x, int div_y);

// A wall plate: an upright sprite lying on a node face, as DorfCraft's
// engravings lie on a wall, a hundredth of a node in front of it because a
// vanilla client needs the gap or the two fight for depth. Goanna draws such
// a plate on the face itself (the entity shader moves it a hair toward the
// eye so it wins the depth test) and lights it per vertex from the nodes in
// front of the face, as the wall beside it is lit, instead of one level for
// the whole entity. See docs/materials.md, "Wall plates".
//
// The quad's front normal must be horizontal and along a world axis, and its
// plane within kWallPlateGap of a node face. Then `axis` is 0 for x or 2 for
// z (Godot's axes), `face` that face's coordinate, and `side` +1 when the
// front faces +axis. Whether a solid node is behind it is the caller's to
// check, with the nodes this names.
constexpr float kWallPlateGap = 0.03f;
struct WallPlane {
    bool ok = false;
    int axis = 0;
    float face = 0.0f;
    int side = 1;
};
WallPlane wallPlane(const float normal[3], const float centre[3]);

// Where a quad's edge from world coordinate `from` (at parameter 0) to `to`
// (at 1) crosses a node boundary (k + 0.5): the parameters strictly inside
// (0, 1), ascending. A plate is cut there so that every vertex the wall has
// is a vertex of the plate too, and its light per vertex is the wall's.
std::vector<float> nodeCuts(float from, float to);

// One quad cut into a grid at parameters `us` along its first edge (vertex 0
// to 1) and `vs` along its second (0 to 3), each strictly inside (0, 1) and
// ascending. Positions, normals and coordinates are interpolated, the
// winding kept. With no cuts it is the quad itself.
struct UprightSpriteGrid {
    std::vector<UprightSpriteVertex> v;
    std::vector<int> index;
};
UprightSpriteGrid subdivideQuad(const UprightSpriteQuad &q, const std::vector<float> &us,
        const std::vector<float> &vs);

// The texture string side 0 (front) or 1 (back) shows, before the texture
// modifier is added: GenericCAO::updateTextures.
std::string uprightSpriteTexture(const std::vector<std::string> &textures, int side);

} // namespace goanna
