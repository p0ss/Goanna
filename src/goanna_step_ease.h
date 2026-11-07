// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The view's rise after a step up, eased the way Luanti's own camera eases
// it (Camera::update in luanti/src/client/camera.cpp, "Smooth the camera
// movement after the player instantly moves upward due to stepheight"; that
// file is Copyright (C) 2010-2013 celeron55, Perttu Ahola, LGPL-2.1-or-later).
// camera.cpp needs Irrlicht's scene and cannot be compiled here, so the same
// condition and decay are restated: a rise of more than 0.01 and no more
// than the step height starts the ease while the player stands on the
// ground after the move, and the shown height then closes on the real one
// by exp(-23 dt) a frame. A fall, a rise past the step height (a teleport,
// a server correction upwards) or a jump, which leaves the ground, shows at
// once. Presentation only: the player's position, what the server is sent
// and the collision are untouched.
#pragma once

#include <cmath>

namespace goanna {

struct StepEase {
    bool have = false;
    bool active = false;
    float shown = 0.0f; // the height shown, in the caller's units

    // Forget the ease, as after a server move: the next height shows as is.
    void reset() { have = false; active = false; }

    // raw: the player's height after this frame's move; step: its step
    // height, in the same units. Returns what to add to the height shown
    // (zero or negative). dt of zero leaves the ease where it was.
    float update(float raw, float step, bool grounded, float dt) {
        if (!have) {
            have = true;
            active = false;
            shown = raw;
            return 0.0f;
        }
        if (dt <= 0.0f)
            return active ? shown - raw : 0.0f;
        const float up = raw - shown;
        if (up < 0.01f || up > step)
            active = false;
        else if (grounded)
            active = true;
        if (active) {
            const float t = std::exp(-23.0f * dt);
            shown = shown * t + raw * (1.0f - t);
        } else {
            shown = raw;
        }
        return shown - raw;
    }
};

} // namespace goanna
