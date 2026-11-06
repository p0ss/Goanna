// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The local player's collision with active objects, as the stock client
// has it: LocalPlayer::move sweeps the player against every nearby object
// whose properties have both `physical` and `collide_with_objects` set,
// taking each object's collision box, axis aligned, at the position the
// server last sent (luanti/src/collision.cpp, add_object_boxes, and
// GenericCAO::getCollisionBox in client/content_cao.cpp).
//
// ObjectCollisionSource is what the transplanted add_object_boxes asks in
// place of ClientEnvironment. The session gathers it once per player step
// and puts it in scope (CollisionObjectSourceScope) around the movement.

#include <map>
#include <memory>
#include <vector>

#include "irrlichttypes_bloated.h"
#include "transplant/collision.h"

namespace goanna {

class GoannaActiveObject;

class ObjectCollisionSource final : public CollisionObjectSource {
public:
    // Takes the objects that can collide with the local player: not the
    // local player's own object nor one attached directly to it (upstream's
    // self check), and with physical and collide_with_objects both set
    // (the two tests add_object_boxes makes of each object, made here once
    // so a query only looks at objects that can collide). Attached objects
    // are left out altogether; see the note in the source.
    void gather(const std::map<u16, std::unique_ptr<GoannaActiveObject>> &objects);

    // ClientEnvironment::getActiveObjects over the gathered objects: those
    // whose drawn (interpolated) position is within max_d of origin.
    void getActiveObjects(const v3f &origin, f32 max_d,
            std::vector<ActiveObject *> &dest) const override;

    size_t candidates() const { return m_candidates.size(); }

private:
    std::vector<GoannaActiveObject *> m_candidates;
};

} // namespace goanna
