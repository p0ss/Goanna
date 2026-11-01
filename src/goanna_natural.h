// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Natural attacks: an animal's bite, a bear's swipe, a bull's gore or
// charge, blended by where it aims, as melee strokes are blended by drag
// angle.
//
// A body's model carries each attack's clips, one per aim height (a wolf:
// natural_bite_low, _mid, _high; natural_lunge_low, ...), all the same
// length, and the plan in its root extras {"natural": {...}} (DorfCraft's
// tools/kindred_creatures/animation/natural/bake.py). Each attack names its
// weapon (jaws, claws, horns, tusks: rails between points on bones, which
// only the server reads). The server picks a parameter p that puts the
// weapon at the target's height, sweeps the weapon of the pose blended at p
// for the contact, and plays the clip nearest p, which is what a stock
// client shows. An attack that travels (a lunge, a charge) moves the body on
// the server; the client sees it as the entity's own motion. Goanna shows the pose the server swept: the
// two clips either side of p blended at the playing clip's time.
//
// The server's word is format 5 of the action state on the stroke state bone
// (goanna_strokes.h, DorfCraft's kit/natural/init.lua): position.x the
// parameter (0 the first clip, 1 the second, ...), position.y the clip time
// when sent, position.z the attack's index in the plan; scale.x its serial,
// scale.y 1, scale.z 5. It is sent once an attack and never cleared: the
// blend applies only while one of that attack's clips is playing, so the
// attack ends with its clip.

#pragma once

#include <string>
#include <vector>

#include "goanna_animation.h"

namespace Json {
class Value;
}

namespace goanna {

constexpr int NATURAL_STATE_FORMAT = 5;

struct NaturalPlan {
    std::string state = "kindred_stroke";
    struct Attack {
        std::string kind;
        std::vector<std::string> clips;
        float length = 0.0f;
    };
    std::vector<Attack> attacks;
};
bool parseNaturalPlan(const Json::Value &v, NaturalPlan &out);

// The two clips to blend (indices into the attack's clips) and the weight of
// the second, for parameter p.
struct NaturalBlend {
    int a = 0, b = 0;
    float weight = 0.0f;
};
NaturalBlend naturalBracket(int clips, float p);
// The clip a stock client is shown for p (the nearest variant).
int naturalNearest(int clips, float p);

// The frame's joints (`locals`, posed from the playing tracks) given the
// attack's pose: tracks a and b at the playing track's frame, blended by
// `weight`, over what is there by `amount` (the playing track's blend-in
// from the clip before, 0 to 1). Only joints track a or b animates are
// touched. All the attack's clips have the same length and key times, so
// one frame is the same moment in each.
void blendNaturalPose(const scene::SkinnedMesh &mesh, const scene::TrackAnimSpec &playing, u16 a, u16 b,
        float weight, float amount, JointTransforms &locals);

} // namespace goanna
