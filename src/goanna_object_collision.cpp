// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_object_collision.h"

#include "transplant/client/content_cao.h"

namespace goanna {

void ObjectCollisionSource::gather(
        const std::map<u16, std::unique_ptr<GoannaActiveObject>> &objects) {
    m_candidates.clear();
    for (const auto &kv : objects) {
        GoannaActiveObject *obj = kv.second.get();
        if (obj->isLocalPlayer())
            continue;
        // Upstream leaves out what is attached to the local player and
        // checks every other object. An attached object's box upstream
        // sits where its scene node is drawn, offset from the parent and
        // turned with it; Goanna's session side keeps an attached object at
        // its parent's origin (GoannaActiveObject::step) and has no scene
        // node to ask, so a box there could block where nothing is drawn.
        // Attached objects are left out until that position is known.
        if (obj->attachmentParent() != 0)
            continue;
        if (!obj->props().physical || !obj->collideWithObjects())
            continue;
        m_candidates.push_back(obj);
    }
}

void ObjectCollisionSource::getActiveObjects(const v3f &origin, f32 max_d,
        std::vector<ActiveObject *> &dest) const {
    const f32 max_d2 = max_d * max_d;
    for (GoannaActiveObject *obj : m_candidates) {
        if ((obj->position() - origin).getLengthSQ() > max_d2)
            continue;
        dest.push_back(obj->collisionObject());
    }
}

} // namespace goanna
