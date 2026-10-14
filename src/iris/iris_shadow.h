// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A shader pack's shadow map, the arithmetic half: the settings a pack
// gives its shadow pass in const directives (shadowMapResolution,
// shadowDistance and the rest), and the shadowModelView and
// shadowProjection matrices built from them, the light's direction and the
// camera. GoannaIrisGbuffers sets them for the shadow program, the gbuffers
// programs and the screen space chain alike, so all three agree on one
// shadow space. docs/design/iris-compat.md, rung 7, is the plan.
//
// Written from the shader pack format as documented (OptiFine's
// shaders.txt and Iris's documentation of the same uniforms), not from any
// loader's source. Pure arithmetic with no Godot and no shared state.
// Main functions: iris::readShadowSettings, iris::shadowModelView,
// iris::shadowProjection.
#pragma once

#include <map>
#include <string>
#include <vector>

namespace goanna {
namespace iris {

struct ShadowSettings {
    // Texels on a side of shadowtex0 and the rest.
    int resolution = 1024;
    // Half the side of the square the map covers, in nodes.
    float distance = 160.0f;
    // The light's frame moves in steps of this many nodes as the camera
    // does, so the map's texels stay put on the ground; 0 follows the
    // camera exactly.
    float interval = 2.0f;
    // The orthographic depth range: the light's eye is 100 nodes from the
    // player towards the light, so geometry more than about 100 nodes
    // above the player towards the sun is clipped, as in Iris.
    float near_plane = 0.05f;
    float far_plane = 256.0f;
    // The pack's orbit rotation in degrees, applied to the server's sun and
    // moon before supplying lighting, shadow and celestial geometry inputs.
    float sun_path_rotation = 0.0f;
    // Things the pack asked for that are not honoured, for report().
    std::vector<std::string> notes;
};

// Reads the const directives a pack's sources declare (Pack::consts) with
// its option values (Pack::options) for a directive written as an option
// name. Anything absent keeps the default above.
ShadowSettings readShadowSettings(const std::map<std::string, std::string> &consts,
        const std::map<std::string, std::string> &options);

// Column major, as GLSL and Godot's Projection hold them: m[column * 4 + row].
using Mat4 = float[16];

// shadowModelView: player space (world less the camera position) to the
// light's view space, whose -z looks from the light at the player. `light`
// points from the scene towards the sun or moon (need not be unit length);
// `camera` is the camera's world position. The player sits 100 nodes in
// front of the light's eye, offset by the camera's position modulo the
// interval, so the frame snaps to a grid of `interval` nodes.
void shadowModelView(const float light[3], const float camera[3], float interval, Mat4 out);

// shadowProjection: an orthographic box `distance` nodes either side of
// the light's axis, between the near and far planes, in OpenGL's clip
// convention (z from -1 at the near plane to 1 at the far).
void shadowProjection(float distance, float near_plane, float far_plane, Mat4 out);

// a * b
void mul(const Mat4 a, const Mat4 b, Mat4 out);
// The inverse of a rigid transform or of the orthographic projection
// above: anything whose upper 3x3 is orthogonal times a diagonal and
// whose last row is 0 0 0 1. Every matrix this file makes is one.
void affineInverse(const Mat4 m, Mat4 out);
// m * (x, y, z, w)
void transform(const Mat4 m, const float in[4], float out[4]);

} // namespace iris
} // namespace goanna
