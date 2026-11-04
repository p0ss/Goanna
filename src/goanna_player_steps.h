// SPDX-License-Identifier: LGPL-2.1-or-later
// The server owns step height. A full-block grant uses grounded collision
// steps rather than an automatic jump; ordinary servers retain autojump.
#pragma once

#include "object_properties.h"
#include "transplant/localplayer.h"

namespace goanna {

inline void configurePlayerSteps(LocalPlayer &player, const ObjectProperties *props,
        bool autojump) {
    // ObjectProperties carries stepheight in engine units, already scaled
    // by the server. Do not multiply it by BS again.
    player.step_height = props ? props->stepheight : 0.6f * BS;
    player.getPlayerSettings().autojump = autojump && player.step_height <= BS;
}

inline bool playerJumpInput(LocalPlayer &player, bool manual) {
    // Ignore a pending autojump flag when the server has changed the grant.
    return manual || (player.getPlayerSettings().autojump && player.getAutojump());
}

} // namespace goanna
