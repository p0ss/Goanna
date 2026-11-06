// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Transplanted from luanti/src/collision.h.
// Goanna changes 2026-09, against Luanti 5.17.0: the forward declaration of
// Environment becomes Map, and collisionMoveSimple and
// collision_check_intersection take a Map* instead of an Environment*.
// Goanna changes 2026-11: CollisionObjectSource and
// CollisionObjectSourceScope stand in for the ClientEnvironment that
// add_object_boxes asks for nearby active objects.

#pragma once

#include "irrlichttypes_bloated.h"
#include <vector>
#include "object_properties.h"

class IGameDef;
class Map;
class ActiveObject;

enum CollisionType : u8
{
	COLLISION_NODE,
	COLLISION_OBJECT,
};

enum CollisionAxis : s8
{
	COLLISION_AXIS_NONE = -1,
	COLLISION_AXIS_X,
	COLLISION_AXIS_Y,
	COLLISION_AXIS_Z,
};

struct CollisionInfo
{
	CollisionInfo() = default;

	CollisionType type = COLLISION_NODE;
	CollisionAxis axis = COLLISION_AXIS_NONE;
	v3s16 node_p = v3s16(-32768,-32768,-32768); // COLLISION_NODE
	ActiveObject *object = nullptr; // COLLISION_OBJECT
	v3f new_pos;
	v3f old_speed;
	v3f new_speed;
};

struct CollisionMoveResult
{
	CollisionMoveResult() = default;

	bool collides = false;
	bool touching_ground = false;
	bool standing_on_object = false;
	std::vector<CollisionInfo> collisions;
};

// Goanna: stands in for ClientEnvironment in add_object_boxes, which asks it
// for the active objects near a moving box. The session sets one, through
// CollisionObjectSourceScope, only around the local player's movement, so
// the mover is always the local player: a source must leave out the local
// player's own object and the objects attached directly to it, which is
// upstream's `self` check with self being the local player's object.
class CollisionObjectSource
{
public:
	virtual ~CollisionObjectSource() = default;
	// ClientEnvironment::getActiveObjects: every object whose position is
	// within max_d of origin.
	virtual void getActiveObjects(const v3f &origin, f32 max_d,
			std::vector<ActiveObject *> &dest) const = 0;
};

// Goanna: makes source the one add_object_boxes uses on this thread for as
// long as the scope lives. With none set, no object collides.
class CollisionObjectSourceScope
{
public:
	explicit CollisionObjectSourceScope(const CollisionObjectSource *source);
	~CollisionObjectSourceScope();
	CollisionObjectSourceScope(const CollisionObjectSourceScope &) = delete;
	CollisionObjectSourceScope &operator=(const CollisionObjectSourceScope &) = delete;

private:
	const CollisionObjectSource *m_previous;
};

/// Status if any problems were ever encountered during collision detection.
/// @warning For unit test use only.
extern bool g_collision_problems_encountered;

/// @param self (optional) ActiveObject to ignore in the collision detection.
CollisionMoveResult collisionMoveSimple(Map *map, IGameDef *gamedef,
		const aabb3f &box_0,
		f32 stepheight, f32 dtime,
		v3f *pos_f, v3f *speed_f,
		v3f accel_f, ActiveObject *self,
		bool collide_with_objects,
		StepUpMode step_up_mode);

/// @brief A simpler version of "collisionMoveSimple" that only checks whether
///        a collision occurs at the given position.
/// @param self (optional) ActiveObject to ignore in the collision detection.
/// @returns `true` when `box_0` truly intersects with a node or object.
///          Touching faces are not counted as intersection.
bool collision_check_intersection(Map *map, IGameDef *gamedef,
		const aabb3f &box_0, const v3f &pos_f, ActiveObject *self = nullptr,
		bool collide_with_objects = true);

// Helper function:
// Checks for collision of a moving aabbox with a static aabbox
// Returns -1 if no collision, 0 if X collision, 1 if Y collision, 2 if Z collision
// dtime receives time until first collision, invalid if -1 is returned
CollisionAxis axisAlignedCollision(
		const aabb3f &staticbox, const aabb3f &movingbox,
		v3f speed, f32 *dtime);

// Helper function:
// Checks if moving the movingbox up by the given distance would hit a ceiling.
bool wouldCollideWithCeiling(
		const std::vector<aabb3f> &staticboxes,
		const aabb3f &movingbox,
		f32 y_increase, f32 d);
