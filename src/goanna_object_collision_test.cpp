// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The local player against active objects, checked without Godot: the
// transplanted LocalPlayer::move on a stone floor, with objects made from
// the init and AO_CMD_* messages a server sends, gathered the way
// GoannaSession::stepPlayer gathers them. Stock Luanti's rules
// (luanti/src/collision.cpp, add_object_boxes; client/content_cao.cpp,
// GenericCAO::getCollisionBox): an object blocks only with physical and
// collide_with_objects both set, its box is axis aligned at the position
// the server last sent, step height applies to it as to a node, and the
// player can stand on it.

#include "goanna_object_collision.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <sstream>
#include <string>

#include "activeobject.h"
#include "client/mapblock_mesh.h"
#include "client/node_visuals.h"
#include "content/mods.h"
#include "gamedef.h"
#include "goanna_map.h"
#include "itemdef.h"
#include "nodedef.h"
#include "settings.h"
#include "transplant/client/content_cao.h"
#include "transplant/collision.h"
#include "transplant/localplayer.h"
#include "util/serialize.h"

// As in goanna_animation_test: the movement code links Map and
// NodeDefManager, whose destructors reach these; nothing here builds a mesh
// or node visuals.
MapBlockMesh::~MapBlockMesh() {}
NodeVisuals::~NodeVisuals() {}

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const char *what) {
    ++g_checks;
    if (!ok) {
        std::printf("FAIL: %s\n", what);
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
    content_t stone() const { return m_ndef->getId("test:stone"); }

private:
    IItemDefManager *m_idef = createItemDefManager();
    NodeDefManager *m_ndef = createNodeDefManager();
    std::vector<ModSpec> m_mods;
};

// Stone at y <= 0 and air above, over blocks -1..1 in x and z.
void buildFloor(GoannaMap &map, content_t stone) {
    for (s16 bx = -1; bx <= 1; ++bx)
    for (s16 bz = -1; bz <= 1; ++bz) {
        MapSector *sector = map.emergeSector(v2s16(bx, bz));
        for (s16 by = -1; by <= 1; ++by) {
            MapBlock *block = sector->createBlankBlock(by);
            for (s16 z = 0; z < MAP_BLOCKSIZE; ++z)
            for (s16 y = 0; y < MAP_BLOCKSIZE; ++y)
            for (s16 x = 0; x < MAP_BLOCKSIZE; ++x) {
                const s16 wy = by * MAP_BLOCKSIZE + y;
                block->setNodeNoCheck(x, y, z, MapNode(wy <= 0 ? stone : CONTENT_AIR));
            }
            block->expireIsAirCache();
        }
    }
}

std::string message(u8 cmd, const std::string &body) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, cmd);
    return os.str() + body;
}

std::string propertiesMessage(const ObjectProperties &prop) {
    std::ostringstream os(std::ios::binary);
    prop.serialize(os);
    return message(AO_CMD_SET_PROPERTIES, os.str());
}

// UnitSAO / LuaEntitySAO::sendPosition: what move_to(pos, true) sends.
std::string positionMessage(v3f pos, bool interpolate, bool is_end) {
    std::ostringstream os(std::ios::binary);
    writeV3F32(os, pos);
    writeV3F32(os, v3f());
    writeV3F32(os, v3f());
    writeV3F32(os, v3f());
    writeU8(os, interpolate);
    writeU8(os, is_end);
    writeF32(os, 0.2f);
    return message(AO_CMD_UPDATE_POSITION, os.str());
}

std::string initData(const std::string &name, bool is_player, u16 id, v3f pos,
        const ObjectProperties &prop) {
    std::ostringstream os(std::ios::binary);
    writeU8(os, 1);
    os << serializeString16(name);
    writeU8(os, is_player);
    writeU16(os, id);
    writeV3F32(os, pos);
    writeV3F32(os, v3f());
    writeU16(os, 20);
    writeU8(os, 1);
    os << serializeString32(propertiesMessage(prop));
    return os.str();
}

ObjectProperties blockProps(bool physical, bool collide_with_objects,
        aabb3f box = aabb3f(-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f)) {
    ObjectProperties p;
    p.physical = physical;
    p.collideWithObjects = collide_with_objects;
    p.collisionbox = box;
    return p;
}

struct World {
    TestGameDef gamedef;
    GoannaMap map{&gamedef};
    LocalPlayer player{&gamedef, "singleplayer"};
    std::map<u16, std::unique_ptr<GoannaActiveObject>> objects;
    ObjectCollisionSource source;
    std::vector<CollisionInfo> collisions;
    u16 next_id = 1;

    World() {
        buildFloor(map, gamedef.stone());
        player.setPosition(v3f(0, 0.5f, 0) * BS);
    }

    // Positions in nodes.
    GoannaActiveObject &add(v3f pos, const ObjectProperties &prop,
            const std::string &name = "test:block", bool is_player = false) {
        u16 id = next_id++;
        auto obj = std::make_unique<GoannaActiveObject>(id, ACTIVEOBJECT_TYPE_GENERIC);
        obj->initialize(initData(name, is_player, id, pos * BS, prop), &player);
        GoannaActiveObject &ref = *obj;
        objects[id] = std::move(obj);
        return ref;
    }

    // GoannaSession::stepPlayer, cut down: gather, scope, 10 ms parts,
    // gravity, and the horizontal speed held at `walk` (nodes per second)
    // the way applyControl would on flat ground.
    void run(float seconds, v3f walk) {
        source.gather(objects);
        CollisionObjectSourceScope scope(&source);
        const float dt = 0.01f;
        for (float t = 0; t < seconds; t += dt) {
            v3f speed = player.getSpeed();
            speed.X = walk.X * BS;
            speed.Z = walk.Z * BS;
            player.setSpeed(speed);
            player.gravity = 2 * 9.81f * BS;
            player.move(dt, &map, &collisions);
        }
    }

    v3f pos() const { return player.getPosition() / BS; }

    bool hitObject() const {
        for (const CollisionInfo &c : collisions)
            if (c.type == COLLISION_OBJECT)
                return true;
        return false;
    }
};

// The player's box is 0.3 either side, so walking +X into a block centred
// at x = 2 stops at 2 - 0.5 - 0.3 = 1.2.
void testPhysicalBlocks() {
    World w;
    w.add(v3f(2, 1, 0), blockProps(true, true));
    w.run(1.0f, v3f(4, 0, 0));
    check(std::fabs(w.pos().X - 1.2f) < 0.01f, "a physical object stops the player at its face");
    check(w.hitObject(), "and the collision is reported as an object");
    check(w.player.touching_ground, "while the player is still on the floor");
}

void testNonPhysicalPasses() {
    World w;
    w.add(v3f(2, 1, 0), blockProps(false, true));
    w.run(1.0f, v3f(4, 0, 0));
    check(w.pos().X > 3.5f, "an object that is not physical does not block");
    check(!w.hitObject(), "and nothing is reported");
}

// add_object_boxes takes an object only if collideWithObjects() is true, so
// in the stock client a physical object with collide_with_objects = false
// does not block the player either.
void testCollideWithObjectsFalsePasses() {
    World w;
    w.add(v3f(2, 1, 0), blockProps(true, false));
    w.run(1.0f, v3f(4, 0, 0));
    check(w.pos().X > 3.5f, "physical with collide_with_objects false does not block, as in stock");
}

void testStandOnTop() {
    World w;
    w.add(v3f(0, 1, 0), blockProps(true, true));
    w.player.setPosition(v3f(0, 3, 0) * BS);
    w.run(1.5f, v3f());
    check(std::fabs(w.pos().Y - 1.5f) < 0.01f, "the player lands on top of a physical object");
    check(w.player.touching_ground, "and stands on it");
    // Walk off its far edge: the player leaves the box and drops to the floor.
    w.run(1.0f, v3f(2, 0, 0));
    check(std::fabs(w.pos().Y - 0.5f) < 0.01f, "walking off it drops the player to the floor");
}

// Step height applies to objects as to nodes: a half-height box is walked
// onto, a full one is not (the default player step height is 0.6).
void testStepUp() {
    World w;
    w.add(v3f(2, 1, 0), blockProps(true, true, aabb3f(-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f)));
    w.run(0.6f, v3f(3, 0, 0));
    check(w.pos().X > 1.5f && w.pos().X < 2.5f, "a low physical object is stepped onto");
    check(std::fabs(w.pos().Y - 1.0f) < 0.01f, "and stood on");
}

// The box sits where the server last put the object, not where it is
// drawn while catching up: after move_to(pos, true) from x = 2 to x = 4,
// before the object has been stepped, it is drawn at 2 and collides at 4.
void testMovedObjectCollidesAtServerPosition() {
    World w;
    GoannaActiveObject &obj = w.add(v3f(2, 1, 0), blockProps(true, true));
    obj.processMessage(positionMessage(v3f(4, 1, 0) * BS, true, false), &w.player);
    check(std::fabs(obj.position().X / BS - 2.0f) < 0.01f, "the moved object is still drawn at its old place");
    check(std::fabs(obj.rawPosition().X / BS - 4.0f) < 0.01f, "the server's new position is known");
    w.run(1.0f, v3f(4, 0, 0));
    check(std::fabs(w.pos().X - 3.2f) < 0.01f, "the player collides with it at the server's position");

    // A physical object's drawn position closes 80% of the gap each object
    // step (GenericCAO::step updates its translator over that step's dtime
    // and SmoothTranslator moves 0.8 of the way), so it is drawn within a
    // few frames of where it collides.
    obj.step(0.05f, &w.map, &w.gamedef, nullptr);
    check(std::fabs(obj.position().X / BS - 3.6f) < 0.01f, "one object step draws it 80% of the way");
    for (int i = 0; i < 4; ++i)
        obj.step(0.05f, &w.map, &w.gamedef, nullptr);
    check(std::fabs(obj.position().X / BS - 4.0f) < 0.01f, "and five draw it at the server's position");
}

// The local player's own object never blocks it, even when physical.
void testOwnObjectIgnored() {
    World w;
    w.add(v3f(0, 0.5f, 0), blockProps(true, true, aabb3f(-0.3f, 0.0f, -0.3f, 0.3f, 1.77f, 0.3f)),
            "singleplayer", true);
    check(w.objects.begin()->second->isLocalPlayer(), "the object is the local player's");
    w.run(1.0f, v3f(4, 0, 0));
    check(w.pos().X > 3.5f, "the local player's own physical object does not block it");
}

// Attached objects are left out (see goanna_object_collision.cpp).
void testAttachedLeftOut() {
    World w;
    GoannaActiveObject &parent = w.add(v3f(8, 1, 0), blockProps(false, true));
    GoannaActiveObject &child = w.add(v3f(2, 1, 0), blockProps(true, true));
    std::ostringstream os(std::ios::binary);
    writeS16(os, parent.id());
    os << serializeString16("");
    writeV3F32(os, v3f());
    writeV3F32(os, v3f());
    writeU8(os, 0);
    child.processMessage(message(AO_CMD_ATTACH_TO, os.str()), &w.player);
    check(child.attachmentParent() == parent.id(), "the child is attached");
    w.source.gather(w.objects);
    check(w.source.candidates() == 0, "an attached physical object is not a candidate");
}

// Nothing collides outside a scope: object steps and any other caller of
// collisionMoveSimple see nodes only, as before.
void testNoScopeNoObjects() {
    World w;
    w.add(v3f(2, 1, 0), blockProps(true, true));
    const float dt = 0.01f;
    for (float t = 0; t < 1.0f; t += dt) {
        v3f speed = w.player.getSpeed();
        speed.X = 4 * BS;
        w.player.setSpeed(speed);
        w.player.gravity = 2 * 9.81f * BS;
        w.player.move(dt, &w.map, &w.collisions);
    }
    check(w.pos().X > 3.5f, "without a source in scope no object collides");
}

// Many physical blocks around the player, as a moving body's limbs would
// be: 1000 within a few nodes. Prints the cost of a second of walking.
void testManyObjects() {
    World w;
    for (int i = 0; i < 1000; ++i) {
        float x = 3.0f + (i % 10);
        float z = -5.0f + ((i / 10) % 10);
        float y = 1.0f + (i / 100);
        w.add(v3f(x, y, z), blockProps(true, true));
    }
    auto t0 = std::chrono::steady_clock::now();
    w.run(1.0f, v3f(4, 0, 0));
    auto us = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - t0).count();
    check(std::fabs(w.pos().X - 2.2f) < 0.01f, "the nearest of 1000 blocks stops the player");
    std::printf("1000 physical objects: one second of walking (100 moves) took %lld us\n",
            (long long)us);
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
    testPhysicalBlocks();
    testNonPhysicalPasses();
    testCollideWithObjectsFalsePasses();
    testStandOnTop();
    testStepUp();
    testMovedObjectCollidesAtServerPosition();
    testOwnObjectIgnored();
    testAttachedLeftOut();
    testNoScopeNoObjects();
    testManyObjects();
    if (g_failures) {
        std::printf("%d of %d object collision checks failed\n", g_failures, g_checks);
        return 1;
    }
    std::printf("object collision: all %d checks passed\n", g_checks);
    return 0;
}
