// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Luanti 5.17's animation tracks, checked end to end without Godot: the
// AO_CMD_* animation messages a 5.17 server sends (and the shorter ones an
// older server sends) go through the transplanted active object, the tracks
// resolve against a mesh by number and by name, and goanna_animation poses
// the joints from them the way ModelAnimator does each frame. None of this is
// visible in a screenshot until a mod uses a second track, which is exactly
// when it would be too late to notice.

#include "goanna_animation.h"

#include <cmath>
#include <cstdio>
#include <optional>
#include <sstream>
#include <string>
#include <variant>

#include <AnimSpec.h>
#include <SkinnedMesh.h>

#include "activeobject.h"
#include "client/mapblock_mesh.h"
#include "client/node_visuals.h"
#include "content/mods.h"
#include "gamedef.h"
#include "itemdef.h"
#include "player.h"
#include "settings.h"
#include "transplant/client/content_cao.h"
#include "transplant/localplayer.h"
#include "util/serialize.h"

// The transplanted movement code links Map and NodeDefManager, whose
// destructors reach these two. Their real definitions are in transplanted
// files that need the renderer, and nothing here builds a mesh or a node
// definition, so empty ones satisfy the link.
MapBlockMesh::~MapBlockMesh() {}
NodeVisuals::~NodeVisuals() {}

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

bool near(const v3f &a, const v3f &b) {
    return a.getDistanceFrom(b) < 1e-3f;
}

bool nearf(float a, float b) {
    return std::fabs(a - b) < 1e-3f;
}

enum Joint { ROOT = 0, ARM = 1, LEG = 2 };
const v3f ARM_REST(1, 2, 3);
const v3f LEG_REST(-1, -2, -3);

// Three joints and three tracks. Two tracks animate the arm and two the leg,
// so priority decides who owns each; the rest positions are away from every
// keyframe, so a joint back at rest cannot be mistaken for one animated to
// zero.
//   track 1 "wave": arm x 0 to 10 over frames 0 to 10
//   track 2 "lift": arm y 0 to 4, leg z 0 to 4, over frames 0 to 4
//   track 3 "kick": leg x 5 to 7 over frames 0 to 2
// (Numbered from 1 as the Lua API numbers them; 0 to 2 internally.)
scene::SkinnedMesh *buildMesh(int track_count = 3) {
    scene::SkinnedMeshBuilder b(scene::SkinnedMesh::SourceFormat::OTHER);
    auto *root = b.addJoint();
    root->Name = "root";
    auto *arm = b.addJoint(root);
    arm->Name = "arm";
    arm->transform = core::Transform{ARM_REST};
    auto *leg = b.addJoint(root);
    leg->Name = "leg";
    leg->transform = core::Transform{LEG_REST};
    auto add_track = [&](const char *name) -> scene::SkinnedMesh::Animation & {
        auto &anim = b.getAnimation(b.addAnimation());
        anim.name = name;
        return anim;
    };
    auto keys = [](v3f from, v3f to, float end) {
        scene::SkinnedMesh::Keys k;
        k.position.pushBack(0.0f, from);
        k.position.pushBack(end, to);
        return k;
    };
    if (track_count >= 1) {
        auto &wave = add_track("wave");
        wave.joint_keys.push_back({arm->JointID, keys(v3f(0, 0, 0), v3f(10, 0, 0), 10)});
    }
    if (track_count >= 2) {
        auto &lift = add_track("lift");
        lift.joint_keys.push_back({arm->JointID, keys(v3f(0, 0, 0), v3f(0, 4, 0), 4)});
        lift.joint_keys.push_back({leg->JointID, keys(v3f(0, 0, 0), v3f(0, 0, 4), 4)});
    }
    if (track_count >= 3) {
        auto &kick = add_track("kick");
        kick.joint_keys.push_back({leg->JointID, keys(v3f(5, 0, 0), v3f(7, 0, 0), 2)});
    }
    return std::move(b).finalize();
}

// A track as the wire names it: a number from 1, or a name.
struct TrackRef {
    u16 number = 0; // Lua numbering; 0 means use the name
    std::string name;
};
TrackRef num(u16 n) { return {n, ""}; }
TrackRef named(const char *n) { return {0, n}; }

void writeTrack(std::ostream &os, const TrackRef &t) {
    // UnitSAO's writeTrackIdentifier
    if (t.number == 0) {
        writeU16(os, 0);
        os << serializeString16(t.name);
    } else {
        writeU16(os, t.number);
    }
}

struct Play {
    float min = 0, max = 0, fps = 1, blend = 0;
    bool loop = true;
    s32 priority = 0;
    float start = 0;
};

// UnitSAO::generateUpdateAnimationCommand. Without a track, the message a
// server older than 5.17 sends.
std::string setAnimation(const Play &p, const std::optional<TrackRef> &track) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, AO_CMD_SET_ANIMATION);
    writeF32(os, p.min);
    writeF32(os, p.max);
    writeF32(os, p.fps);
    writeF32(os, p.blend);
    writeU8(os, !p.loop);
    if (track) {
        writeTrack(os, *track);
        writeS32(os, p.priority);
        writeF32(os, p.start);
    }
    return os.str();
}

std::string setSpeed(float fps, const std::optional<TrackRef> &track) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, AO_CMD_SET_ANIMATION_SPEED);
    writeF32(os, fps);
    if (track)
        writeTrack(os, *track);
    return os.str();
}

std::string stopAnimation(const TrackRef &track) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, AO_CMD_STOP_ANIMATION);
    writeTrack(os, track);
    return os.str();
}

// What the renderer does for one object each frame: apply what arrived, then
// AnimatedMeshSceneNode::OnAnimate through goanna_animation, as ModelAnimator
// does it.
struct Rig {
    scene::SkinnedMesh *mesh;
    GoannaActiveObject obj{1, ACTIVEOBJECT_TYPE_GENERIC};
    LocalPlayer *player = nullptr;
    OldJointTransforms old;
    JointTransforms pose;

    explicit Rig(scene::SkinnedMesh *m) : mesh(m) {}
    void send(const std::string &msg) { obj.processMessage(msg, player); }
    void attach() { obj.setAnimatedMesh(mesh); }
    // Only what arrived, without advancing: a looping track started on its
    // last frame wraps to its first on any advance, even of zero seconds.
    void apply() { obj.applyDeferredAnimation(player); }
    void step(float dt) {
        apply();
        scene::AnimSpec none;
        scene::AnimSpec *anim = obj.meshAnimation();
        scene::AnimSpec &a = anim ? *anim : none;
        a.advance(dt);
        pose = animateTracks(*mesh, a, old);
        keepOldTransforms(pose, old);
    }
    v3f at(Joint j) const { return std::get<core::Transform>(pose.at(j)).translation; }
    const scene::TrackAnimSpec *track(u16 nr) const {
        const scene::AnimSpec *anim = obj.meshAnimation();
        if (!anim)
            return nullptr;
        auto it = anim->tracks.find(nr);
        return it == anim->tracks.end() ? nullptr : &it->second;
    }
};

// A pre-5.17 server sends no track fields at all. That is track 1, played
// from the start of its range.
void testOlderServerMessage() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.send(setAnimation({0, 10, 5}, std::nullopt));
    check(r.obj.meshAnimation() == nullptr, "no mesh animation before the renderer adds the object");
    check(r.obj.deferredAnimationCount() == 1, "the command waits for the mesh");
    r.attach();
    r.step(0.0f);
    check(r.obj.deferredAnimationCount() == 0, "the queue is applied once the mesh is known");
    const auto *t = r.track(0);
    check(t && nearf(t->min_frame, 0) && nearf(t->max_frame, 10) && nearf(t->fps, 5),
            "an old set_animation lands on track 1");
    r.step(1.0f);
    check(near(r.at(ARM), v3f(5, 0, 0)), "track 1 at 5 fps is at frame 5 after a second");
    check(near(r.at(LEG), LEG_REST), "a joint no playing track animates stays at rest");
    mesh->drop();
}

// Tracks by name resolve against the mesh; unknown names and numbers past the
// mesh's tracks are dropped, as upstream drops them.
void testTracksByNameAndNumber() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    r.send(setAnimation({0, 4, 0}, named("lift")));
    r.send(setAnimation({0, 2, 0}, num(3)));
    r.send(setAnimation({0, 2, 0}, named("nope")));
    r.send(setAnimation({0, 2, 0}, num(7)));
    r.step(0.0f);
    const scene::AnimSpec *anim = r.obj.meshAnimation();
    check(anim && anim->tracks.size() == 2, "two of the four tracks resolve");
    check(r.track(1) != nullptr, "\"lift\" is track 2");
    check(r.track(2) != nullptr, "track 3 by number");
    check(r.obj.serverAnimation().tracks.size() == 2, "the server's view holds the same two");
    mesh->drop();
}

// Two tracks on one joint: the higher priority one owns it, whichever was set
// last. A joint only the lower one animates still follows it.
void testPriority() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 0};
    wave.start = 5;
    Play lift{0, 4, 0};
    lift.start = 2;
    lift.priority = 1;
    Play kick{0, 2, 0};
    kick.priority = -1;
    r.send(setAnimation(lift, named("lift")));
    r.send(setAnimation(wave, named("wave")));
    r.send(setAnimation(kick, named("kick")));
    r.step(0.0f);
    check(near(r.at(ARM), v3f(0, 2, 0)), "lift (priority 1) owns the arm over wave (priority 0)");
    check(near(r.at(LEG), v3f(0, 0, 2)), "lift owns the leg over kick (priority -1)");

    wave.priority = 2;
    r.send(setAnimation(wave, named("wave")));
    r.step(0.0f);
    check(near(r.at(ARM), v3f(5, 0, 0)), "raising wave to priority 2 gives it the arm");
    check(near(r.at(LEG), v3f(0, 0, 2)), "wave does not animate the leg, so lift keeps it");

    r.send(stopAnimation(named("lift")));
    r.step(0.0f);
    check(near(r.at(LEG), v3f(5, 0, 0)), "with lift stopped, kick has the leg");
    mesh->drop();
}

// The start frame the server sends, and the clamp to the track's own length.
void testStartFrameAndClamp() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 1};
    wave.start = 3;
    r.send(setAnimation(wave, num(1)));
    Play lift{0, 100, 1};
    lift.start = 50;
    r.send(setAnimation(lift, num(2)));
    r.apply();
    check(r.track(0) && nearf(r.track(0)->cur_frame, 3), "track 1 starts at the frame the server sent");
    check(r.track(1) && nearf(r.track(1)->max_frame, 4), "a range past the track's end is clamped to it");
    check(r.track(1) && nearf(r.track(1)->cur_frame, 4), "and so is a start frame past it");
    r.step(0.5f);
    check(r.track(0) && nearf(r.track(0)->cur_frame, 3.5f), "and plays on from there");

    Play back{0, 10, -1};
    r.send(setAnimation(back, std::nullopt));
    r.apply();
    check(r.track(0) && nearf(r.track(0)->cur_frame, 10),
            "an old message with a negative speed starts at the end of the range");
    mesh->drop();
}

// set_animation_frame_speed and update_animation change one track's speed and
// keep its frame; the old form, with no track, is track 1.
void testSpeedPerTrack() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 1};
    Play kick{0, 2, 0.5f};
    r.send(setAnimation(wave, num(1)));
    r.send(setAnimation(kick, named("kick")));
    r.step(1.0f);
    r.send(setSpeed(0.0f, named("kick")));
    r.step(1.0f);
    check(r.track(0) && nearf(r.track(0)->cur_frame, 2), "track 1 keeps playing");
    check(r.track(2) && nearf(r.track(2)->cur_frame, 0.5f), "track 3 paused where it was");
    r.send(setSpeed(2.0f, std::nullopt));
    r.step(1.0f);
    check(r.track(0) && nearf(r.track(0)->cur_frame, 4), "an old speed message changes track 1");
    check(r.track(2) && nearf(r.track(2)->cur_frame, 0.5f), "and leaves track 3 alone");
    check(r.obj.serverAnimation().tracks.at(2).fps == 0.0f, "the server's view has the new speed");
    r.send(setSpeed(3.0f, num(2)));
    r.step(0.0f);
    check(r.track(1) == nullptr, "a speed for a track that is not playing starts nothing");
    mesh->drop();
}

// stop_animation takes the track away, and the joints it held go back to
// their rest transforms rather than freezing where they were.
void testStopReturnsToRest() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 1};
    wave.start = 7;
    r.send(setAnimation(wave, num(1)));
    r.step(0.0f);
    check(near(r.at(ARM), v3f(7, 0, 0)), "wave poses the arm");
    r.send(stopAnimation(num(1)));
    r.step(0.0f);
    check(near(r.at(ARM), ARM_REST), "stopping the only track on the arm returns it to rest");
    check(r.obj.meshAnimation()->tracks.empty(), "nothing is playing");
    check(r.obj.serverAnimation().tracks.empty(), "and the server's view agrees");
    r.send(stopAnimation(num(1)));
    r.step(0.0f);
    check(near(r.at(ARM), ARM_REST), "stopping a stopped track changes nothing");
    mesh->drop();
}

// A blend time interpolates from the pose shown the frame before, per track,
// the way SkinnedMesh::animateMesh does it.
void testBlendPerTrack() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 0};
    wave.start = 10;
    wave.loop = false;
    r.send(setAnimation(wave, num(1)));
    r.step(0.0f);
    check(near(r.at(ARM), v3f(10, 0, 0)), "wave holds the arm at 10");
    Play lift{0, 4, 0};
    lift.start = 4;
    lift.loop = false;
    lift.priority = 1;
    lift.blend = 1.0f;
    r.send(setAnimation(lift, named("lift")));
    r.step(0.25f);
    // a quarter of the way from (10, 0, 0) to (0, 4, 0)
    check(near(r.at(ARM), v3f(7.5f, 1, 0)), "a quarter second into a one second blend");
    r.step(0.25f);
    // half way from the pose just shown, (7.5, 1, 0), to (0, 4, 0)
    check(near(r.at(ARM), v3f(3.75f, 2.5f, 0)), "each step blends from the pose shown last");
    r.step(0.5f);
    check(near(r.at(ARM), v3f(0, 4, 0)), "the blend ends on the new track's pose");
    check(r.track(1) && nearf(r.track(1)->blend_progress, 1.0f), "and its progress stops at the duration");
    mesh->drop();
}

// Upstream keeps each playing track's frame when the object's mesh changes,
// and drops the tracks the new mesh does not have. A rebuild that keeps the
// mesh (Goanna rebuilds for a texture change) touches nothing.
void testMeshChange() {
    scene::SkinnedMesh *mesh = buildMesh();
    scene::SkinnedMesh *same_tracks = buildMesh();
    scene::SkinnedMesh *one_track = buildMesh(1);
    Rig r(mesh);
    r.attach();
    Play wave{0, 10, 1};
    wave.blend = 2.0f;
    Play lift{0, 4, 1};
    r.send(setAnimation(wave, num(1)));
    r.send(setAnimation(lift, num(2)));
    r.step(1.5f);
    r.obj.setAnimatedMesh(mesh);
    check(r.track(0) && nearf(r.track(0)->blend_progress, 1.5f), "the same mesh is not a new visual");
    r.obj.setAnimatedMesh(same_tracks);
    check(r.track(0) && nearf(r.track(0)->cur_frame, 1.5f), "a new mesh carries on from the frame reached");
    check(r.track(1) && nearf(r.track(1)->cur_frame, 1.5f), "on every track");
    r.obj.setAnimatedMesh(one_track);
    check(r.track(0) && !r.track(1), "a track the new mesh lacks is dropped");
    check(r.obj.serverAnimation().tracks.size() == 1, "from the server's view as well");
    r.obj.setAnimatedMesh(nullptr);
    check(r.obj.meshAnimation() == nullptr, "a visual that is not a mesh has no animation");
    r.send(setAnimation(wave, num(1)));
    r.step(0.0f);
    check(r.obj.deferredAnimationCount() == 0, "commands for it are applied, and go nowhere");
    mesh->drop();
    same_tracks->drop();
    one_track->drop();
}

// Pre-5.17 servers send a (0, 0) animation at init for every object, static
// ones included. It must not create anything on a mesh with no tracks.
void testOlderServerInitOnStaticMesh() {
    scene::SkinnedMeshBuilder b(scene::SkinnedMesh::SourceFormat::OTHER);
    b.addJoint()->Name = "root";
    scene::SkinnedMesh *mesh = std::move(b).finalize();
    GoannaActiveObject obj(2, ACTIVEOBJECT_TYPE_GENERIC);
    obj.processMessage(setAnimation({0, 0, 15}, std::nullopt), nullptr);
    obj.setAnimatedMesh(mesh);
    obj.applyDeferredAnimation(nullptr);
    check(obj.meshAnimation() && obj.meshAnimation()->tracks.empty(), "a (0, 0) init animation adds nothing");
    mesh->drop();
}

// Everything that arrives before the renderer draws the object is applied in
// order, speed and stop included, where upstream would have had the scene
// node already.
void testQueueOrder() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    Play lift{0, 4, 1};
    r.send(setAnimation(lift, named("lift")));
    r.send(setSpeed(3.0f, named("lift")));
    r.send(setAnimation({0, 2, 1}, named("kick")));
    r.send(stopAnimation(named("kick")));
    Play by_number{1, 3, 2};
    r.send(setAnimation(by_number, num(2)));
    r.attach();
    r.step(0.0f);
    check(r.track(2) == nullptr, "a set then a stop leaves nothing");
    check(r.track(1) && nearf(r.track(1)->min_frame, 1) && nearf(r.track(1)->fps, 2),
            "the later command on the same track wins, by name or by number");
    mesh->drop();
}

// An object the renderer never draws never has its queue applied. It must not
// grow with every message a mob's server side sends, and the state it holds
// must be the one the full sequence would have produced.
void testQueueBound() {
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    for (int i = 0; i < 2000; ++i) {
        Play p{0, 10, 1};
        p.start = (float)(i % 10);
        r.send(setAnimation(p, num(1)));
        r.send(setSpeed((float)(i % 7), num(1)));
        r.send(setSpeed((float)(i % 5), named("kick")));
        if (i % 3 == 0)
            r.send(stopAnimation(named("lift")));
    }
    check(r.obj.deferredAnimationCount() < 100, "the queue stays bounded");
    r.attach();
    r.step(0.0f);
    const auto *t = r.track(0);
    check(t && nearf(t->cur_frame, 9) && nearf(t->fps, 1999 % 7), "track 1 as the last commands left it");
    check(r.track(1) == nullptr && r.track(2) == nullptr, "nothing else was started");
    mesh->drop();
}

// A stand-in game for the LocalPlayer, which only needs an item definition
// manager for its inventory.
class TestGameDef : public IGameDef {
public:
    IItemDefManager *getItemDefManager() override { return m_idef; }
    const NodeDefManager *getNodeDefManager() override { return nullptr; }
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

private:
    IItemDefManager *m_idef = createItemDefManager();
    std::vector<ModSpec> m_mods;
};

std::string localPlayerInit(const std::string &name) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, 1);
    os << serializeString16(name);
    writeU8(os, 1); // is_player
    writeU16(os, 1);
    writeV3F32(os, v3f(0, 0, 0));
    writeV3F32(os, v3f(0, 0, 0));
    writeU16(os, 20);
    writeU8(os, 0); // no init messages
    return os.str();
}

// set_local_animation: the local player plays its own idle, walk and dig
// ranges on track 1 from its controls, a server animation with one of those
// ranges on track 1 does not interrupt it, and any other server animation
// does.
void testLocalPlayerAnimations() {
    TestGameDef gamedef;
    LocalPlayer player(&gamedef, "singleplayer");
    player.local_animations = {v2f(0, 3), v2f(4, 7), v2f(8, 9), v2f(9, 10)};
    player.local_animation_speed = 30.0f;
    scene::SkinnedMesh *mesh = buildMesh();
    Rig r(mesh);
    r.player = &player;
    r.obj.initialize(localPlayerInit("singleplayer"), &player);
    check(r.obj.isLocalPlayer(), "the object is the local player");
    r.attach();

    r.send(setAnimation({4, 7, 30}, std::nullopt));
    r.step(0.0f);
    check(r.track(0) == nullptr, "a server animation with the local walk range is not applied");
    check(r.obj.serverAnimation().tracks.count(0) == 1, "but it is remembered");

    player.control.movement_speed = 1.0f;
    r.obj.stepLocalPlayerAnimation(&player);
    check(r.obj.localPlayerAnimationActive(), "walking plays the local walk animation");
    check(r.track(0) && nearf(r.track(0)->min_frame, 4) && nearf(r.track(0)->fps, 30),
            "on track 1, at the local speed");
    check(player.last_animation == LocalPlayerAnimation::WALK_ANIM, "and the player remembers it");

    player.control.movement_speed = 0.0f;
    player.control.dig = true;
    r.obj.stepLocalPlayerAnimation(&player);
    check(r.track(0) && nearf(r.track(0)->min_frame, 8), "digging plays the dig range");
    player.control.dig = false;

    r.send(setAnimation({1, 2, 5}, num(3)));
    r.step(0.0f);
    check(!r.obj.localPlayerAnimationActive(), "any other server animation ends the local one");
    check(r.track(0) && nearf(r.track(0)->min_frame, 4), "and brings back what the server set");
    check(r.track(2) != nullptr, "including the new track");

    player.local_animations = {};
    player.last_animation = LocalPlayerAnimation::NO_ANIM;
    player.control.movement_speed = 1.0f;
    r.obj.stepLocalPlayerAnimation(&player);
    check(!r.obj.localPlayerAnimationActive(), "with no local animations the server's stay");
    mesh->drop();
}

void setUpSettings() {
    Settings *defaults = Settings::createLayer(SL_DEFAULTS);
    for (const char *k : {"free_move", "pitch_move", "fast_move", "continuous_forward",
                 "always_fly_fast", "aux1_descends", "noclip", "autojump"})
        defaults->setDefault(k, "false");
    g_settings = Settings::createLayer(SL_GLOBAL);
}

} // namespace

int main() {
    setUpSettings();
    testOlderServerMessage();
    testTracksByNameAndNumber();
    testPriority();
    testStartFrameAndClamp();
    testSpeedPerTrack();
    testStopReturnsToRest();
    testBlendPerTrack();
    testMeshChange();
    testOlderServerInitOnStaticMesh();
    testQueueOrder();
    testQueueBound();
    testLocalPlayerAnimations();
    if (g_failures) {
        std::printf("%d animation check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("animation: all checks passed\n");
    return 0;
}
