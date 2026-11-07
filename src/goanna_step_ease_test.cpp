// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The eased step rise (goanna_step_ease.h) on the transplanted
// LocalPlayer::move, checked without Godot: a stone floor with a full block
// and a half slab ahead, walked into at 4 nodes a second with DorfCraft's
// worn body step height of 1.05 nodes, at 60 and 20 frames a second, each
// frame cut into 10 ms parts as GoannaSession::stepPlayer cuts it. The
// physics is not eased: the player's height still snaps up a node in one
// part. What is shown rises over about 0.1 to 0.2 s, never above the
// player, and catches up. A jump, a fall, a rise past the step height and
// a server move show at once, as in stock Luanti's camera.
//
// GOANNA_STEP_EASE_TRACE=<file> writes every frame (case, time, height,
// height shown, x, z) as CSV, for the evidence in a report.

#include "goanna_step_ease.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "client/mapblock_mesh.h"
#include "client/node_visuals.h"
#include "content/mods.h"
#include "gamedef.h"
#include "goanna_map.h"
#include "itemdef.h"
#include "nodedef.h"
#include "settings.h"
#include "transplant/localplayer.h"

// As in goanna_object_collision_test: the movement code links Map and
// NodeDefManager, whose destructors reach these; nothing here builds a mesh
// or node visuals.
MapBlockMesh::~MapBlockMesh() {}
NodeVisuals::~NodeVisuals() {}

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;
FILE *g_trace = nullptr;

void check(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        std::printf("FAIL: %s\n", what.c_str());
        ++g_failures;
    }
}

class TestGameDef : public IGameDef {
public:
    TestGameDef() {
        ContentFeatures f;
        f.name = "test:stone";
        f.drawtype = NDT_NORMAL;
        f.walkable = true;
        m_ndef->set(f.name, std::move(f));
        ContentFeatures s;
        s.name = "test:slab";
        s.drawtype = NDT_NODEBOX;
        s.walkable = true;
        s.node_box.type = NODEBOX_FIXED;
        s.node_box.fixed = {aabb3f(-0.5f * BS, -0.5f * BS, -0.5f * BS, 0.5f * BS, 0.0f, 0.5f * BS)};
        s.collision_box = s.node_box;
        m_ndef->set(s.name, std::move(s));
    }
    ~TestGameDef() { delete m_ndef; delete m_idef; }
    IItemDefManager *getItemDefManager() override { return m_idef; }
    const NodeDefManager *getNodeDefManager() override { return m_ndef; }
    ICraftDefManager *getCraftDefManager() override { return nullptr; }
    u16 allocateUnknownNodeId(const std::string &) override { return 0; }
    const std::vector<ModSpec> &getMods() const override { return m_mods; }
    const ModSpec *getModSpec(const std::string &) const override { return nullptr; }
    ModStorageDatabase *getModStorageDatabase() override { return nullptr; }
    bool joinModChannel(const std::string &) override { return false; }
    bool leaveModChannel(const std::string &) override { return false; }
    bool sendModChannelMessage(const std::string &, const std::string &) override { return false; }
    ModChannel *getModChannel(const std::string &) override { return nullptr; }
    bool isClient() override { return true; }
    content_t id(const char *name) const { return m_ndef->getId(name); }

private:
    IItemDefManager *m_idef = createItemDefManager();
    NodeDefManager *m_ndef = createNodeDefManager();
    std::vector<ModSpec> m_mods;
};

// Stone at y <= 0 and air above, over blocks -1..1 in x and z; then `ahead`
// (a node name, or nothing) on the floor at z >= 3, and with `wall` a
// second node on it from z >= 8, so a stair of two.
void buildCourse(GoannaMap &map, const TestGameDef &gd, const char *ahead, bool stair) {
    const content_t stone = gd.id("test:stone");
    const content_t up = ahead ? gd.id(ahead) : CONTENT_AIR;
    for (s16 bx = -1; bx <= 1; ++bx)
    for (s16 bz = -1; bz <= 1; ++bz) {
        MapSector *sector = map.emergeSector(v2s16(bx, bz));
        for (s16 by = -1; by <= 1; ++by) {
            MapBlock *block = sector->createBlankBlock(by);
            for (s16 z = 0; z < MAP_BLOCKSIZE; ++z)
            for (s16 y = 0; y < MAP_BLOCKSIZE; ++y)
            for (s16 x = 0; x < MAP_BLOCKSIZE; ++x) {
                const s16 wy = by * MAP_BLOCKSIZE + y, wz = bz * MAP_BLOCKSIZE + z;
                content_t c = wy <= 0 ? stone : CONTENT_AIR;
                if (ahead && wy == 1 && wz >= 3)
                    c = up;
                if (ahead && stair && wy == 2 && wz >= 6)
                    c = up;
                block->setNodeNoCheck(x, y, z, MapNode(c));
            }
            block->expireIsAirCache();
        }
    }
}

struct Frame {
    float t, y, shown, x, z;
};

struct Run {
    TestGameDef gamedef;
    GoannaMap map{&gamedef};
    LocalPlayer player{&gamedef, "singleplayer"};
    StepEase ease;
    std::vector<Frame> frames;
    float t = 0;

    Run(const char *ahead, bool stair, float step_nodes) {
        buildCourse(map, gamedef, ahead, stair);
        player.setPosition(v3f(0, 0.5f, 0) * BS);
        player.step_height = step_nodes * BS;
    }

    // One frame of `dt`, in 10 ms parts, walking at `walk` nodes a second
    // along +z; `jump` sets the jump speed at the frame's start if grounded.
    void frame(float dt, float walk, bool jump = false) {
        const int parts = std::max(1, (int)std::ceil(dt / 0.01f));
        const float part = dt / parts;
        if (jump && player.touching_ground) {
            v3f s = player.getSpeed();
            s.Y = 6.5f * BS;
            player.setSpeed(s);
        }
        for (int i = 0; i < parts; ++i) {
            v3f s = player.getSpeed();
            s.X = 0;
            s.Z = walk * BS;
            player.setSpeed(s);
            player.gravity = 2 * 9.81f * BS;
            player.move(part, &map, nullptr);
        }
        t += dt;
        const v3f p = player.getPosition();
        const float off = ease.update(p.Y, player.step_height, player.touching_ground, dt);
        frames.push_back({t, p.Y / BS, (p.Y + off) / BS, p.X / BS, p.Z / BS});
    }

    void trace(const std::string &name) const {
        if (!g_trace)
            return;
        for (const Frame &f : frames)
            std::fprintf(g_trace, "%s,%.4f,%.4f,%.4f,%.4f,%.4f\n", name.c_str(), f.t, f.y, f.shown, f.x, f.z);
    }
};

// Biggest one-frame rise of a series.
template <typename F>
float biggestRise(const std::vector<Frame> &fr, F get) {
    float most = 0;
    for (size_t i = 1; i < fr.size(); ++i)
        most = std::max(most, get(fr[i]) - get(fr[i - 1]));
    return most;
}

// Walking onto a block or slab: the physics snaps, what is shown eases.
void testStepUp(const char *node, float rise, float fps) {
    const std::string name = std::string(node) + "@" + std::to_string((int)fps);
    Run r(node, false, 1.05f);
    const float dt = 1.0f / fps;
    for (int i = 0; i < (int)(1.5f * fps); ++i)
        r.frame(dt, 4.0f);
    r.trace("step " + name);
    const auto &fr = r.frames;
    // When the physics stepped, and how far.
    size_t at = 0;
    for (size_t i = 1; i < fr.size(); ++i)
        if (fr[i].y - fr[i - 1].y > 0.5f * rise) {
            at = i;
            break;
        }
    check(at > 0, name + ": the physics stepped up");
    if (!at)
        return;
    check(std::fabs(fr.back().y - (0.5f + rise)) < 0.02f, name + ": stands on top afterwards");
    const float snap = biggestRise(fr, [](const Frame &f) { return f.y; });
    const float shown = biggestRise(fr, [](const Frame &f) { return f.shown; });
    // At 60 fps the first frame shows 1 - exp(-23/60) of the rise, a third.
    const float first = 1.0f - std::exp(-23.0f * dt);
    check(snap > 0.95f * rise, name + ": the physics rises in one frame (" + std::to_string(snap) + ")");
    check(shown <= first * rise + 0.02f, name + ": no shown frame rises more than the decay allows (" +
            std::to_string(shown) + ")");
    bool below = true;
    float settled = -1;
    for (size_t i = at; i < fr.size(); ++i) {
        below = below && fr[i].shown <= fr[i].y + 1e-4f;
        if (settled < 0 && fr[i].y - fr[i].shown < 0.05f * rise)
            settled = fr[i].t - fr[at - 1].t;
    }
    check(below, name + ": never shown above the player");
    check(settled > 0.08f && settled < 0.22f, name + ": within 5% of the top after 0.08 to 0.22 s (" +
            std::to_string(settled) + ")");
    check(std::fabs(fr.back().shown - fr.back().y) < 1e-3f, name + ": caught up");
    // Before the step, on the flat, nothing is offset.
    check(std::fabs(fr[at - 1].shown - fr[at - 1].y) < 1e-6f, name + ": no offset on the flat");
    // The step itself keeps the walking pace: no frame jumps forwards.
    float most = 0;
    for (size_t i = 1; i < fr.size(); ++i)
        most = std::max(most, fr[i].z - fr[i - 1].z);
    check(most <= 4.0f * dt + 1e-3f, name + ": no frame moves forwards more than the walk (" +
            std::to_string(most) + ")");
    std::printf("%s: physics rise %.3f in one frame; shown at most %.3f a frame, within 5%% after %.3f s\n",
            name.c_str(), snap, shown, settled);
}

// A stair of two whole blocks: each rise eases, the second one starting
// from wherever the first had reached.
void testStair() {
    Run r("test:stone", true, 1.05f);
    for (int i = 0; i < 150; ++i)
        r.frame(1.0f / 60, 4.0f);
    r.trace("stair stone@60");
    const auto &fr = r.frames;
    check(std::fabs(fr.back().y - 2.5f) < 0.02f, "stair: on the second step");
    const float shown = biggestRise(fr, [](const Frame &f) { return f.shown; });
    check(shown < 0.5f, "stair: no shown frame rises half a node (" + std::to_string(shown) + ")");
    bool below = true;
    for (const Frame &f : fr)
        below = below && f.shown <= f.y + 1e-4f;
    check(below, "stair: never shown above the player");
}

// Jumping on the flat, and falling back: shown as it happens.
void testJump() {
    Run r(nullptr, false, 1.05f);
    for (int i = 0; i < 30; ++i)
        r.frame(1.0f / 60, 0.0f);
    r.frame(1.0f / 60, 0.0f, true);
    for (int i = 0; i < 90; ++i)
        r.frame(1.0f / 60, 0.0f);
    r.trace("jump flat@60");
    float peak = 0, most = 0;
    for (const Frame &f : r.frames) {
        peak = std::max(peak, f.y);
        most = std::max(most, std::fabs(f.shown - f.y));
    }
    check(peak > 1.4f, "jump: the player left the ground");
    check(most < 1e-6f, "jump: never eased (" + std::to_string(most) + ")");
}

// Off the edge of the block, down to the floor: not eased.
void testFall() {
    Run r("test:stone", false, 1.05f);
    r.player.setPosition(v3f(0, 1.5f, 4) * BS);
    for (int i = 0; i < 20; ++i)
        r.frame(1.0f / 60, 0.0f);
    for (int i = 0; i < 60; ++i)
        r.frame(1.0f / 60, -4.0f);
    r.trace("fall stone@60");
    float most = 0;
    for (const Frame &f : r.frames)
        most = std::max(most, std::fabs(f.shown - f.y));
    check(std::fabs(r.frames.back().y - 0.5f) < 0.02f, "fall: down on the floor");
    check(most < 1e-6f, "fall: never eased (" + std::to_string(most) + ")");
}

// The ease alone: a rise past the step height shows at once (a teleport or
// a correction upwards), a reset after a server move forgets the ease, and
// a zero dt leaves it where it was.
void testRules() {
    StepEase e;
    check(e.update(0.5f * BS, 1.05f * BS, true, 0.016f) == 0.0f, "rules: first height is shown as is");
    check(e.update(2.6f * BS, 1.05f * BS, true, 0.016f) == 0.0f, "rules: a rise past the step shows at once");
    const float o = e.update(3.6f * BS, 1.05f * BS, true, 0.016f);
    check(o < -0.5f * BS, "rules: a step up starts eased");
    check(e.update(3.6f * BS, 1.05f * BS, true, 0.0f) == o, "rules: zero dt holds the ease");
    e.reset();
    check(e.update(3.6f * BS, 1.05f * BS, true, 0.016f) == 0.0f, "rules: a server move is not eased");
    check(e.update(4.6f * BS, 1.05f * BS, false, 0.016f) == 0.0f, "rules: an airborne rise is not eased");
    // Stock: an ease in progress carries on through a frame off the ground.
    check(e.update(5.6f * BS, 1.05f * BS, true, 0.016f) < 0.0f, "rules: eased again on the ground");
    check(e.update(5.6f * BS, 1.05f * BS, false, 0.016f) < 0.0f, "rules: an ease in progress continues");
    check(e.update(5.0f * BS, 1.05f * BS, true, 0.016f) == 0.0f, "rules: a fall below what is shown snaps");
    // The ordinary 0.6 step height eases a slab and not a block.
    StepEase s;
    s.update(0.5f * BS, 0.6f * BS, true, 0.016f);
    check(s.update(1.0f * BS, 0.6f * BS, true, 0.016f) < 0.0f, "rules: 0.6 eases a slab");
    StepEase b;
    b.update(0.5f * BS, 0.6f * BS, true, 0.016f);
    check(b.update(1.5f * BS, 0.6f * BS, true, 0.016f) == 0.0f, "rules: 0.6 shows a whole node at once");
}

} // namespace

int main() {
    Settings *defaults = Settings::createLayer(SL_DEFAULTS);
    for (const char *k : {"free_move", "pitch_move", "fast_move", "continuous_forward",
                 "always_fly_fast", "aux1_descends", "noclip", "autojump"})
        defaults->setDefault(k, "false");
    g_settings = Settings::createLayer(SL_GLOBAL);
    if (const char *path = std::getenv("GOANNA_STEP_EASE_TRACE")) {
        g_trace = std::fopen(path, "w");
        if (g_trace)
            std::fprintf(g_trace, "case,t,y,shown,x,z\n");
    }
    testRules();
    for (float fps : {60.0f, 20.0f}) {
        testStepUp("test:stone", 1.0f, fps);
        testStepUp("test:slab", 0.5f, fps);
    }
    testStair();
    testJump();
    testFall();
    if (g_trace)
        std::fclose(g_trace);
    std::printf("step ease: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
