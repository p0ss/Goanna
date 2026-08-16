// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Pointed-thing raycast: Luanti's Environment::continueRaycast, transplanted
// as a free function (src/transplant/environment_raycast.cpp) so Goanna can
// point at nodes and objects without an Environment.

#include <functional>
#include <optional>
#include <vector>

#include "irrlichttypes_bloated.h"
#include "util/pointabilities.h"
#include "util/pointedthing.h"

class Map;
class RaycastState;

namespace goanna {

using SelectObjectsFn = std::function<void(const core::line3d<f32> &shootline,
        std::vector<PointedThing> &objects, const std::optional<Pointabilities> &pointabilities)>;

void continueRaycast(RaycastState *state, PointedThing *result_p, Map &map,
        const SelectObjectsFn &getSelectedActiveObjects);

} // namespace goanna
