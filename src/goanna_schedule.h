// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#ifndef GOANNA_SCHEDULE_H
#define GOANNA_SCHEDULE_H

// One priority for every scheduler that has to choose what to build next.
//
// Goanna decides what to build in five separate places: the near block queue
// in poll_blocks, the near mesh submission, the far region rebuild, the far
// region mesh submission, and the summary request scan. Each of them used to
// carry its own idea of what mattered, and none of them knew which way the
// camera was pointing. So the far field filled radially while the player
// looked one way, near geometry queued behind every distant far region, and
// the region rebuild ran oldest-first regardless of where the player stood.
//
// This is the single rule they now share. A candidate is turned into a
// deficit class and a distance, and comes back as one integer, lower first.
// Because every scheduler encodes into the same integer, near coverage, far
// coverage, refinement and summary requests are ordered against each other
// rather than each against itself.
//
// Everything here is in Godot space: Y up, and Z running the other way from
// Luanti's. Use godotCentreOfBlocks to cross that boundary. Computing it by
// hand is what made the far field build the world behind the player first.
//
// No Godot types and no client state, so it is testable on its own:
// src/goanna_schedule_test.cpp.

#include <algorithm>
#include <cmath>

#include "irrlichttypes_bloated.h"

namespace goanna {

// The Godot-space centre of a cube of `blocks` mapblocks whose low corner is
// the mapblock `bp`. The Z mirror is the whole point of this existing.
inline v3f godotCentreOfBlocks(const v3s16 &bp, int blocks, int block_size) {
    const float half = 0.5f * (float)blocks * (float)block_size;
    return v3f((float)bp.X * (float)block_size + half,
            (float)bp.Y * (float)block_size + half,
            -((float)bp.Z * (float)block_size + half));
}

inline v3f godotCentreOfBlock(const v3s16 &bp, int block_size) {
    return godotCentreOfBlocks(bp, 1, block_size);
}

struct ViewPriority {
    // What is missing, coarsest first. A class is a hard band: every
    // candidate in one is ordered ahead of every candidate in the next,
    // whatever their distances, so refinement can never crowd out a world
    // that is not drawn at all.
    enum Class : int {
        kBootstrap = 0, // inside the ring around the player: always first
        // Drawn, and what is drawn is no longer true: the blocks moved to the
        // near field or to another tier and this mesh still contains them.
        // Ahead of coverage, because a hole is something the player can see
        // past and a stale slab is not: it hangs in the air over the top of
        // the real terrain until the rebuild lands.
        kStale = 1,
        kCoverage = 2, // nothing is drawn here at any detail
        kRefine = 3,   // drawn, but coarser than this distance deserves
        kMaintain = 4, // drawn at the right detail, and out of date
        kClassCount = 5,
    };

    // Distances are stored in the low bits, so one class spans a range no
    // world can exceed. 2^22 nodes is 4 million, against a 4096 node far
    // distance ceiling and a 62000 node map edge.
    static constexpr int kClassStride = 1 << 22;

    // What a candidate directly behind the camera is worth against one
    // straight ahead, before the cone opens. A weight, never a filter: a
    // filter puts a hole where the player turns around.
    static constexpr float kBehindFloor = 0.15f;

    v3f eye{0, 0, 0};     // camera position, Godot nodes
    v3f forward{0, 0, 0}; // unit; a zero vector means no direction is known
    // How far the cone has opened, 0 to 1. The client raises this while the
    // camera holds still, so leaving it pointed somewhere fills the whole
    // scene out to the horizon rather than only the part in front of it.
    float widen = 0.0f;
    // What a node of height costs against a node of ground, for coverage
    // only. Filling in what is not known runs horizontally: above and below
    // the player is mostly sky the server has not made and rock nobody can
    // see. Repairing what is drawn wrongly is urgent wherever it sits, and a
    // stale slab hanging over the player's head is exactly that case, so this
    // must not price one at twice its real distance.
    float vertical = 1.0f;
    // Nodes. Inside this, everything is kBootstrap, which is the guarantee
    // that walking into a world never leaves the player standing in nothing.
    float bootstrap = 48.0f;

    // 0 to 1. One straight ahead, kBehindFloor directly behind, rising to
    // one everywhere as `widen` reaches one.
    float weight(const v3f &at) const {
        if (forward.getLengthSQ() < 0.5f)
            return 1.0f;
        v3f d = at - eye;
        const float len = d.getLength();
        if (len < 1e-3f)
            return 1.0f;
        d /= len;
        // 0 directly behind, 1 straight ahead, and squared so the fall off
        // is gentle across a field of view and steep outside one.
        const float ahead = 0.5f * (1.0f + d.dotProduct(forward));
        const float floor_w =
                kBehindFloor + (1.0f - kBehindFloor) * std::clamp(widen, 0.0f, 1.0f);
        return floor_w + (1.0f - floor_w) * ahead * ahead;
    }

    // Distance from the eye, with height discounted by `vertical` for the
    // one class that discount is reasoned for.
    float measure(Class c, const v3f &at) const {
        const float scale = c == kCoverage ? vertical : 1.0f;
        const float dx = at.X - eye.X;
        const float dy = (at.Y - eye.Y) * scale;
        const float dz = at.Z - eye.Z;
        return std::sqrt(dx * dx + dy * dy + dz * dz);
    }

    int of(Class c, const v3f &at) const { return of(c, at, measure(c, at)); }

    // For a scheduler with its own distance metric. The summary scan prices
    // a vertical layer by whether the server has answered that the layers
    // between hold anything, which no geometric rule here can know; it still
    // wants this cone and these classes.
    int of(Class c, const v3f &at, float measured) const {
        if (measured <= bootstrap)
            c = kBootstrap;
        const float w = std::max(weight(at), 0.01f);
        const float scaled = std::max(measured, 0.0f) / w;
        const int d = (int)std::min(scaled, (float)(kClassStride - 1));
        return (int)c * kClassStride + d;
    }

    static Class classOf(int priority) {
        return (Class)std::clamp(priority / kClassStride, 0, (int)kMaintain);
    }
    // One band better for every `per` milliseconds waited, never into
    // kBootstrap, which is a promise about proximity and not about patience.
    // Ordering by priority alone has no fairness at all: the sort this
    // replaced was oldest first, which was wrong about what to do next but
    // right that everything drains.
    static Class aged(Class c, double waited_ms, double per) {
        if (per <= 0.0)
            return c;
        const int bands = (int)(waited_ms / per);
        return (Class)std::max((int)kStale, (int)c - bands);
    }
    // The effective distance in nodes: the real one divided by the view
    // weight, which is the number the scheduler actually sorted on.
    static int distanceOf(int priority) {
        return std::max(0, priority) % kClassStride;
    }
    static const char *className(Class c) {
        switch (c) {
        case kBootstrap: return "boot";
        case kStale: return "stale";
        case kCoverage: return "cover";
        case kRefine: return "refine";
        default: return "maint";
        }
    }
};

} // namespace goanna

#endif
