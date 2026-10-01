// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Knees and elbows for block-limbed player models, and the strokes a body
// makes in the water. docs/limbs.md has the whole picture.
//
// A Minecraft-style player model (Minetest Game's character.b3d, Mineclonia's
// mcl_armor_character.b3d) has each arm and leg as one box, or two or three
// nested boxes for sleeves, trousers and armour, rigidly on one joint, with
// no vertices between its ends: it swings at the shoulder and hip and cannot
// bend. When such a model is converted for Godot, each limb's triangles are
// cut at mid height (the 6 pixel line of a 12 pixel limb, so the skin stays
// pixel exact) and the half below the cut is moved to a bone of Goanna's own.
// That bone's pose is the limb's pose times a bend about the cut: Luanti's
// joints, keyframes and bone overrides are untouched, and the game still
// decides the gait, the aim and the swing. The vertices on the cut go to a
// second bone of Goanna's, turned by half the bend, so a bent joint closes
// as a mitre: the cut lies on the plane halving the angle, no gap opens on
// the outside, nothing pokes through on the inside and the joint keeps its
// thickness. (Weighting the cut half to each side, the usual blend, pinches
// it: to 71 per cent of its width at a right angle.)
//
// Limbs are found by the bone names both games use (Arm_Left, Arm_Right,
// Leg_Left, Leg_Right); a model without them is left as it was.
//
// The bends are procedural. Walking and running: a knee bends as its leg
// swings forward (the foot lifts to come through) and an elbow as its arm
// comes forward, both from the swing the game's own animation gives the
// limb. In the water Goanna also drives the shoulders and hips, which the
// game's swim animation holds nearly still: a crawl stroke (arms over the
// back, a flutter kick) while the game has the body lying in the water, and
// treading water (sculling arms, egg-beater legs) while a body upright in
// deep water has nothing under its feet.
#pragma once

#include <vector>

#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <SkinnedMesh.h>

namespace goanna {

enum class LimbKind { Arm, Leg };

// One limb that bends: its joint (which keeps the half above the cut), the
// Godot bones Goanna adds for the half below and for the cut itself, and
// where the cut is.
struct LimbBend {
    int joint = -1;
    int bone = -1;
    int seam_bone = -1;
    LimbKind kind = LimbKind::Leg;
    bool right = false;
    // Godot mesh space (Luanti's with z mirrored), rest pose: the middle of
    // the limb at the cut, which the bend turns about, and the far end.
    godot::Vector3 pivot;
    godot::Vector3 end;
    float cut_y = 0.0f;
};

// The limbs of `mesh` that bend, by bone name, with their cut and pivot from
// the vertices rigidly weighted to each across every buffer. Bones are left
// at -1 for the caller to assign. Empty for a model without the names, or
// whose limbs are not upright boxes in the rest pose.
std::vector<LimbBend> findLimbs(const scene::SkinnedMesh &mesh);

// One mesh buffer's surface as buildGodotModel assembles it: Godot space,
// four bone slots a vertex. Plain vectors, so the split runs without the
// engine (goanna_limbs_test).
struct LimbMeshData {
    std::vector<godot::Vector3> verts, normals;
    std::vector<godot::Vector2> uvs;
    std::vector<int> indices, bones;
    std::vector<float> weights;
};

// Cuts one buffer's triangles (Godot space arrays, four bone slots a vertex)
// at each limb's cut height: vertices of the limb below the cut move to its
// bone, triangles crossing the cut are split with new vertices on it (their
// position, normal and UV interpolated along the edge, shared between the
// triangles either side), and vertices on the cut move to its seam bone.
// Only vertices rigidly on a limb joint are touched.
void splitLimbs(const std::vector<LimbBend> &limbs, LimbMeshData &mesh);

// The rest space bend of a limb's lower half by `degrees` about its pivot.
// Positive bends a knee the way a knee goes (the foot back) and an elbow the
// way an elbow goes (the hand forward). Godot mesh space.
godot::Transform3D bendTransform(const LimbBend &limb, float degrees);

// What a body is doing in the water, for the strokes.
enum class WaterPose { None = 0, Swim = 1, Tread = 2 };

// Degrees for one limb this frame, relative to its rest: the shoulder or hip
// turned forward (pitch) and outward (spread), and the knee or elbow bend.
struct LimbAngles {
    float pitch = 0.0f;
    float spread = 0.0f;
    float bend = 0.0f;
};

// A walking or running limb's bend from its swing (degrees forward of
// hanging straight, relative to the body) and how fast that swing is
// changing (degrees a second, positive forward).
float walkBend(LimbKind kind, float swing, float swing_rate);

// A limb's pose in a water stroke at `phase` (radians, the body's own stroke
// clock). Legs and arms, left and right, each take their own place in the
// cycle from it.
LimbAngles strokeAngles(WaterPose pose, LimbKind kind, bool right, float phase);

// How fast the stroke clock runs, radians a second, for a body moving at
// `speed` nodes a second.
float strokeRate(WaterPose pose, float speed);

} // namespace goanna
