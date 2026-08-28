// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The one scheduling rule, checked on its own. Three things matter and none
// of them is visible in a screenshot: a Luanti block position becomes the
// Godot point the camera is actually near, a class band is never crossed by
// distance, and the cone is a weight that opens rather than a filter that
// cuts.

#include "goanna_schedule.h"

#include <cstdio>

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

// The defect this whole file exists to stop coming back: the far region
// scheduler built centre_nodes from a Luanti block position without mirroring
// Z, so at 600 nodes out it sorted against a point 1200 nodes away on the
// wrong side of the axis, and the regions it built first were behind the
// player.
void testBlockCentreIsMirrored() {
    // Luanti block -40 on Z covers Godot Z 624 to 640, so its centre is 632.
    const v3f c = godotCentreOfBlock(v3s16(0, 0, -40), 16);
    check(c.Z > 0.0f, "a negative Luanti Z block sits at a positive Godot Z");
    check(std::fabs(c.Z - 632.0f) < 0.01f, "block centre lands on the block's middle");
    check(std::fabs(c.X - 8.0f) < 0.01f, "X keeps its sign");

    // A region of 8 blocks whose low corner is that block: Godot Z 512 to 640.
    const v3f r = godotCentreOfBlocks(v3s16(0, 0, -40), 8, 16);
    check(std::fabs(r.Z - 576.0f) < 0.01f, "a region centres on the middle of its cube");
    check(std::fabs(r.X - 64.0f) < 0.01f, "and not on its low corner");

    // A camera standing in that region ranks it as the nearest there is,
    // which is the whole point. Without the mirror it scored about 1150.
    ViewPriority vp;
    vp.eye = v3f(64, 64, 576);
    check(vp.measure(ViewPriority::kCoverage, r) < 16.0f, "the region the camera stands in is the nearest one");
    v3f unmirrored((float)0 * 16 + 64, (float)0 * 16 + 64, (float)-40 * 16 + 64);
    check(vp.measure(ViewPriority::kCoverage, unmirrored) > 1000.0f,
            "and dropping the mirror puts it a kilometre away");
}

void testClassBandsAreNeverCrossed() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.bootstrap = 0.0f; // not under test here
    const int far_coverage = vp.of(ViewPriority::kCoverage, v3f(4000, 0, 0));
    const int near_refine = vp.of(ViewPriority::kRefine, v3f(1, 0, 0));
    check(far_coverage < near_refine,
            "coverage four kilometres out still beats refinement underfoot");
    check(ViewPriority::classOf(far_coverage) == ViewPriority::kCoverage,
            "the class survives the round trip");
    check(ViewPriority::distanceOf(far_coverage) == 4000,
            "and so does the distance");
}

void testBootstrapRingWins() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.bootstrap = 48.0f;
    // Stale geometry beside the player outranks missing geometry beyond the
    // ring: inside the ring everything is urgent and there is very little of
    // it, and this is what stops a player standing in nothing.
    const int inside = vp.of(ViewPriority::kMaintain, v3f(0, 0, -20));
    const int outside = vp.of(ViewPriority::kCoverage, v3f(0, 0, -200));
    check(ViewPriority::classOf(inside) == ViewPriority::kBootstrap,
            "work inside the ring is promoted");
    check(inside < outside, "and outranks coverage beyond it");
}

void testConeIsAWeightNotAFilter() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.forward = v3f(0, 0, -1); // Godot's camera looks down -Z
    vp.bootstrap = 0.0f;

    const v3f ahead(0, 0, -500);
    const v3f behind(0, 0, 500);
    const v3f side(500, 0, 0);

    check(vp.weight(ahead) > 0.99f, "straight ahead is unweighted");
    check(std::fabs(vp.weight(behind) - ViewPriority::kBehindFloor) < 0.01f,
            "directly behind falls to the floor");
    check(vp.weight(side) > vp.weight(behind) && vp.weight(side) < vp.weight(ahead),
            "the side sits between the two");
    // Inside a 70 degree field of view the penalty has to be small, or the
    // edges of the screen fill visibly later than the middle.
    const v3f edge(std::sin(0.61f) * 500.0f, 0, -std::cos(0.61f) * 500.0f);
    check(vp.weight(edge) > 0.8f, "the edge of the view is barely penalised");

    check(vp.of(ViewPriority::kCoverage, behind) > vp.of(ViewPriority::kCoverage, ahead),
            "what is behind is ordered later");
    check(ViewPriority::distanceOf(vp.of(ViewPriority::kCoverage, behind)) < ViewPriority::kClassStride,
            "but it is still in the queue, not cut from it");
}

void testConeOpensWhenTheCameraHoldsStill() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.forward = v3f(0, 0, -1);
    const v3f behind(0, 0, 500);

    vp.widen = 0.0f;
    const float shut = vp.weight(behind);
    vp.widen = 1.0f;
    const float open = vp.weight(behind);
    check(open > shut, "holding still lifts what is behind the camera");
    check(open > 0.99f, "and eventually removes the cone entirely");

    // With the cone gone, ordering is distance alone, which is what fills the
    // whole scene out to the horizon for a camera that is left pointed
    // somewhere.
    check(vp.of(ViewPriority::kCoverage, behind) ==
                    vp.of(ViewPriority::kCoverage, v3f(0, 0, -500)),
            "an open cone ranks front and back alike");
}

void testHeightIsDiscountedForCoverageOnly() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.vertical = 2.0f;
    check(std::fabs(vp.measure(ViewPriority::kCoverage, v3f(0, 100, 0)) - 200.0f) < 0.01f,
            "height costs double while filling in what is not known");
    check(std::fabs(vp.measure(ViewPriority::kCoverage, v3f(100, 0, 0)) - 100.0f) < 0.01f,
            "and ground is unaffected");
    // The discount is reasoned about a horizontal frontier. It must not reach
    // a stale slab hanging directly over the player's head, which is urgent
    // at its real distance and nothing like a frontier.
    check(std::fabs(vp.measure(ViewPriority::kStale, v3f(0, 100, 0)) - 100.0f) < 0.01f,
            "but a stale region overhead is priced at its real distance");
    check(std::fabs(vp.measure(ViewPriority::kMaintain, v3f(0, 100, 0)) - 100.0f) < 0.01f,
            "and so is an out of date one");
}

// The defect the stale class exists for: a far region that has lost its
// blocks to the near field keeps drawing them, so a slab of coarse terrain
// hangs over the real ground until it is rebuilt. Classing that as ordinary
// maintenance put it behind every region that had nothing drawn at all, and
// on the showcase fixture sixty of them waited 43 seconds.
void testStaleOutranksCoverage() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    vp.bootstrap = 0.0f;
    const int stale_far = vp.of(ViewPriority::kStale, v3f(3000, 0, 0));
    const int cover_near = vp.of(ViewPriority::kCoverage, v3f(10, 0, 0));
    check(stale_far < cover_near, "a stale slab outranks a nearer hole");
    check(vp.of(ViewPriority::kCoverage, v3f(10, 0, 0)) <
                    vp.of(ViewPriority::kMaintain, v3f(1, 0, 0)),
            "and a hole still outranks ordinary maintenance");
}

// Ordering by priority alone starves the bottom band. Age restores what the
// oldest-first sort got right, without letting patience outrank proximity.
void testAgeingPromotesButNotIntoBootstrap() {
    check(ViewPriority::aged(ViewPriority::kMaintain, 0.0, 4000.0) == ViewPriority::kMaintain,
            "fresh work keeps its class");
    check(ViewPriority::aged(ViewPriority::kMaintain, 4500.0, 4000.0) == ViewPriority::kRefine,
            "one band per interval waited");
    check(ViewPriority::aged(ViewPriority::kMaintain, 9000.0, 4000.0) == ViewPriority::kCoverage,
            "and it keeps climbing");
    check(ViewPriority::aged(ViewPriority::kMaintain, 600000.0, 4000.0) == ViewPriority::kStale,
            "ten minutes reaches stale and stops there");
    check(ViewPriority::aged(ViewPriority::kCoverage, 600000.0, 4000.0) != ViewPriority::kBootstrap,
            "the bootstrap ring is a promise about proximity, not patience");
}

void testNoDirectionMeansNoCone() {
    ViewPriority vp;
    vp.eye = v3f(0, 0, 0);
    // Before the first pose arrives there is no direction to weight against.
    check(vp.weight(v3f(0, 0, 500)) > 0.99f, "an unknown direction weights nothing");
}

} // namespace

int main() {
    testBlockCentreIsMirrored();
    testClassBandsAreNeverCrossed();
    testBootstrapRingWins();
    testConeIsAWeightNotAFilter();
    testConeOpensWhenTheCameraHoldsStill();
    testHeightIsDiscountedForCoverageOnly();
    testStaleOutranksCoverage();
    testAgeingPromotesButNotIntoBootstrap();
    testNoDirectionMeansNoCone();

    if (g_failures) {
        std::printf("goanna_schedule_test: %d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_schedule_test: ok\n");
    return 0;
}
